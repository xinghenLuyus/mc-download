import 'dart:io';
import 'package:path/path.dart' as p;

// Keep Windows data beside the executable, independent of a shortcut's working
// directory. Non-Windows development runs use the project working directory.
Future<String> applicationDataDirectory({
  String? executablePath,
  String? workingDirectory,
  bool? windows,
  Map<String, String>? environment,
}) async {
  final isWindows = windows ?? Platform.isWindows;
  final portable = (environment ?? Platform.environment)['MCD_PORTABLE_DATA'];
  if (isWindows && portable != null && portable.isNotEmpty) {
    if (!p.isAbsolute(portable)) {
      throw const FormatException('便携数据目录必须使用绝对路径');
    }
    return p.normalize(portable);
  }
  final base = isWindows
      ? p.dirname(executablePath ?? Platform.resolvedExecutable)
      : workingDirectory ?? Directory.current.path;
  return p.normalize(p.absolute(p.join(base, '.mcdownload')));
}

Future<void> shellOpen(String target) async {
  await Process.start(
    Platform.isWindows
        ? 'explorer.exe'
        : Platform.isMacOS
        ? 'open'
        : 'xdg-open',
    [target],
    mode: ProcessStartMode.detached,
    runInShell: false,
  );
}
