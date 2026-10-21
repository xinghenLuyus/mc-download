// SPDX-License-Identifier: MIT
// Copyright (c) 2026 MC Download contributors.
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'models.dart';
import 'network.dart';
import 'repository.dart';
import 'java_runtime.dart';

class MinecraftInstaller {
  final NetworkService network;
  final String cache;
  MinecraftInstaller(this.network, this.cache);
  List<GameVersion> versions = [];
  Future<List<JavaRuntime>>? _javaRuntimes;
  String? _javaJobId;
  Future<List<GameVersion>> fetchVersions() async {
    final j = asMap(
      await network.json(network.sources.candidates(SourcePolicy.manifest)),
    );
    versions = asList(
      j['versions'],
    ).map((e) => GameVersion.fromJson(asMap(e))).toList();
    if (versions.isEmpty) throw const FormatException('版本列表为空');
    await writeJson(p.join(cache, 'version-manifest.json'), j);
    return versions;
  }

  Future<Json> vanilla(String id, DownloadJob job, [Set<String>? chain]) async {
    validateId(id);
    chain ??= {};
    if (!chain.add(id) || chain.length > 20) {
      throw const FormatException('远程版本继承存在循环');
    }
    if (versions.isEmpty) await fetchVersions();
    final entry = versions.where((v) => v.id == id).firstOrNull;
    if (entry == null) throw StateError('官方版本列表没有 $id');
    final file = p.join(cache, 'metadata', '$id.json');
    await network.download(
      DownloadFile(
        file,
        network.sources.candidates(entry.url),
        hash: entry.sha1,
      ),
      job,
    );
    final json = asMap(decodeJson(await File(file).readAsString()));
    return json['inheritsFrom'] is String
        ? mergeManifest(await vanilla(json['inheritsFrom'], job, chain), json)
        : json;
  }

  Future<List<Json>> loaderVersions(String game, String loader) async {
    final encoded = Uri.encodeComponent(game);
    if (loader == 'Fabric' || loader == 'Quilt') {
      final base = loader == 'Fabric'
          ? 'https://meta.fabricmc.net/v2'
          : 'https://meta.quiltmc.org/v3';
      final j = await network.json(
        network.sources.candidates('$base/versions/loader/$encoded'),
      );
      final rows = asList(j).map((raw) {
        final l = asMap(asMap(raw)['loader']);
        return {
          'version': l['version'],
          'stable':
              l['stable'] ??
              !'${l['version']}'.contains(RegExp('beta|alpha|pre')),
        };
      }).toList();
      rows.sort(
        (a, b) => compareVersionNumbers(
          b['version'] as String,
          a['version'] as String,
        ),
      );
      return rows;
    }
    if (loader == 'Forge') {
      final xml = await network.text(
        network.sources.candidates(
          'https://maven.minecraftforge.net/net/minecraftforge/forge/maven-metadata.xml',
        ),
        validate: (text) => RegExp(r'<(?:\w+:)?versions\s*>').hasMatch(text),
      );
      final rows =
          mavenVersions(xml).where((v) => v.startsWith('$game-')).toList()
            ..sort(compareVersionNumbers);
      return rows.reversed
          .map((v) => {'version': v, 'stable': !v.contains('beta')})
          .toList();
    }
    if (loader == 'NeoForge') {
      final official =
          'https://maven.neoforged.net/api/maven/versions/releases/net/neoforged/${game == '1.20.1' ? 'forge' : 'neoforge'}';
      final mirror = '${network.settings.mirrorUrl}/neoforge/list/$encoded';
      final urls = network.settings.sourceMode == SourceMode.official
          ? [official, mirror]
          : [mirror, official];
      Object? failure;
      for (final url in network.settings.fallback ? urls : urls.take(1)) {
        try {
          final data = await network.json([url]);
          final values = data is List
              ? data.map((e) {
                  final item = asMap(e);
                  final raw = '${item['rawVersion'] ?? item['version']}';
                  final version = '${item['version'] ?? raw}'.replaceFirst(
                    RegExp(r'^neoforge-'),
                    '',
                  );
                  if (game == '1.20.1' && !version.startsWith('$game-')) {
                    return raw.startsWith('$game-')
                        ? raw.replaceFirst('$game-forge-', '$game-')
                        : '$game-$version';
                  }
                  return version;
                }).toList()
              : asList(asMap(data)['versions'])
                    .cast<String>()
                    .where(
                      (v) => game == '1.20.1'
                          ? v.startsWith('1.20.1-')
                          : neoForgeGame(v) == game,
                    )
                    .toList();
          final distinct = values.toSet().toList()..sort(compareVersionNumbers);
          return distinct.reversed
              .map(
                (v) => {
                  'version': v,
                  'stable': !v.contains('beta') && !v.contains('alpha'),
                },
              )
              .toList();
        } catch (e) {
          failure = e;
        }
      }
      throw failure ?? StateError('无法获取 NeoForge 版本列表');
    }
    if (loader == 'OptiFine') {
      final v = game == '1.8' || game == '1.9' ? '$game.0' : game;
      final j = await network.json([
        '${network.settings.mirrorUrl}/optifine/$v',
      ]);
      return asList(j)
          .map(
            (e) => {
              'version': '${e['type']}_${e['patch']}',
              'stable': !'${e['patch']}'.contains('pre'),
            },
          )
          .toList();
    }
    return [];
  }

  Future<void> install(
    InstallSpec spec,
    DownloadJob job, {
    Future<void> Function(String content, Json manifest)? populate,
  }) async {
    validateId(spec.id);
    validateId(spec.game);
    final target = safeChild(spec.root, 'versions/${spec.id}');
    await guardPath(spec.root, target);
    final backup = safeChild(spec.root, '.mcd-trash/${job.id}-${spec.id}');
    // A process can terminate between the two directory renames. On retry,
    // restore that task's exact backup before preparing another replacement.
    if (spec.replace &&
        !await Directory(target).exists() &&
        await Directory(backup).exists()) {
      await guardPath(spec.root, backup);
      await Directory(target).parent.create(recursive: true);
      await Directory(backup).rename(target);
      job.log('已恢复上次提交中断前的版本');
    }
    final replacing = spec.replace && await Directory(target).exists();
    String? originalHash;
    if (await Directory(target).exists() && !replacing) {
      throw StateError('版本 ${spec.id} 已存在，请更换安装名称');
    }
    if (replacing) {
      final original = File(p.join(target, '${spec.id}.json'));
      originalHash = await original.exists()
          ? await fileHash(original.path, 'sha1')
          : null;
      for (final other in await GameRepository(spec.root).scan()) {
        if (other.id == spec.id) continue;
        if (other.error.isNotEmpty) continue;
        final own = asMap(
          decodeJson(
            await File(p.join(other.path, '${other.id}.json')).readAsString(),
          ),
        );
        if (own['inheritsFrom'] == spec.id || own['jar'] == spec.id) {
          throw StateError('${other.id} 依赖此版本，请复制后修改');
        }
      }
    }
    // Stable across retries, separate from the versions scanned by launchers.
    final working = safeChild(spec.root, '.mcd-staging/${job.id}');
    await guardPath(spec.root, working);
    await Directory(working).create(recursive: true);
    job.stage = '读取版本元数据';
    job.notify();
    var manifest = await vanilla(spec.game, job);
    final client = asMap(asMap(manifest['downloads'])['client']);
    if (client['url'] == null) throw const FormatException('该版本没有客户端文件');
    final jar = p.join(working, '${spec.id}.jar');
    job.stage = '下载游戏本体';
    job.notify();
    await network.download(
      DownloadFile(
        jar,
        network.sources.candidates(
          client['url'],
          mirrorPath: '/version/${Uri.encodeComponent(spec.game)}/client',
        ),
        hash: client['sha1'],
        size: client['size'],
      ),
      job,
    );
    if (spec.loader.isNotEmpty) {
      job.stage = '安装 ${spec.loader} ${spec.loaderVersion}';
      job.notify();
      if (spec.loader == 'Fabric' || spec.loader == 'Quilt') {
        final base = spec.loader == 'Fabric'
            ? 'https://meta.fabricmc.net/v2'
            : 'https://meta.quiltmc.org/v3';
        final patch = asMap(
          await network.json(
            network.sources.candidates(
              '$base/versions/loader/${Uri.encodeComponent(spec.game)}/${Uri.encodeComponent(spec.loaderVersion)}/profile/json',
            ),
            job: job,
          ),
        );
        manifest = mergeManifest(manifest, patch);
      } else if (spec.loader == 'Forge' || spec.loader == 'NeoForge') {
        manifest = await _forge(spec, manifest, jar, working, job);
      } else if (spec.loader == 'OptiFine') {
        manifest = await _optifine(spec, manifest, jar, job);
      } else {
        throw UnsupportedError('不支持的加载器：${spec.loader}');
      }
    }
    manifest['id'] = spec.id;
    manifest['clientVersion'] = spec.game;
    manifest.remove('inheritsFrom');
    manifest.remove('jar');
    final content = spec.isolate ? working : spec.root;
    await complete(spec.root, manifest, spec.game, job, contentPath: content);
    if (replacing) {
      job.stage = '保留现有版本内容';
      job.notify();
      // Refresh preserved content after downloads. A resumed task must not
      // resurrect mods or worlds removed since its previous attempt.
      await for (final entry in Directory(working).list(followLinks: false)) {
        job.check();
        if (p.basename(entry.path) == '${spec.id}.jar' ||
            p.basename(entry.path) == 'resources') {
          continue;
        }
        await entry.delete(recursive: true);
      }
      await copyTree(
        target,
        working,
        exclude: {'${spec.id}.json', '${spec.id}.jar', 'mcd.json', 'resources'},
        check: job.check,
      );
    }
    if (populate != null) await populate(content, manifest);
    for (final dir in ['mods', 'resourcepacks', 'shaderpacks', 'saves']) {
      final path = safeChild(content, dir);
      await guardPath(spec.root, path);
      await Directory(path).create(recursive: true);
    }
    await writeJson(p.join(working, '${spec.id}.json'), manifest);
    await writeJson(p.join(working, 'mcd.json'), spec.toJson());
    // Minimal launcher interoperability settings. No account or global config changes.
    await syncIsolation(spec.root, working, spec.isolate);
    job.check();
    job.stage = '提交安装结果';
    job.notify();
    if (await Directory(target).exists() && !replacing) {
      throw StateError('安装过程中出现同名版本，停止覆盖');
    }
    await Directory(target).parent.create(recursive: true);
    job.committing = true;
    try {
      if (replacing) {
        final original = File(p.join(target, '${spec.id}.json'));
        final currentHash = await original.exists()
            ? await fileHash(original.path, 'sha1')
            : null;
        if (currentHash != originalHash) {
          throw StateError('安装期间原版本被外部程序修改，停止覆盖');
        }
        await guardPath(spec.root, backup);
        if (await Directory(backup).exists()) {
          throw StateError('此任务的备份目录已存在，请检查 .mcd-trash 后重新建立安装任务');
        }
        await Directory(backup).parent.create(recursive: true);
        await Directory(target).rename(backup);
        try {
          await Directory(working).rename(target);
        } catch (_) {
          await Directory(backup).rename(target);
          rethrow;
        }
        job.log('原版本已备份到 $backup');
      } else {
        await Directory(working).rename(target);
      }
    } finally {
      job.committing = false;
    }
    job.log('已安装到 $target');
  }

  List<DownloadFile> libraries(
    String root,
    List<dynamic> entries, {
    bool allowGenerated = false,
  }) {
    final files = <DownloadFile>[];
    for (final raw in entries) {
      final lib = asMap(raw);
      if (!windowsRules(lib['rules'], network.settings.arch)) continue;
      final coordinate = lib['name'] as String? ?? '';
      final nativeClassifier = coordinate.split(':').last;
      if (nativeClassifier.startsWith('natives-windows')) {
        final required =
            nativeClassifier.contains('arm64') ||
                nativeClassifier.contains('aarch64')
            ? 'arm64'
            : nativeClassifier.endsWith('-x86') ||
                  nativeClassifier.endsWith('-32')
            ? 'x86'
            : 'x64';
        if (network.settings.arch != required) continue;
      }
      final downloads = asMap(lib['downloads']);
      final artifacts = <Json>[];
      if (downloads['artifact'] != null) {
        artifacts.add(asMap(downloads['artifact']));
      } else if (downloads.isEmpty &&
          lib['name'] is String &&
          asMap(lib['natives']).isEmpty) {
        final path = mavenPath(lib['name']);
        if (lib['url'] != '') {
          artifacts.add({
            'path': path,
            'url':
                '${lib['url'] ?? 'https://libraries.minecraft.net/'}${(lib['url'] as String? ?? '/').endsWith('/') ? '' : '/'}$path',
          });
        } else if (!allowGenerated &&
            !File(safeChild(root, 'libraries/$path')).existsSync()) {
          throw StateError('缺少安装器生成文件：$path');
        }
      }
      final native = asMap(lib['natives'])['windows'];
      if (native is String) {
        final classifier = native.replaceAll(
          r'${arch}',
          network.settings.arch == 'x86' ? '32' : '64',
        );
        final artifact = asMap(asMap(downloads['classifiers'])[classifier]);
        if (artifact.isNotEmpty) artifacts.add(artifact);
      }
      for (final item in artifacts) {
        final path =
            item['path'] as String? ??
            (lib['name'] is String ? mavenPath(lib['name']) : null);
        if (path == null) throw const FormatException('支持库缺少路径');
        final target = safeChild(root, 'libraries/$path');
        final url = item['url'] as String? ?? '';
        if (url.isEmpty) {
          if (!allowGenerated && !File(target).existsSync()) {
            throw StateError('缺少生成的支持库 $path');
          }
          continue;
        }
        files.add(
          DownloadFile(
            target,
            network.sources.candidates(url),
            hash: item['sha1'],
            size: item['size'],
          ),
        );
      }
    }
    return files;
  }

  Future<void> complete(
    String root,
    Json manifest,
    String game,
    DownloadJob job, {
    String? contentPath,
  }) async {
    job.stage = '校验并补全支持库';
    job.notify();
    final libs = libraries(root, asList(manifest['libraries']));
    for (final f in libs) {
      await guardPath(root, f.path);
    }
    await network.batch(libs, job);
    final asset = asMap(manifest['assetIndex']);
    if (asset.isEmpty) {
      job.log('此历史版本没有 assetIndex，保留原有资源规则');
      return;
    }
    final indexId = '${asset['id']}';
    validateId(indexId);
    final indexPath = safeChild(root, 'assets/indexes/$indexId.json');
    await guardPath(root, indexPath);
    job.stage = '获取资源索引';
    job.notify();
    await network.download(
      DownloadFile(
        indexPath,
        network.sources.candidates(asset['url']),
        hash: asset['sha1'],
        size: asset['size'],
      ),
      job,
    );
    final index = asMap(decodeJson(await File(indexPath).readAsString()));
    final objects = asMap(index['objects']);
    final files = <DownloadFile>[];
    for (final raw in objects.values) {
      final o = asMap(raw);
      final hash = o['hash'] as String;
      if (!RegExp(r'^[a-f0-9]{40}$').hasMatch(hash)) {
        throw const FormatException('资源索引哈希无效');
      }
      final path = safeChild(
        root,
        'assets/objects/${hash.substring(0, 2)}/$hash',
      );
      await guardPath(root, path);
      files.add(
        DownloadFile(
          path,
          network.sources.candidates(
            'https://resources.download.minecraft.net/${hash.substring(0, 2)}/$hash',
          ),
          hash: hash,
          size: o['size'],
        ),
      );
    }
    job.stage = '下载资源文件（${files.length} 项）';
    job.notify();
    await network.batch(files, job);
    if (index['virtual'] == true) {
      for (final entry in objects.entries) {
        job.check();
        final hash = entry.value['hash'] as String;
        final dest = safeChild(root, 'assets/virtual/$indexId/${entry.key}');
        await guardPath(root, dest);
        await File(dest).parent.create(recursive: true);
        await File(
          p.join(root, 'assets', 'objects', hash.substring(0, 2), hash),
        ).copy(dest);
      }
    }
    if (index['map_to_resources'] == true) {
      final content = contentPath ?? root;
      for (final entry in objects.entries) {
        job.check();
        final hash = entry.value['hash'] as String;
        final dest = safeChild(content, 'resources/${entry.key}');
        await guardPath(content, dest);
        await File(dest).parent.create(recursive: true);
        await File(
          p.join(root, 'assets', 'objects', hash.substring(0, 2), hash),
        ).copy(dest);
      }
    }
  }

  Future<void> repair(
    LocalVersion version,
    DownloadJob job, {
    String? gameOverride,
  }) async {
    final game = gameOverride ?? version.game;
    final ownFile = File(p.join(version.path, '${version.id}.json'));
    Json own = {};
    try {
      own = asMap(decodeJson(await ownFile.readAsString()));
    } catch (_) {}
    if (own.isEmpty &&
        version.loader.isNotEmpty &&
        version.loaderVersion.isNotEmpty) {
      await install(
        InstallSpec(
          root: version.root,
          id: version.id,
          game: game,
          loader: version.loader,
          loaderVersion: version.loaderVersion,
          isolate: version.contentPath == version.path,
          replace: true,
        ),
        job,
      );
      return;
    }
    Future<Json> resolve(String id, Set<String> seen) async {
      validateId(id);
      if (!seen.add(id) || seen.length > 20) {
        throw const FormatException('版本继承存在循环或层级过深');
      }
      final file = File(safeChild(version.root, 'versions/$id/$id.json'));
      Json json = {};
      try {
        json = asMap(decodeJson(await file.readAsString()));
      } catch (_) {}
      if (json.isEmpty) {
        if (versions.isEmpty) await fetchVersions();
        final remoteId = id == version.id ? game : id;
        if (!versions.any((v) => v.id == remoteId)) {
          throw StateError('缺少父版本 $id，无法自动恢复自定义加载器。请恢复备份或使用“调整组件”重建。');
        }
        json = {
          ...await vanilla(remoteId, job),
          'id': id,
          'clientVersion': remoteId,
        };
        await guardPath(version.root, file.path);
        if (await file.exists()) {
          await file.copy(
            '${file.path}.before-repair-${DateTime.now().millisecondsSinceEpoch}',
          );
        }
        await writeJson(file.path, json);
        job.log('已恢复版本描述 $id');
      }
      final parent = json['inheritsFrom'];
      return parent is String
          ? mergeManifest(await resolve(parent, seen), json)
          : json;
    }

    var manifest = await resolve(version.id, {});
    if (asMap(asMap(manifest['downloads'])['client']).isEmpty ||
        asMap(manifest['assetIndex']).isEmpty) {
      manifest = mergeManifest(await vanilla(game, job), manifest);
    }
    final client = asMap(asMap(manifest['downloads'])['client']);
    Future<String> jarOwner(String id, Set<String> seen) async {
      validateId(id);
      if (!seen.add(id) || seen.length > 20) {
        throw const FormatException('客户端 JAR 继承存在循环');
      }
      final json = asMap(
        decodeJson(
          await File(
            safeChild(version.root, 'versions/$id/$id.json'),
          ).readAsString(),
        ),
      );
      if (json['jar'] is String) return json['jar'];
      if (await File(
        safeChild(version.root, 'versions/$id/$id.jar'),
      ).exists()) {
        return id;
      }
      if (json['inheritsFrom'] is String) {
        return jarOwner(json['inheritsFrom'], seen);
      }
      return id;
    }

    if (client['url'] != null) {
      final owner = await jarOwner(version.id, {});
      validateId(owner);
      final path = safeChild(version.root, 'versions/$owner/$owner.jar');
      await guardPath(version.root, path);
      await network.download(
        DownloadFile(
          path,
          network.sources.candidates(
            client['url'],
            mirrorPath: '/version/${Uri.encodeComponent(game)}/client',
          ),
          hash: client['sha1'],
          size: client['size'],
        ),
        job,
      );
    }
    try {
      await complete(
        version.root,
        manifest,
        game,
        job,
        contentPath: version.contentPath,
      );
    } on StateError catch (e) {
      // Generated Forge artifacts have no remote URL: a managed install can
      // safely rerun its processors, rather than repeatedly failing the same repair.
      if (e.message.toString().contains('生成') &&
          ['Forge', 'NeoForge', 'OptiFine'].contains(version.loader)) {
        await install(
          InstallSpec(
            root: version.root,
            id: version.id,
            game: game,
            loader: version.loader,
            loaderVersion: version.loaderVersion,
            isolate: version.contentPath == version.path,
            replace: true,
          ),
          job,
        );
      } else {
        rethrow;
      }
    }
  }

  Future<void> saveGame(
    String game,
    bool server,
    String path,
    DownloadJob job,
  ) async {
    final meta = await vanilla(game, job);
    final file = asMap(asMap(meta['downloads'])[server ? 'server' : 'client']);
    if (file['url'] == null) {
      throw StateError('此版本没有提供${server ? '服务端' : '客户端'}文件');
    }
    job.stage = '下载${server ? '服务端' : '客户端'} $game';
    job.notify();
    await network.download(
      DownloadFile(
        path,
        network.sources.candidates(
          file['url'],
          mirrorPath:
              '/version/${Uri.encodeComponent(game)}/${server ? 'server' : 'client'}',
        ),
        hash: file['sha1'],
        size: file['size'],
      ),
      job,
    );
  }

  Future<Json> _forge(
    InstallSpec spec,
    Json base,
    String clientJar,
    String work,
    DownloadJob job,
  ) async {
    final neo = spec.loader == 'NeoForge';
    final artifact = neo
        ? (spec.game == '1.20.1'
              ? 'net.neoforged:forge'
              : 'net.neoforged:neoforge')
        : 'net.minecraftforge:forge';
    final coordinate = '$artifact:${spec.loaderVersion}:installer';
    final relative = mavenPath(coordinate);
    final url =
        '${neo ? 'https://maven.neoforged.net/releases' : 'https://maven.minecraftforge.net'}/$relative';
    final jar = p.join(cache, 'installers', p.basename(relative));
    final archive = await fetchArchive(
      DownloadFile(jar, network.sources.candidates(url)),
      job,
      requiredEntry: 'install_profile.json',
    );
    final profile = archiveJson(archive, 'install_profile.json');
    final modern = profile['json'] is String;
    final patch = modern
        ? archiveJson(
            archive,
            (profile['json'] as String).replaceFirst(RegExp(r'^/'), ''),
          )
        : asMap(profile['versionInfo']);
    if (patch.isEmpty) throw const FormatException('安装器缺少版本信息');
    // Embedded Maven artifacts must exist before resolving processor libraries.
    for (final entry in archive.files.where(
      (f) => f.isFile && f.name.startsWith('maven/'),
    )) {
      final target = safeChild(
        spec.root,
        'libraries/${entry.name.substring(6)}',
      );
      await guardPath(spec.root, target);
      await File(target).parent.create(recursive: true);
      await File(target).writeAsBytes(entry.content);
    }
    if (!modern) {
      final install = asMap(profile['install']);
      final filePath = install['filePath'];
      final path = install['path'];
      if (filePath is String && path is String) {
        final embedded = archive.findFile(filePath);
        if (embedded != null) {
          final target = safeChild(spec.root, 'libraries/${mavenPath(path)}');
          await guardPath(spec.root, target);
          await File(target).parent.create(recursive: true);
          await File(target).writeAsBytes(embedded.content);
        }
      }
    } else {
      final files = libraries(
        spec.root,
        asList(profile['libraries']),
        allowGenerated: true,
      );
      for (final f in files) {
        await guardPath(spec.root, f.path);
      }
      await network.batch(files, job);
      final temp = p.join(work, '.processors');
      await Directory(temp).create(recursive: true);
      final vanillaCopy = p.join(temp, 'minecraft.jar');
      await File(clientJar).copy(vanillaCopy);
      final vars = <String, String>{
        'SIDE': 'client',
        'MINECRAFT_JAR': vanillaCopy,
        'MINECRAFT_VERSION': spec.game,
        'ROOT': work,
        'INSTALLER': jar,
        'LIBRARY_DIR': p.join(spec.root, 'libraries'),
      };
      String literal(String input) {
        if (input.startsWith("'") && input.endsWith("'")) {
          return input.substring(1, input.length - 1);
        }
        if (input.startsWith('[') && input.endsWith(']')) {
          return safeChild(
            spec.root,
            'libraries/${mavenPath(input.substring(1, input.length - 1))}',
          );
        }
        return input.replaceAllMapped(
          RegExp(r'\{([^{}]+)\}'),
          (m) => vars[m[1]] ?? (throw FormatException('未知安装变量 ${m[1]}')),
        );
      }

      for (final entry in asMap(profile['data']).entries) {
        final value = asMap(entry.value)['client'];
        if (value is! String) continue;
        if (value.startsWith('/') && !value.startsWith('//')) {
          final embedded = archive.findFile(value.substring(1));
          if (embedded == null) throw FormatException('安装器缺少 $value');
          final target = safeChild(temp, entry.key);
          await File(target).parent.create(recursive: true);
          await File(target).writeAsBytes(embedded.content);
          vars[entry.key] = target;
        } else {
          vars[entry.key] = literal(value);
        }
      }
      final processors = asList(profile['processors'])
          .map(asMap)
          .where(
            (e) =>
                asList(e['sides']).isEmpty ||
                asList(e['sides']).contains('client'),
          )
          .toList();
      for (var i = 0; i < processors.length; i++) {
        job.check();
        final processor = processors[i];
        job.stage = '${spec.loader} 安装处理器 ${i + 1}/${processors.length}';
        job.notify();
        final outputs = {
          for (final e in asMap(processor['outputs']).entries)
            literal(e.key): literal(e.value),
        };
        for (final output in outputs.keys) {
          await guardPath(spec.root, output);
        }
        var cached = outputs.isNotEmpty;
        for (final entry in outputs.entries) {
          if (!await validFile(
            DownloadFile(entry.key, [], hash: entry.value),
          )) {
            cached = false;
          }
        }
        if (cached) continue;
        final args = asList(
          processor['args'],
        ).cast<String>().map(literal).toList();
        // Keep Mojang mapping downloads on our proxy/source-aware transport.
        if (args.contains('DOWNLOAD_MOJMAPS') && args.contains('--output')) {
          final mappings = asMap(asMap(base['downloads'])['client_mappings']);
          final output = args[args.indexOf('--output') + 1];
          await guardPath(spec.root, output);
          await network.download(
            DownloadFile(
              output,
              network.sources.candidates(mappings['url']),
              hash: mappings['sha1'],
              size: mappings['size'],
            ),
            job,
          );
        } else {
          final processorJar = safeChild(
            spec.root,
            'libraries/${mavenPath(processor['jar'])}',
          );
          final jarArchive = await readZip(processorJar);
          final main = jarMainClass(jarArchive);
          final classpath = [
            ...asList(processor['classpath']).cast<String>().map(
              (c) => safeChild(spec.root, 'libraries/${mavenPath(c)}'),
            ),
            processorJar,
          ].join(Platform.isWindows ? ';' : ':');
          await runJava(
            ['-cp', classpath, main, ...args],
            job,
            workingDirectory: work,
            minimumJava: math.max(
              _classJava(jarArchive, main),
              (asMap(base['javaVersion'])['majorVersion'] as num?)?.toInt() ??
                  8,
            ),
          );
        }
        for (final entry in outputs.entries) {
          if (!await validFile(
            DownloadFile(entry.key, [], hash: entry.value),
          )) {
            throw StateError('安装处理器输出校验失败：${entry.key}');
          }
        }
      }
      await Directory(temp).delete(recursive: true);
    }
    return mergeManifest(base, patch);
  }

  Future<Json> _optifine(
    InstallSpec spec,
    Json base,
    String clientJar,
    DownloadJob job,
  ) async {
    final split = spec.loaderVersion.split('_');
    if (split.length < 3) throw const FormatException('OptiFine 版本格式无效');
    final type = '${split[0]}_${split[1]}';
    final patch = split.sublist(2).join('_');
    final game = ['1.8', '1.9'].contains(spec.game)
        ? '${spec.game}.0'
        : spec.game;
    final jar = p.join(
      cache,
      'installers',
      'OptiFine_${spec.game}_${spec.loaderVersion}.jar',
    );
    job.log('OptiFine 文件由已配置镜像提供：${network.settings.mirrorUrl}');
    final archive = await fetchArchive(
      DownloadFile(jar, [
        '${network.settings.mirrorUrl}/optifine/$game/$type/$patch',
      ]),
      job,
    );
    final coord = 'optifine:OptiFine:${spec.game}_${spec.loaderVersion}';
    final output = safeChild(spec.root, 'libraries/${mavenPath(coord)}');
    await guardPath(spec.root, output);
    await File(output).parent.create(recursive: true);
    if (archive.findFile('optifine/Patcher.class') != null) {
      await runJava(
        ['-cp', jar, 'optifine.Patcher', clientJar, jar, output],
        job,
        minimumJava: _classJava(archive, 'optifine.Patcher'),
      );
    } else {
      await File(jar).copy(output);
    }
    var wrapper = 'net.minecraft:launchwrapper:1.12';
    for (final entry in archive.files.where(
      (f) =>
          f.isFile &&
          RegExp(r'^launchwrapper(?:-of)?-[\w.]+\.jar$').hasMatch(f.name),
    )) {
      final name = p.basenameWithoutExtension(entry.name);
      wrapper = name.startsWith('launchwrapper-of-')
          ? 'optifine:launchwrapper-of:${name.substring(17)}'
          : 'optifine:launchwrapper:${name.substring(14)}';
      final target = safeChild(spec.root, 'libraries/${mavenPath(wrapper)}');
      await guardPath(spec.root, target);
      await File(target).parent.create(recursive: true);
      await File(target).writeAsBytes(entry.content);
      break;
    }
    final patchManifest = <String, dynamic>{
      'mainClass': 'net.minecraft.launchwrapper.Launch',
      'libraries': [
        {'name': coord, 'url': ''},
        {'name': wrapper, if (wrapper.startsWith('optifine:')) 'url': ''},
      ],
    };
    if (base['arguments'] != null) {
      patchManifest['arguments'] = {
        'game': ['--tweakClass', 'optifine.OptiFineTweaker'],
      };
    } else {
      patchManifest['minecraftArguments'] =
          '${base['minecraftArguments'] ?? ''} --tweakClass optifine.OptiFineTweaker';
    }
    return mergeManifest(base, patchManifest);
  }

  Future<Archive> fetchArchive(
    DownloadFile file,
    DownloadJob job, {
    String? requiredEntry,
  }) async {
    for (var attempt = 0; ; attempt++) {
      await network.download(file, job);
      try {
        final archive = await readZip(file.path);
        if (requiredEntry != null && archive.findFile(requiredEntry) == null) {
          throw FormatException('安装器缺少 $requiredEntry');
        }
        return archive;
      } catch (e) {
        if (e is! FormatException && e is! ArchiveException) rethrow;
        if (attempt > 0) rethrow;
        job.check();
        await File(file.path).delete();
        job.log('安装器缓存无效，重新下载：${p.basename(file.path)}');
      }
    }
  }

  int _classJava(Archive archive, String main) {
    final file = archive.findFile('${main.replaceAll('.', '/')}.class');
    if (file == null) return 8;
    final bytes = file.content;
    if (bytes.length < 8) return 8;
    return ((bytes[6] << 8) | bytes[7]) - 44;
  }

  Future<void> runJava(
    List<String> args,
    DownloadJob job, {
    String? workingDirectory,
    int minimumJava = 8,
  }) async {
    job.check();
    var executable = network.settings.javaPath;
    if (automaticJava(executable)) {
      if (_javaJobId != job.id) {
        _javaRuntimes = null;
        _javaJobId = job.id;
      }
      final runtimes = await (_javaRuntimes ??= discoverJava(
        gameRoots: network.settings.roots,
      ));
      if (runtimes.isEmpty) _javaRuntimes = null;
      final runtime = selectJava(runtimes, minimumMajor: minimumJava);
      executable = runtime.executable;
      job.log('自动选择 Java ${runtime.version}：$executable');
    }
    job.check();
    late Process process;
    try {
      process = await Process.start(
        executable,
        args,
        workingDirectory: workingDirectory,
        runInShell: false,
      );
    } on ProcessException catch (e) {
      throw StateError(
        '无法运行 Java，请在设置中查找或选择 java.exe。Forge / NeoForge / OptiFine 安装需要 Java。${e.message}',
      );
    }
    job.processes.add(process);
    if (job.status != JobStatus.running) {
      process.kill();
      job.processes.remove(process);
      job.check();
    }
    final out = process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .forEach(job.log);
    final err = process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .forEach(job.log);
    final code = await process.exitCode;
    await Future.wait([out, err]);
    job.processes.remove(process);
    job.check();
    if (code != 0) throw StateError('Java 安装处理器退出码 $code，请检查 Java 版本和任务日志');
  }
}

Future<Archive> readZip(String file) => Isolate.run(() {
  final bytes = File(file).readAsBytesSync();
  if (bytes.length < 4 ||
      bytes[0] != 0x50 ||
      bytes[1] != 0x4b ||
      ![0x03, 0x05, 0x07].contains(bytes[2])) {
    throw const FormatException('文件不是有效 ZIP / JAR 压缩包');
  }
  final archive = ZipDecoder().decodeBytes(bytes);
  if (archive.files.length > 200000 ||
      archive.files.fold<int>(0, (n, f) => n + f.size) >
          16 * 1024 * 1024 * 1024) {
    throw const FormatException('压缩包内容过大');
  }
  return archive;
});
Json archiveJson(Archive archive, String name) {
  final entry = archive.findFile(name);
  if (entry == null) throw FormatException('压缩包缺少 $name');
  return asMap(decodeJson(utf8.decode(entry.content)));
}

String jarMainClass(Archive archive) {
  final file = archive.findFile('META-INF/MANIFEST.MF');
  if (file == null) throw const FormatException('处理器缺少 MANIFEST.MF');
  final text = utf8.decode(file.content).replaceAll(RegExp(r'\r?\n '), '');
  final match = RegExp(
    r'^Main-Class:\s*(.+)$',
    multiLine: true,
  ).firstMatch(text);
  if (match == null) throw const FormatException('处理器没有 Main-Class');
  return match[1]!.trim();
}

int compareVersionNumbers(String a, String b) {
  final left = RegExp(
    r'\d+|[A-Za-z]+',
  ).allMatches(a).map((m) => m[0]!).toList();
  final right = RegExp(
    r'\d+|[A-Za-z]+',
  ).allMatches(b).map((m) => m[0]!).toList();
  for (var i = 0; i < left.length && i < right.length; i++) {
    final x = int.tryParse(left[i]), y = int.tryParse(right[i]);
    final result = x != null && y != null
        ? x.compareTo(y)
        : left[i].compareTo(right[i]);
    if (result != 0) return result;
  }
  return left.length.compareTo(right.length);
}

// NeoForge changed its game-version encoding with Minecraft 26.x.
String neoForgeGame(String value) {
  final parts = value.split('.');
  if (parts.length < 3) return '';
  final major = int.tryParse(parts[0]);
  if (major == null) return '';
  if (major == 0) return parts[1];
  if (major >= 26) {
    if (parts.length < 4) return '';
    final version = int.tryParse(parts[2]) == 0
        ? parts.take(2).join('.')
        : parts.take(3).join('.');
    return value.contains('+') ? '$version-${value.split('+').last}' : version;
  }
  return '1.${int.tryParse(parts[1]) == 0 ? parts[0] : parts.take(2).join('.')}';
}

// Maven's small, fixed <versions> list does not need a general XML DOM/parser.
// Reject malformed/HTML responses instead of presenting an empty version list.
Iterable<String> mavenVersions(String text) {
  final clean = text.replaceAll(RegExp(r'<!--[\s\S]*?-->'), '');
  final block = RegExp(
    r'<(?:\w+:)?versions\s*>([\s\S]*?)</(?:\w+:)?versions\s*>',
  ).firstMatch(clean)?[1];
  if (block == null) throw const FormatException('Maven 元数据缺少版本列表');
  final matches = RegExp(
    r'<(?:\w+:)?version\s*>\s*([A-Za-z0-9._+\-]+)\s*</(?:\w+:)?version\s*>',
  ).allMatches(block).map((m) => m[1]!).toSet();
  if (matches.isEmpty && block.trim().isNotEmpty) {
    throw const FormatException('Maven 版本列表格式无法识别');
  }
  return matches;
}
