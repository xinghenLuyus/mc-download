import 'dart:io';
import 'package:path/path.dart' as p;
import 'models.dart';

class GameDirectoryCandidate {
  final String path, source;
  final bool hasVersions;
  const GameDirectoryCandidate(
    this.path,
    this.source, {
    required this.hasVersions,
  });
}

class DirectorySearchResult {
  final List<GameDirectoryCandidate> directories;
  final bool limited;
  final List<String> warnings;
  const DirectorySearchResult(
    this.directories, {
    this.limited = false,
    this.warnings = const [],
  });
}

// Only inspect known locations automatically. Deep scans are confined to a folder
// explicitly selected by the user; asset/mod trees and filesystem links are skipped.
class GameDirectoryDiscovery {
  final Map<String, String> environment;
  final bool windows;
  GameDirectoryDiscovery({Map<String, String>? environment, bool? windows})
    : environment = environment ?? Platform.environment,
      windows = windows ?? Platform.isWindows;

  String identity(String path) {
    final value = p.normalize(p.absolute(path));
    return windows ? value.toLowerCase() : value;
  }

  Future<GameDirectoryCandidate?> inspect(
    String path,
    String source, {
    bool named = false,
  }) async {
    try {
      final directory = Directory(path);
      if (!await directory.exists()) return null;
      final canonical = await directory.resolveSymbolicLinks();
      final versions = Directory(p.join(canonical, 'versions'));
      final hasVersions = await versions.exists();
      if (named || p.basename(canonical).toLowerCase() == '.minecraft') {
        return GameDirectoryCandidate(
          canonical,
          source,
          hasVersions: hasVersions,
        );
      }
      if (!hasVersions) return null;
      if (await Directory(p.join(canonical, 'assets')).exists() ||
          await Directory(p.join(canonical, 'libraries')).exists() ||
          await File(p.join(canonical, 'launcher_profiles.json')).exists()) {
        return GameDirectoryCandidate(canonical, source, hasVersions: true);
      }
      var count = 0;
      await for (final entry in versions.list(followLinks: false)) {
        if (++count > 256) break;
        if (entry is Directory &&
            await File(
              p.join(entry.path, '${p.basename(entry.path)}.json'),
            ).exists()) {
          return GameDirectoryCandidate(canonical, source, hasVersions: true);
        }
      }
    } on FileSystemException {
      /* A missing/inaccessible candidate is not a game root. */
    }
    return null;
  }

  Future<List<GameDirectoryCandidate>> defaults({
    String? executableDirectory,
  }) async {
    if (!windows) return [];
    final paths = <String, String>{};
    // Prefer the launcher's portable game folder over the roaming installation.
    // executableDirectory comes from the outer EXE, including single-file builds.
    if (executableDirectory != null) {
      paths[p.join(executableDirectory, '.minecraft')] = '工具旁的游戏目录';
      paths[executableDirectory] = '工具所在目录';
    }
    final appdata = environment['APPDATA'];
    final home = environment['USERPROFILE'];
    if (appdata != null && appdata.isNotEmpty) {
      paths[p.join(appdata, '.minecraft')] = '官方启动器默认目录';
    }
    if (home != null && home.isNotEmpty) {
      paths[p.join(home, 'AppData', 'Roaming', '.minecraft')] = '官方启动器默认目录';
    }
    final result = <String, GameDirectoryCandidate>{};
    for (final entry in paths.entries) {
      final found = await inspect(entry.key, entry.value);
      if (found != null) result[identity(found.path)] = found;
    }
    return result.values.toList();
  }

  Future<DirectorySearchResult> fromLauncher(
    String selected, {
    int maxDepth = 5,
    int maxDirectories = 1500,
    Duration budget = const Duration(seconds: 5),
    bool Function()? cancelled,
  }) async {
    final type = await FileSystemEntity.type(selected);
    final base = type == FileSystemEntityType.file
        ? p.dirname(selected)
        : selected;
    if (!await Directory(base).exists()) {
      throw const FileSystemException('所选启动器目录不存在');
    }
    final canonical = await Directory(base).resolveSymbolicLinks();
    if (p.dirname(canonical) == canonical) {
      throw const FileSystemException('请选择启动器所在文件夹，不扫描整块磁盘');
    }
    final watch = Stopwatch()..start();
    final result = <String, GameDirectoryCandidate>{};
    final visited = <String>{};
    final warnings = <String>[];
    final queue = <({String path, int depth})>[(path: canonical, depth: 0)];
    var position = 0, limited = false;
    const excluded = {
      'assets',
      'libraries',
      'mods',
      'resourcepacks',
      'shaderpacks',
      'saves',
      'logs',
      'crash-reports',
      'cache',
      'caches',
      'backups',
      'node_modules',
      '.git',
      '.mcd-trash',
      '.mcd-staging',
      '.mcd-copy',
      '.mcd-world',
    };
    Future<void> add(String path, String source) async {
      final candidate = await inspect(path, source);
      if (candidate != null) {
        result.putIfAbsent(identity(candidate.path), () => candidate);
      }
    }

    await _configurationRoots(
      canonical,
      (path, source) => add(path, source),
      warnings,
    );
    while (position < queue.length) {
      if (cancelled?.call() == true) break;
      if (visited.length >= maxDirectories || watch.elapsed > budget) {
        limited = true;
        break;
      }
      final item = queue[position++];
      if (!visited.add(identity(item.path))) continue;
      final found = await inspect(item.path, '所选启动器目录内发现');
      if (found != null) {
        result.putIfAbsent(identity(found.path), () => found);
        // A root's versions contain content folders, not additional root repositories.
        continue;
      }
      if (item.depth >= maxDepth) {
        limited = true;
        continue;
      }
      try {
        await for (final entry in Directory(
          item.path,
        ).list(followLinks: false)) {
          if (cancelled?.call() == true) break;
          if (entry is! Directory ||
              excluded.contains(p.basename(entry.path).toLowerCase())) {
            continue;
          }
          if (queue.length >= maxDirectories || watch.elapsed > budget) {
            limited = true;
            break;
          }
          queue.add((path: entry.path, depth: item.depth + 1));
        }
      } on FileSystemException {
        warnings.add('无法读取 ${item.path}');
      }
    }
    return DirectorySearchResult(
      result.values.toList(),
      limited: limited,
      warnings: warnings,
    );
  }

  Future<void> _configurationRoots(
    String base,
    Future<void> Function(String, String) add,
    List<String> warnings,
  ) async {
    String resolve(String value) {
      var path = value.replaceAllMapped(
        RegExp(r'%([^%]+)%'),
        (m) => environment[m[1]!] ?? m[0]!,
      );
      if (path.startsWith(r'$')) {
        path = p.join(
          base,
          path.substring(1).replaceFirst(RegExp(r'^[/\\]+'), ''),
        );
      }
      if (windows && !Platform.isWindows) path = path.replaceAll('\\', '/');
      return p.isAbsolute(path)
          ? p.normalize(path)
          : p.normalize(p.join(base, path));
    }

    for (final name in [
      'hmcl.json',
      'config/game-directories.json',
      '.hmcl/config/game-directories.json',
    ]) {
      final file = File(p.join(base, name));
      try {
        if (!await file.exists() || await file.length() > 4 * 1024 * 1024) {
          continue;
        }
        final json = asMap(decodeJson(await file.readAsString()));
        // Read only documented game-directory fields, never import launcher accounts.
        for (final entry in asList(json['directories'])) {
          final path = asMap(entry)['path'];
          if (path is String && path.isNotEmpty) {
            await add(resolve(path), 'HMCL 游戏目录配置');
          }
        }
        for (final entry in asMap(json['profiles']).values) {
          final path = asMap(entry)['gameDir'];
          if (path is String && path.isNotEmpty) {
            await add(resolve(path), 'HMCL 游戏目录配置');
          }
        }
      } on FormatException {
        warnings.add('$name 格式损坏，已改为搜索实际目录');
      } on FileSystemException {
        warnings.add('无法读取 $name');
      }
    }
    final file = File(p.join(base, 'PCL', 'Setup.ini'));
    try {
      if (await file.exists() && await file.length() < 4 * 1024 * 1024) {
        final text = await file.readAsString();
        final folders = RegExp(
          r'^LaunchFolders[:=](.*)$',
          multiLine: true,
        ).firstMatch(text)?[1];
        if (folders != null) {
          for (final entry in folders.trim().split('|')) {
            final separator = entry.indexOf('>');
            if (separator >= 0) {
              await add(resolve(entry.substring(separator + 1)), 'PCL 游戏目录配置');
            }
          }
        }
      }
    } on FormatException {
      warnings.add('PCL 配置无法解码，已改为搜索实际目录');
    } on FileSystemException {
      warnings.add('无法读取 PCL 游戏目录配置');
    }
  }
}
