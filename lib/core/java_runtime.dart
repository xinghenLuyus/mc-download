import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;

class JavaRuntime {
  final String executable, version;
  final int major;
  const JavaRuntime(this.executable, this.version, this.major);
}

Future<JavaRuntime> inspectJava(String executable) async {
  final process = await Process.start(executable, [
    '-version',
  ], runInShell: false);
  final output = process.stdout
      .transform(const Utf8Decoder(allowMalformed: true))
      .join();
  final error = process.stderr
      .transform(const Utf8Decoder(allowMalformed: true))
      .join();
  int code;
  try {
    code = await process.exitCode.timeout(const Duration(seconds: 8));
  } on TimeoutException {
    process.kill();
    throw StateError('Java 检测超时：$executable');
  }
  final text = '${await output}\n${await error}';
  final match = RegExp(r'version\s+"([^"\r\n]+)"').firstMatch(text);
  if (code != 0 || match == null) {
    throw StateError('无效 Java：$executable\n$text');
  }
  final version = match[1]!;
  final parts = version.split(RegExp('[._+-]'));
  final major =
      int.tryParse(
        parts.first == '1' && parts.length > 1 ? parts[1] : parts.first,
      ) ??
      0;
  return JavaRuntime(executable, version, major);
}

// Bounded search of runtime installation locations, not a recursive disk scan.
Future<List<JavaRuntime>> discoverJava({
  Iterable<String> gameRoots = const [],
}) async {
  final candidates = <String>{};
  final env = Platform.environment;
  final exe = Platform.isWindows ? 'java.exe' : 'java';
  for (final key in ['JAVA_HOME', 'JRE_HOME']) {
    if (env[key]?.isNotEmpty == true) {
      candidates.add(p.join(env[key]!, 'bin', exe));
    }
  }
  for (final path in (env['PATH'] ?? '').split(
    Platform.isWindows ? ';' : ':',
  )) {
    if (path.isNotEmpty) candidates.add(p.join(path, exe));
  }
  final roots = <String>[];
  if (Platform.isWindows) {
    for (final key in ['ProgramFiles', 'ProgramFiles(x86)']) {
      final base = env[key];
      if (base == null) continue;
      for (final vendor in [
        'Java',
        'Eclipse Adoptium',
        'Microsoft',
        'Zulu',
        'BellSoft',
      ]) {
        roots.add(p.join(base, vendor));
      }
    }
    final local = env['LOCALAPPDATA'];
    if (local != null) {
      roots.add(
        p.join(
          local,
          'Packages',
          'Microsoft.4297127D64EC6_8wekyb3d8bbwe',
          'LocalCache',
          'Local',
          'runtime',
        ),
      );
    }
  }
  for (final root in gameRoots) {
    roots.add(p.join(root, 'runtime'));
    roots.add(p.join(p.dirname(root), 'runtime'));
  }
  var inspected = 0;
  Future<void> visit(String path, int depth) async {
    if (++inspected > 350 || !await Directory(path).exists()) return;
    final java = p.join(path, 'bin', exe);
    if (await File(java).exists()) {
      candidates.add(java);
      return;
    }
    if (depth == 0) return;
    try {
      await for (final item in Directory(path).list(followLinks: false)) {
        if (item is Directory) await visit(item.path, depth - 1);
      }
    } on FileSystemException {
      /* inaccessible runtime */
    }
  }

  for (final root in roots) {
    await visit(root, 4);
  }
  final result = <JavaRuntime>[];
  final seen = <String>{};
  for (final candidate in candidates) {
    if (!await File(candidate).exists()) continue;
    try {
      final real = await File(candidate).resolveSymbolicLinks();
      if (!seen.add(Platform.isWindows ? real.toLowerCase() : real)) continue;
      result.add(await inspectJava(real));
      if (result.length >= 20) break;
    } on Exception {
      /* continue with other installed runtimes */
    }
  }
  result.sort((a, b) => b.major.compareTo(a.major));
  return result;
}
