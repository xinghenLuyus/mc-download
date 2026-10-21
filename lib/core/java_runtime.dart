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
  Iterable<String> extraRoots = const [],
  Future<JavaRuntime> Function(String) inspect = inspectJava,
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
  final roots = <String>[...extraRoots];
  if (Platform.isWindows) {
    roots.addAll(await _registeredJavaHomes());
    for (final key in ['ProgramFiles', 'ProgramFiles(x86)']) {
      final base = env[key];
      if (base == null) continue;
      for (final vendor in [
        'Java',
        'Eclipse Adoptium',
        'Microsoft',
        'Zulu',
        'BellSoft',
        'Amazon Corretto',
        'Semeru',
      ]) {
        roots.add(p.join(base, vendor));
      }
    }
    final home = env['USERPROFILE'];
    if (home != null) {
      roots.addAll([
        p.join(home, '.jdks'),
        p.join(home, 'scoop', 'apps'),
        p.join(home, 'AppData', 'Roaming', '.minecraft', 'runtime'),
      ]);
    }
    final roaming = env['APPDATA'];
    if (roaming != null) roots.add(p.join(roaming, '.minecraft', 'runtime'));
    final local = env['LOCALAPPDATA'];
    if (local != null) {
      roots.add(p.join(local, 'Programs', 'Eclipse Adoptium'));
      roots.add(p.join(local, 'Programs', 'Microsoft'));
      roots.add(p.join(local, 'Programs', 'Java'));
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
    final launcher = p.dirname(root);
    for (final folder in ['runtime', 'java', 'jre', p.join('PCL', 'Java')]) {
      roots.add(p.join(launcher, folder));
    }
  }
  var inspected = 0;
  Future<void> visit(String path, int depth) async {
    if (++inspected > 2000 || !await Directory(path).exists()) return;
    final java = p.join(path, 'bin', exe);
    if (await File(java).exists()) {
      candidates.add(java);
      return;
    }
    if (depth == 0) return;
    try {
      await for (final item in Directory(path).list(followLinks: false)) {
        if (inspected >= 2000) break;
        if (item is Directory) await visit(item.path, depth - 1);
      }
    } on FileSystemException {
      /* inaccessible runtime */
    }
  }

  for (final root in roots.toSet()) {
    inspected = 0;
    await visit(root, 4);
  }
  final result = <JavaRuntime>[];
  final seen = <String>{};
  Future<void> inspectCandidate(String candidate) async {
    try {
      if (!await File(candidate).exists()) return;
      final real = await File(candidate).resolveSymbolicLinks();
      if (!seen.add(Platform.isWindows ? real.toLowerCase() : real)) return;
      result.add(await inspect(real));
    } catch (_) {
      // Broken registrations and invalid runtimes must not hide valid installs.
    }
  }

  final pending = <Future<void>>[];
  for (final candidate in candidates) {
    pending.add(inspectCandidate(candidate));
    if (pending.length == 4) {
      await Future.wait(pending);
      pending.clear();
    }
  }
  await Future.wait(pending);
  result.sort((a, b) => _compareJava(b, a));
  return result;
}

/// Prefer the oldest compatible major to avoid breaking legacy installers on
/// unnecessarily new Java releases. Prefer the newest update within that major.
JavaRuntime selectJava(List<JavaRuntime> runtimes, {int minimumMajor = 8}) {
  final compatible = runtimes.where((r) => r.major >= minimumMajor).toList()
    ..sort((a, b) {
      final major = a.major.compareTo(b.major);
      return major != 0 ? major : _compareJava(b, a);
    });
  if (compatible.isEmpty) {
    throw StateError('未找到 Java $minimumMajor 或更高版本，请在设置中刷新扫描或安装 Java。');
  }
  return compatible.first;
}

bool automaticJava(String path) =>
    path.isEmpty || path == 'auto' || path == 'java';

int _compareJava(JavaRuntime a, JavaRuntime b) {
  final av = RegExp(
    r'\d+',
  ).allMatches(a.version).map((m) => int.parse(m[0]!)).toList();
  final bv = RegExp(
    r'\d+',
  ).allMatches(b.version).map((m) => int.parse(m[0]!)).toList();
  for (var i = 0; i < av.length || i < bv.length; i++) {
    final result = (i < av.length ? av[i] : 0).compareTo(
      i < bv.length ? bv[i] : 0,
    );
    if (result != 0) return result;
  }
  return a.executable.compareTo(b.executable);
}

Future<List<String>> _registeredJavaHomes() async {
  final homes = <String>[];
  // Both registry views include installations outside standard vendor folders.
  for (final view in ['64', '32']) {
    for (final key in [
      r'HKLM\SOFTWARE\JavaSoft',
      r'HKLM\SOFTWARE\Eclipse Adoptium',
      r'HKCU\SOFTWARE\JavaSoft',
    ]) {
      Process? process;
      try {
        process = await Process.start('reg.exe', [
          'query',
          key,
          '/s',
          '/reg:$view',
        ], runInShell: false);
        final output = process.stdout
            .transform(const Utf8Decoder(allowMalformed: true))
            .join();
        final error = process.stderr.drain<void>();
        final code = await process.exitCode.timeout(const Duration(seconds: 3));
        final text = await output;
        await error;
        if (code != 0) continue;
        for (final line in text.split('\n')) {
          final match = RegExp(
            r'(?:JavaHome|Path)\s+REG_(?:EXPAND_)?SZ\s+(.+)$',
            caseSensitive: false,
          ).firstMatch(line.trim());
          if (match != null) homes.add(match[1]!.trim());
        }
      } on Exception {
        process?.kill();
      }
    }
  }
  return homes;
}
