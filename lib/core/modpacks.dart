// Pack manifest detection follows the formats handled by PCL and HMCL.
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart' show ZipFileEncoder;
import 'package:path/path.dart' as p;
import 'installer.dart';
import 'models.dart';
import 'network.dart';
import 'repository.dart';
import 'resources.dart';

class PackInfo {
  final String file, prefix, format, name, game, loader, loaderVersion;
  final Json manifest;
  PackInfo({
    required this.file,
    required this.prefix,
    required this.format,
    required this.name,
    required this.game,
    this.loader = '',
    this.loaderVersion = '',
    required this.manifest,
  });
}

class ModpackService {
  final MinecraftInstaller installer;
  final ResourceService resources;
  ModpackService(this.installer, this.resources);
  Future<PackInfo> inspect(String file) async {
    final archive = await readZip(file);
    String? key;
    for (final candidate in [
      'modrinth.index.json',
      'mcbbs.packmeta',
      'mmc-pack.json',
      'modpack.json',
      'manifest.json',
    ]) {
      key = archive.files
          .where(
            (f) =>
                f.isFile &&
                (f.name == candidate ||
                    (f.name.endsWith('/$candidate') &&
                        f.name.split('/').length == 2)),
          )
          .map((f) => f.name)
          .firstOrNull;
      if (key != null) break;
    }
    if (key == null) {
      throw const FormatException(
        '没有找到支持的整合包清单。支持 mrpack、CurseForge、HMCL、MCBBS、MultiMC；普通游戏目录请在版本管理中添加',
      );
    }
    final prefix = key.contains('/') ? '${key.split('/').first}/' : '';
    final json = archiveJson(archive, key);
    var format = p.basename(key);
    var game = '';
    var loader = '';
    var loaderVersion = '';
    if (format == 'modrinth.index.json') {
      if (json['game'] != 'minecraft' || json['formatVersion'] != 1) {
        throw const FormatException('不支持此 mrpack 格式或游戏');
      }
      final deps = asMap(json['dependencies']);
      game = deps['minecraft'] ?? '';
      final loaders = {
        'fabric-loader': 'Fabric',
        'quilt-loader': 'Quilt',
        'forge': 'Forge',
        'neoforge': 'NeoForge',
      };
      for (final e in deps.entries) {
        if (e.key != 'minecraft' && !loaders.containsKey(e.key)) {
          throw StateError('不支持的整合包组件：${e.key}');
        }
        if (loaders.containsKey(e.key)) {
          if (loader.isNotEmpty) throw StateError('整合包声明了多个互斥加载器');
          loader = loaders[e.key]!;
          loaderVersion = e.value;
        }
      }
      format = 'Modrinth';
    } else if (format == 'mmc-pack.json') {
      for (final raw in asList(json['components'])) {
        final c = asMap(raw);
        final uid = c['uid'];
        if (uid == 'net.minecraft') {
          game = c['version'] ?? '';
          continue;
        }
        final name = {
          'net.fabricmc.fabric-loader': 'Fabric',
          'org.quiltmc.quilt-loader': 'Quilt',
          'net.minecraftforge': 'Forge',
          'net.neoforged': 'NeoForge',
        }[uid];
        if (name != null) {
          if (loader.isNotEmpty) throw StateError('此 MultiMC 包包含多个加载器，暂不能转换');
          loader = name;
          loaderVersion = c['version'] ?? '';
        } else if (![
          'org.lwjgl',
          'org.lwjgl3',
          'net.fabricmc.intermediary',
        ].contains(uid)) {
          throw StateError('此 MultiMC 包需要额外组件 $uid，暂不能自动转换');
        }
      }
      if (archive.files.any((f) => f.name.startsWith('${prefix}patches/'))) {
        throw StateError('此 MultiMC 包包含自定义补丁，不能按标准组件无损转换');
      }
      format = 'MultiMC';
    } else if (format == 'modpack.json') {
      game = json['gameVersion'] ?? '';
      loader = json['loader'] ?? '';
      loaderVersion = json['loaderVersion'] ?? '';
      format = 'HMCL';
      if (archive.findFile('${prefix}minecraft/pack.json') != null) {
        final patch = archiveJson(archive, '${prefix}minecraft/pack.json');
        if (patch['patches'] != null) {
          throw StateError('此 HMCL 包包含非标准补丁，请先用原启动器导出为 mrpack');
        }
        json['_embeddedPatch'] = patch;
      }
    } else if (json['addons'] != null || format == 'mcbbs.packmeta') {
      for (final raw in asList(json['addons'])) {
        final a = asMap(raw);
        final id = a['id'];
        if (id == 'game') game = a['version'] ?? '';
        final name = {
          'forge': 'Forge',
          'neoforge': 'NeoForge',
          'fabric': 'Fabric',
          'quilt': 'Quilt',
          'optifine': 'OptiFine',
        }[id];
        if (name == null && id != 'game' && id != 'java') {
          throw StateError('不支持的 MCBBS 组件：$id');
        }
        if (name != null) {
          if (loader.isNotEmpty) {
            throw StateError('此整合包使用组合组件，请先导出为标准单加载器 mrpack');
          }
          loader = name;
          loaderVersion = a['version'] ?? '';
        }
      }
      format = 'MCBBS';
    } else {
      final mc = asMap(json['minecraft']);
      game = mc['version'] ?? '';
      final loaders = asList(mc['modLoaders']);
      final selected =
          loaders.where((e) => e['primary'] == true).firstOrNull ??
          loaders.firstOrNull;
      if (selected != null) {
        final id = selected['id'] as String;
        for (final name in ['neoforge', 'forge', 'fabric', 'quilt']) {
          if (id.startsWith('$name-')) {
            loader = {
              'neoforge': 'NeoForge',
              'forge': 'Forge',
              'fabric': 'Fabric',
              'quilt': 'Quilt',
            }[name]!;
            loaderVersion = id.substring(name.length + 1);
            break;
          }
        }
        if (loader.isEmpty) throw StateError('不支持的 CurseForge 加载器 $id');
      }
      format = 'CurseForge';
    }
    if (game.isEmpty) throw const FormatException('整合包缺少 Minecraft 版本');
    if (loader == 'Forge' && !loaderVersion.startsWith('$game-')) {
      loaderVersion = '$game-$loaderVersion';
    }
    if (loader == 'NeoForge' &&
        game == '1.20.1' &&
        !loaderVersion.startsWith('$game-')) {
      loaderVersion = '$game-$loaderVersion';
    }
    return PackInfo(
      file: file,
      prefix: prefix,
      format: format,
      name: json['name'] ?? p.basenameWithoutExtension(file),
      game: game,
      loader: loader,
      loaderVersion: loaderVersion,
      manifest: json,
    );
  }

  Future<void> install(
    PackInfo info,
    String root,
    String id,
    DownloadJob job,
  ) async {
    final archive = await readZip(info.file);
    job.check();
    if (info.format == 'CurseForge' ||
        (info.format == 'MCBBS' &&
            asList(
              info.manifest['files'],
            ).any((f) => asMap(f)['type'] == 'curse')) ||
        (info.format == 'Modrinth' &&
            asList(info.manifest['files']).any(
              (f) =>
                  ![
                    'unsupported',
                    'optional',
                  ].contains(asMap(asMap(f)['env'])['client']) &&
                  asList(
                    asMap(f)['downloads'],
                  ).any((url) => isCurseForgeEndpoint(Uri.parse('$url'))),
            ))) {
      installer.network.requireCurseForgeKey();
    }
    final spec = InstallSpec(
      root: root,
      id: id,
      game: info.game,
      loader: info.loader,
      loaderVersion: info.loaderVersion,
      isolate: true,
    );
    await installer.install(
      spec,
      job,
      populate: (content, manifest) async {
        job.stage = '安装整合包文件';
        job.notify();
        final files = <DownloadFile>[];
        if (info.format == 'Modrinth') {
          for (final raw in asList(info.manifest['files'])) {
            final f = asMap(raw);
            final env = asMap(f['env']);
            if (env['client'] == 'unsupported' || env['client'] == 'optional') {
              job.log('跳过客户端 ${env['client']} 文件：${f['path']}');
              continue;
            }
            final target = safeChild(content, f['path']);
            await guardPath(root, target);
            final hashes = asMap(f['hashes']);
            files.add(
              DownloadFile(
                target,
                asList(f['downloads']).cast<String>(),
                hash: hashes['sha512'] ?? hashes['sha1'],
                algorithm: hashes['sha512'] == null ? 'sha1' : 'sha512',
                size: f['fileSize'],
              ),
            );
          }
        } else if (info.format == 'CurseForge') {
          for (final raw in asList(info.manifest['files'])) {
            job.check();
            final f = asMap(raw);
            if (f['required'] == false) continue;
            final version = await resources.curseFile(
              '${f['projectID']}',
              '${f['fileID']}',
              job: job,
            );
            final target = safeChild(content, 'mods/${version['filename']}');
            await guardPath(root, target);
            files.add(resources.downloadFile(version, target));
          }
        }
        await installer.network.batch(files, job);
        final directories = switch (info.format) {
          'Modrinth' => ['overrides/', 'client-overrides/'],
          'CurseForge' => ['${info.manifest['overrides'] ?? 'overrides'}/'],
          'HMCL' => ['minecraft/'],
          'MultiMC' => ['.minecraft/', 'minecraft/'],
          _ => ['overrides/'],
        };
        for (final relative in directories) {
          await extractPrefix(
            archive,
            '${info.prefix}$relative',
            content,
            root,
            job,
          );
        }
        if (info.format == 'MCBBS') {
          final additions = <DownloadFile>[];
          for (final raw in asList(info.manifest['files'])) {
            final file = asMap(raw);
            job.check();
            if (file['type'] == 'curse') {
              final version = await resources.curseFile(
                '${file['projectID']}',
                '${file['fileID']}',
                job: job,
              );
              final target = safeChild(content, 'mods/${version['filename']}');
              await guardPath(root, target);
              additions.add(resources.downloadFile(version, target));
            } else if (file['type'] == 'addon') {
              final target = safeChild(content, file['path']);
              await guardPath(root, target);
              final hash = file['hash'] as String?;
              if (await validFile(DownloadFile(target, [], hash: hash))) {
                continue;
              }
              final api = info.manifest['fileApi'] as String? ?? '';
              if (api.isEmpty) {
                throw StateError(
                  'MCBBS 包内缺少或损坏文件 ${file['path']}，也未提供 fileApi',
                );
              }
              final relative = (file['path'] as String)
                  .split('/')
                  .map(Uri.encodeComponent)
                  .join('/');
              additions.add(
                DownloadFile(target, [
                  '${api.replaceAll(RegExp(r'/+$'), '')}/overrides/$relative',
                ], hash: hash),
              );
            } else {
              throw StateError('未知 MCBBS 文件类型 ${file['type']}');
            }
          }
          await installer.network.batch(additions, job);
        }
        final extra = asMap(info.manifest['_embeddedPatch']);
        if (info.format == 'MCBBS') {
          extra['libraries'] = asList(info.manifest['libraries']);
        }
        if (extra.isNotEmpty) {
          final merged = mergeManifest(manifest, extra)..['id'] = id;
          merged.remove('inheritsFrom');
          merged.remove('jar');
          final libraries = installer.libraries(
            root,
            asList(extra['libraries']),
          );
          for (final file in libraries) {
            await guardPath(root, file.path);
          }
          await installer.network.batch(libraries, job);
          manifest
            ..clear()
            ..addAll(merged);
        }
        await writeJson(p.join(content, '.mcd-pack.json'), {
          'format': info.format,
          'name': info.name,
          'sourceFile': p.basename(info.file),
        });
      },
    );
  }

  Future<void> installWorld(
    String archivePath,
    LocalVersion target,
    String name,
    DownloadJob job,
  ) async {
    validateId(name);
    final archive = await readZip(archivePath);
    final level = archive.files
        .where(
          (f) =>
              f.isFile &&
              (f.name == 'level.dat' || f.name.endsWith('/level.dat')),
        )
        .toList();
    if (level.length != 1) throw StateError('世界压缩包需要包含且只包含一个 level.dat');
    final key = level.first.name;
    final prefix = key.substring(0, key.length - 'level.dat'.length);
    final dest = safeChild(target.contentPath, 'saves/$name');
    if (await Directory(dest).exists()) throw StateError('同名世界已存在');
    await guardPath(target.contentPath, dest);
    final temp = safeChild(target.contentPath, '.mcd-world/${job.id}');
    await extractPrefix(archive, prefix, temp, target.contentPath, job);
    job.check();
    await Directory(dest).parent.create(recursive: true);
    await Directory(temp).rename(dest);
  }

  Future<void> export(
    LocalVersion target,
    String destination,
    DownloadJob job,
  ) async {
    if (target.loader == 'OptiFine') {
      throw StateError('独立 OptiFine 安装不能用标准 mrpack 描述，请改为导出文件夹');
    }
    job.stage = '打包本地内容';
    job.notify();
    final source = target.contentPath;
    final deps = <String, String>{'minecraft': target.game};
    final key = {
      'Fabric': 'fabric-loader',
      'Quilt': 'quilt-loader',
      'Forge': 'forge',
      'NeoForge': 'neoforge',
    }[target.loader];
    if (key != null) {
      deps[key] = target.loader == 'Forge'
          ? target.loaderVersion.replaceFirst('${target.game}-', '')
          : target.loaderVersion;
    }
    final index = {
      'formatVersion': 1,
      'game': 'minecraft',
      'versionId': '1.0.0',
      'name': target.id,
      'files': [],
      'dependencies': deps,
    };
    final temp = '$destination.part';
    await Isolate.run(() async {
      File(temp).parent.createSync(recursive: true);
      final encoder = ZipFileEncoder()..create(temp);
      try {
        final json = utf8.encode(pretty(index));
        encoder.addArchiveFile(
          ArchiveFile('modrinth.index.json', json.length, json),
        );
        for (final dir in [
          'mods',
          'config',
          'defaultconfigs',
          'resourcepacks',
          'shaderpacks',
          'kubejs',
          'scripts',
        ]) {
          final folder = Directory(p.join(source, dir));
          if (!folder.existsSync()) continue;
          for (final entity in folder.listSync(
            recursive: true,
            followLinks: false,
          )) {
            if (entity is Link) throw const FileSystemException('导出内容包含链接');
            if (entity is! File || entity.path.endsWith('.part')) continue;
            await encoder.addFile(
              entity,
              'overrides/${p.relative(entity.path, from: source).replaceAll('\\', '/')}',
            );
          }
        }
      } finally {
        await encoder.close();
      }
    });
    job.check();
    if (await File(destination).exists()) throw StateError('导出目标已存在，请更换文件名');
    await File(temp).rename(destination);
    job.log('已导出 $destination（不包含存档和账号）');
  }
}

Future<void> extractPrefix(
  Archive archive,
  String prefix,
  String destination,
  String root,
  DownloadJob job,
) async {
  for (final entry in archive.files) {
    job.check();
    if (!entry.name.startsWith(prefix) || entry.name == prefix) continue;
    if (entry.isSymbolicLink) throw const FormatException('压缩包包含符号链接，已拒绝解压');
    final relative = entry.name.substring(prefix.length);
    if (relative.isEmpty || relative.endsWith('/')) continue;
    final target = safeChild(destination, relative);
    await guardPath(root, target);
    final normalized = relative.replaceAll('\\', '/').toLowerCase();
    // Pack overrides may not replace application manifests or launcher account data.
    if ([
          'accounts.json',
          'launcher_accounts.json',
          'mcd.json',
        ].contains(p.basename(target).toLowerCase()) ||
        normalized.startsWith('versions/') ||
        normalized.startsWith('.hmcl/')) {
      continue;
    }
    if (entry.isFile) {
      await File(target).parent.create(recursive: true);
      await File(target).writeAsBytes(entry.content);
    }
  }
}
