import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'models.dart';

final _windowsIllegal = RegExp(r'[<>:"|?*\x00-\x1f]');
final _windowsDevice = RegExp(
  r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|$)',
  caseSensitive: false,
);

String safeChild(String root, String relative) {
  final normalized = relative.replaceAll('\\', '/');
  if (normalized.isEmpty ||
      normalized.startsWith('/') ||
      normalized.contains(':') ||
      normalized.contains('\u0000') ||
      normalized
          .split('/')
          .any(
            (s) =>
                s == '..' ||
                s.endsWith(' ') ||
                s.endsWith('.') ||
                _windowsIllegal.hasMatch(s) ||
                _windowsDevice.hasMatch(s),
          )) {
    throw FormatException('拒绝越界或非法路径：$relative');
  }
  final target = p.normalize(p.joinAll([root, ...normalized.split('/')]));
  if (!p.isWithin(p.absolute(root), p.absolute(target))) {
    throw FormatException('路径不在目标目录：$relative');
  }
  return target;
}

void validateId(String id) {
  if (id.isEmpty ||
      id.length > 120 ||
      id != id.trim() ||
      RegExp(r'[<>:"/\\|?*\x00-\x1f]').hasMatch(id) ||
      id.endsWith('.') ||
      RegExp(
        r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|$)',
        caseSensitive: false,
      ).hasMatch(id) ||
      id == '..') {
    throw const FormatException('版本名称不符合 Windows 文件夹命名规则');
  }
}

Future<void> guardPath(String root, String path) async {
  await Directory(root).create(recursive: true);
  final realRoot = await Directory(root).resolveSymbolicLinks();
  var current = path;
  while (await FileSystemEntity.type(current, followLinks: false) ==
      FileSystemEntityType.notFound) {
    final parent = p.dirname(current);
    if (parent == current) throw const FileSystemException('无法解析目标目录');
    current = parent;
  }
  final real = await (await FileSystemEntity.isDirectory(current)
      ? Directory(current).resolveSymbolicLinks()
      : File(current).resolveSymbolicLinks());
  if (!p.equals(realRoot, real) && !p.isWithin(realRoot, real)) {
    throw const FileSystemException('目标路径经过指向游戏目录外的链接，已停止写入');
  }
}

Future<void> writeJson(String path, Json value) async {
  final file = File(path);
  await file.parent.create(recursive: true);
  final temp = File('$path.tmp');
  await temp.writeAsString(pretty(value), flush: true);
  await temp.rename(path);
}

String mavenPath(String coordinate) {
  final split = coordinate.split('@');
  final pieces = split.first.split(':');
  if (pieces.length < 3 ||
      pieces.length > 4 ||
      pieces.any(
        (s) => s.isEmpty || s.contains('/') || s.contains('\\') || s == '..',
      )) {
    throw FormatException('无效 Maven 坐标：$coordinate');
  }
  final classifier = pieces.length == 4 ? '-${pieces[3]}' : '';
  return '${pieces[0].replaceAll('.', '/')}/${pieces[1]}/${pieces[2]}/${pieces[1]}-${pieces[2]}$classifier.${split.length > 1 ? split.last : 'jar'}';
}

bool windowsRules(dynamic value, String arch) {
  final rules = asList(value);
  if (rules.isEmpty) return true;
  var allow = false;
  for (final raw in rules) {
    final rule = asMap(raw);
    final os = asMap(rule['os']);
    var match = true;
    if (os['name'] != null && os['name'] != 'windows') match = false;
    final targetArch = switch (arch) {
      'arm64' => 'aarch64',
      'x86' => 'x86',
      _ => 'amd64',
    };
    if (os['arch'] != null && !RegExp(os['arch']).hasMatch(targetArch)) {
      match = false;
    }
    if (os['version'] != null && !RegExp(os['version']).hasMatch('10.0')) {
      match = false;
    }
    if (asMap(rule['features']).values.any((v) => v == true)) match = false;
    if (match) allow = rule['action'] == 'allow';
  }
  return allow;
}

Json mergeManifest(Json parent, Json child) {
  final result = {...parent, ...child};
  result['clientVersion'] =
      child['clientVersion'] ?? parent['clientVersion'] ?? parent['id'];
  final libs = <String, dynamic>{};
  for (final raw in [
    ...asList(parent['libraries']),
    ...asList(child['libraries']),
  ]) {
    final l = asMap(raw);
    final name = l['name'] as String? ?? '';
    final parts = name.split(':');
    final key = parts.length >= 3
        ? '${parts[0]}:${parts[1]}:${parts.length > 3 ? parts[3] : ''}:${jsonEncode(l['natives'])}:${jsonEncode(l['rules'])}'
        : name;
    libs[key] = raw;
  }
  result['libraries'] = libs.values.toList();
  if (parent['arguments'] != null || child['arguments'] != null) {
    result['arguments'] = {
      'game': [
        ...asList(asMap(parent['arguments'])['game']),
        ...asList(asMap(child['arguments'])['game']),
      ],
      'jvm': [
        ...asList(asMap(parent['arguments'])['jvm']),
        ...asList(asMap(child['arguments'])['jvm']),
      ],
    };
  }
  result.remove('inheritsFrom');
  return result;
}

class GameRepository {
  final String root;
  GameRepository(this.root);
  Future<Json> readManifest(String id, [Set<String>? seen]) async {
    validateId(id);
    seen ??= {};
    if (!seen.add(id)) throw const FormatException('版本继承存在循环');
    if (seen.length > 20) throw const FormatException('版本继承层级过深');
    final file = File(safeChild(root, 'versions/$id/$id.json'));
    final json = asMap(decodeJson(await file.readAsString()));
    final parent = json['inheritsFrom'];
    return parent is String
        ? mergeManifest(await readManifest(parent, seen), json)
        : json;
  }

  Future<List<LocalVersion>> scan() async {
    final dir = Directory(p.join(root, 'versions'));
    if (!await dir.exists()) return [];
    final result = <LocalVersion>[];
    final manifests = <String, Json>{};
    Future<Json> readCached(String id, [Set<String>? seen]) async {
      validateId(id);
      seen ??= {};
      if (!seen.add(id) || seen.length > 20) {
        throw const FormatException('版本继承存在循环或层级过深');
      }
      if (manifests.containsKey(id)) return manifests[id]!;
      final own = asMap(
        decodeJson(
          await File(safeChild(root, 'versions/$id/$id.json')).readAsString(),
        ),
      );
      return manifests[id] = own['inheritsFrom'] is String
          ? mergeManifest(await readCached(own['inheritsFrom'], seen), own)
          : own;
    }

    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! Directory || p.basename(entity.path).startsWith('.')) {
        continue;
      }
      final id = p.basename(entity.path);
      try {
        final file = File(p.join(entity.path, '$id.json'));
        if (!await file.exists() &&
            !await File(p.join(entity.path, '$id.jar')).exists() &&
            !await File(p.join(entity.path, 'mcd.json')).exists()) {
          continue;
        }
        Json own = {};
        var error = '';
        try {
          own = asMap(decodeJson(await file.readAsString()));
        } catch (e) {
          error = '版本描述文件缺失或损坏：$e';
        }
        Json merged;
        try {
          merged = await readCached(id);
        } catch (e) {
          merged = own;
          if (error.isEmpty) error = '无法解析父版本：$e';
        }
        final meta = File(p.join(entity.path, 'mcd.json'));
        Json extra = {};
        try {
          if (await meta.exists()) {
            extra = asMap(decodeJson(await meta.readAsString()));
          }
        } on Exception {
          if (error.isEmpty) error = '工具的版本记录损坏，已根据原版描述识别；可使用补全文件修复依赖';
        }
        var game =
            extra['game'] as String? ??
            own['clientVersion'] as String? ??
            merged['clientVersion'] as String? ??
            own['inheritsFrom'] as String? ??
            id;
        final gameArgs = asList(asMap(merged['arguments'])['game']);
        final gameFlag = gameArgs.indexOf('--fml.mcVersion');
        if (gameFlag >= 0 &&
            gameFlag + 1 < gameArgs.length &&
            gameArgs[gameFlag + 1] is String) {
          game = gameArgs[gameFlag + 1];
        }
        var loader = extra['loader'] as String? ?? '';
        var loaderVersion = extra['loaderVersion'] as String? ?? '';
        for (final raw in asList(merged['libraries'])) {
          final name = asMap(raw)['name'] as String? ?? '';
          final parts = name.split(':');
          if (parts.length < 3) continue;
          if (parts[0] == 'net.fabricmc' && parts[1] == 'fabric-loader') {
            loader = 'Fabric';
            loaderVersion = parts[2];
          }
          if (parts[0] == 'org.quiltmc' && parts[1] == 'quilt-loader') {
            loader = 'Quilt';
            loaderVersion = parts[2];
          }
          if (parts[0] == 'net.minecraftforge' && parts[1] == 'forge') {
            loader = 'Forge';
            loaderVersion = parts[2];
            if (parts[2].contains('-')) game = parts[2].split('-').first;
          }
          if (parts[0] == 'net.neoforged' &&
              ['neoforge', 'forge'].contains(parts[1])) {
            loader = 'NeoForge';
            loaderVersion = parts[2];
          }
          if (parts[0] == 'optifine' && parts[1].toLowerCase() == 'optifine') {
            loader = 'OptiFine';
            loaderVersion = parts[2].startsWith('${game}_')
                ? parts[2].substring(game.length + 1)
                : parts[2];
          }
        }
        final content = await detectContent(entity.path, extra);
        result.add(
          LocalVersion(
            root: root,
            id: id,
            game: game,
            loader: loader,
            loaderVersion: loaderVersion,
            contentPath: content.path,
            manifest: merged,
            isolationKnown: content.known,
            error: error,
          ),
        );
      } catch (e) {
        result.add(
          LocalVersion(
            root: root,
            id: id,
            game: id,
            loader: '',
            loaderVersion: '',
            contentPath: root,
            manifest: {},
            isolationKnown: false,
            error: '读取版本信息失败：$e',
          ),
        );
      }
    }
    result.sort((a, b) => a.id.toLowerCase().compareTo(b.id.toLowerCase()));
    return result;
  }

  Future<({String path, bool known})> detectContent(
    String versionPath,
    Json metadata,
  ) async {
    if (metadata['isolate'] is bool) {
      return (path: metadata['isolate'] ? versionPath : root, known: true);
    }
    final currentHmcl = File(
      p.join(versionPath, '.hmcl', 'config', 'instance-game-settings.json'),
    );
    if (await currentHmcl.exists()) {
      try {
        final config = asMap(decodeJson(await currentHmcl.readAsString()));
        if (asList(config['overrideProperties']).contains('runningDirectory')) {
          final path = config['runningDirectory'] as String? ?? '';
          return (path: path.isEmpty ? versionPath : path, known: true);
        }
      } catch (_) {}
    }
    final pcl = File(p.join(versionPath, 'PCL', 'Setup.ini'));
    if (await pcl.exists()) {
      final text = await pcl.readAsString();
      final rule = RegExp(
        r'^VersionArgumentIndieV2:(True|False|true|false|1|0)\s*$',
        multiLine: true,
      ).firstMatch(text);
      if (rule != null) {
        return (
          path: ['True', 'true', '1'].contains(rule[1]) ? versionPath : root,
          known: true,
        );
      }
      final old = RegExp(
        r'^VersionArgumentIndie:(1|2)\s*$',
        multiLine: true,
      ).firstMatch(text);
      if (old != null) {
        return (path: old[1] == '1' ? versionPath : root, known: true);
      }
    }
    final hmcl = File(p.join(versionPath, 'hmclversion.cfg'));
    if (await hmcl.exists()) {
      try {
        final j = asMap(decodeJson(await hmcl.readAsString()));
        if (j['gameDirType'] == 1) return (path: versionPath, known: true);
        if (j['gameDirType'] == 0) return (path: root, known: true);
        if (j['gameDirType'] == 2 && j['gameDir'] is String) {
          return (path: j['gameDir'] as String, known: true);
        }
      } catch (_) {}
    }
    for (final name in ['mods', 'saves', 'resourcepacks', 'shaderpacks']) {
      if (await Directory(p.join(versionPath, name)).exists()) {
        return (path: versionPath, known: false);
      }
    }
    return (path: root, known: false);
  }

  Future<void> setIsolation(LocalVersion version, bool isolate) async {
    await guardPath(root, version.path);
    final file = File(p.join(version.path, 'mcd.json'));
    final j = await file.exists()
        ? asMap(decodeJson(await file.readAsString()))
        : <String, dynamic>{};
    j.addAll({
      'game': version.game,
      'loader': version.loader,
      'loaderVersion': version.loaderVersion,
      'isolate': isolate,
    });
    await writeJson(file.path, j);
    await syncIsolation(root, version.path, isolate);
  }

  Future<void> deleteVersion(String id) async {
    validateId(id);
    final path = safeChild(root, 'versions/$id');
    await guardPath(root, path);
    for (final version in await scan()) {
      if (version.id == id) continue;
      final own = asMap(
        decodeJson(
          await File(p.join(version.path, '${version.id}.json')).readAsString(),
        ),
      );
      if (own['inheritsFrom'] == id || own['jar'] == id) {
        throw StateError('${version.id} 仍依赖这个版本，不能删除');
      }
    }
    // Move out of versions; user data remains recoverable and shared libraries untouched.
    final trash = safeChild(
      root,
      '.mcd-trash/${DateTime.now().millisecondsSinceEpoch}-$id',
    );
    await guardPath(root, trash);
    await Directory(trash).parent.create(recursive: true);
    await Directory(path).rename(trash);
  }

  Future<List<Json>> backups() async {
    final trash = Directory(p.join(root, '.mcd-trash'));
    if (!await trash.exists()) return [];
    final result = <Json>[];
    await for (final folder in trash.list(followLinks: false)) {
      if (folder is! Directory) continue;
      await for (final file in folder.list(followLinks: false)) {
        if (file is! File ||
            !file.path.endsWith('.json') ||
            p.basename(file.path) == 'mcd.json') {
          continue;
        }
        final id = p.basenameWithoutExtension(file.path);
        try {
          validateId(id);
          final json = asMap(decodeJson(await file.readAsString()));
          if (json['id'] != id) continue;
          result.add({
            'path': folder.path,
            'id': id,
            'date': (await folder.stat()).modified.toIso8601String(),
          });
          break;
        } on Exception {
          /* Unrelated content backups are not versions. */
        }
      }
    }
    result.sort((a, b) => (b['date'] as String).compareTo(a['date'] as String));
    return result;
  }

  Future<void> restoreBackup(String source, String id) async {
    validateId(id);
    final trash = p.join(root, '.mcd-trash');
    if (!p.isWithin(trash, source)) throw StateError('备份不在此游戏目录中');
    await guardPath(root, source);
    final backup = (await backups())
        .where((e) => p.equals(e['path'], source))
        .firstOrNull;
    if (backup == null) throw StateError('未找到有效版本备份');
    final dest = safeChild(root, 'versions/$id');
    await guardPath(root, dest);
    if (await Directory(dest).exists()) throw StateError('同名版本已存在，请使用另一个名称');
    final stage = safeChild(
      root,
      '.mcd-copy/restore-${DateTime.now().microsecondsSinceEpoch}',
    );
    await guardPath(root, stage);
    await copyTree(source, stage);
    final previous = backup['id'] as String;
    final file = File(p.join(stage, '$previous.json'));
    final json = asMap(decodeJson(await file.readAsString()))..['id'] = id;
    if (json['jar'] == previous) json['jar'] = id;
    if (previous != id) await file.delete();
    await writeJson(p.join(stage, '$id.json'), json);
    if (previous != id && await File(p.join(stage, '$previous.jar')).exists()) {
      await File(
        p.join(stage, '$previous.jar'),
      ).rename(p.join(stage, '$id.jar'));
    }
    final meta = File(p.join(stage, 'mcd.json'));
    if (await meta.exists()) {
      final data = asMap(decodeJson(await meta.readAsString()))..['id'] = id;
      await writeJson(meta.path, data);
    }
    await Directory(dest).parent.create(recursive: true);
    if (await Directory(dest).exists()) throw StateError('恢复期间出现同名版本，停止覆盖');
    await Directory(stage).rename(dest);
  }

  Future<void> copyVersion(
    LocalVersion version,
    String newId, {
    bool rename = false,
  }) async {
    validateId(newId);
    final dest = safeChild(root, 'versions/$newId');
    if (await Directory(dest).exists()) throw StateError('目标版本已存在');
    await guardPath(root, dest);
    if (rename) {
      for (final other in await scan()) {
        if (other.id == version.id) continue;
        final own = asMap(
          decodeJson(
            await File(p.join(other.path, '${other.id}.json')).readAsString(),
          ),
        );
        if (own['inheritsFrom'] == version.id || own['jar'] == version.id) {
          throw StateError('有其他版本依赖此版本，请使用复制');
        }
      }
    }
    final temp = safeChild(
      root,
      '.mcd-copy/${DateTime.now().microsecondsSinceEpoch}',
    );
    await guardPath(root, temp);
    await copyTree(version.path, temp);
    final oldJson = File(p.join(temp, '${version.id}.json'));
    final j = asMap(decodeJson(await oldJson.readAsString()));
    j['id'] = newId;
    if (j['jar'] == version.id) j['jar'] = newId;
    await oldJson.delete();
    await writeJson(p.join(temp, '$newId.json'), j);
    final jar = File(p.join(temp, '${version.id}.jar'));
    if (await jar.exists()) await jar.rename(p.join(temp, '$newId.jar'));
    final meta = File(p.join(temp, 'mcd.json'));
    if (await meta.exists()) {
      final data = asMap(decodeJson(await meta.readAsString()))..['id'] = newId;
      await writeJson(meta.path, data);
    }
    await Directory(dest).parent.create(recursive: true);
    await Directory(temp).rename(dest);
    if (rename) await deleteVersion(version.id);
  }
}

Future<void> syncIsolation(
  String root,
  String versionPath,
  bool isolate,
) async {
  final ini = p.join(versionPath, 'PCL', 'Setup.ini');
  await guardPath(root, ini);
  final file = File(ini);
  await file.parent.create(recursive: true);
  var text = await file.exists() ? await file.readAsString() : '';
  text = text.replaceAll(
    RegExp(
      r'^VersionArgumentIndie(?:V2)?:[^\r\n]*(?:\r?\n|$)',
      multiLine: true,
    ),
    '',
  );
  await file.writeAsString(
    '$text\r\nVersionArgumentIndieV2:${isolate ? 'True' : 'False'}\r\nVersionArgumentIndie:${isolate ? 1 : 2}\r\n',
  );
  final oldPath = p.join(versionPath, 'hmclversion.cfg');
  await guardPath(root, oldPath);
  final oldFile = File(oldPath);
  final old = await oldFile.exists()
      ? asMap(decodeJson(await oldFile.readAsString()))
      : <String, dynamic>{};
  old.addAll({'usesGlobal': false, 'gameDirType': isolate ? 1 : 0});
  await writeJson(oldPath, old);
  final newPath = p.join(
    versionPath,
    '.hmcl',
    'config',
    'instance-game-settings.json',
  );
  await guardPath(root, newPath);
  final newFile = File(newPath);
  final config = await newFile.exists()
      ? asMap(decodeJson(await newFile.readAsString()))
      : <String, dynamic>{};
  config['overrideProperties'] = {
    ...asList(config['overrideProperties']).cast<String>(),
    'runningDirectory',
  }.toList();
  config['runningDirectory'] = isolate ? '' : root;
  await writeJson(newPath, config);
}

Future<void> copyTree(
  String source,
  String destination, {
  Set<String> exclude = const {},
  void Function()? check,
}) async {
  final src = Directory(source);
  await Directory(destination).create(recursive: true);
  await for (final entity in src.list(recursive: true, followLinks: false)) {
    check?.call();
    final relative = p
        .relative(entity.path, from: source)
        .replaceAll('\\', '/');
    if (exclude.contains(relative) ||
        exclude.contains(relative.split('/').first)) {
      continue;
    }
    if (entity is Link) throw const FileSystemException('目录包含链接，不能自动复制');
    final target = safeChild(
      destination,
      p.relative(entity.path, from: source),
    );
    await guardPath(destination, target);
    if (entity is Directory) {
      await Directory(target).create(recursive: true);
    }
    if (entity is File) {
      await File(target).parent.create(recursive: true);
      await entity.copy(target);
    }
  }
}
