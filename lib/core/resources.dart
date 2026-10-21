import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'models.dart';
import 'network.dart';
import 'repository.dart';

class ResourceService {
  final NetworkService network;
  ResourceService(this.network);
  Map<String, String> get cfHeaders {
    if (network.settings.curseKey.trim().isEmpty) {
      throw StateError('CurseForge 需要 API Key，请在设置中填写自己的 Key；Modrinth 无需 Key');
    }
    return {'x-api-key': network.settings.curseKey.trim()};
  }

  Future<Json> cf(String path, {DownloadJob? job}) async => asMap(
    await network.json(
      ['https://api.curseforge.com/v1/$path'],
      headers: cfHeaders,
      job: job,
    ),
  );
  Future<Json> mr(String path, {DownloadJob? job}) async => asMap(
    await network.json(['https://api.modrinth.com/v2/$path'], job: job),
  );

  Future<List<Json>> search({
    required String provider,
    required String kind,
    String query = '',
    String game = '',
    String loader = '',
    int page = 0,
  }) async {
    if (provider == 'Modrinth') {
      if (kind == 'world') {
        throw StateError('Modrinth v2 没有世界分类，请切换 CurseForge');
      }
      final facets = <List<String>>[
        ['project_type:${kind == 'datapack' ? 'mod' : kind}'],
        if (kind == 'datapack') ['categories:datapack'],
        if (game.isNotEmpty) ['versions:$game'],
        if (loader.isNotEmpty && kind == 'mod')
          ['categories:${loader.toLowerCase()}'],
      ];
      final q = Uri(
        queryParameters: {
          'query': query,
          'facets': jsonEncode(facets),
          'limit': '20',
          'offset': '${page * 20}',
          'index': query.isEmpty ? 'downloads' : 'relevance',
        },
      ).query;
      final j = await mr('search?$q');
      return asList(j['hits'])
          .map(
            (e) => {
              'id': e['project_id'],
              'title': e['title'],
              'description': e['description'],
              'downloads': e['downloads'],
              'author': e['author'],
              'icon': e['icon_url'],
              'provider': provider,
              'kind': kind,
              'url': 'https://modrinth.com/project/${e['slug']}',
            },
          )
          .toList();
    }
    final classes = {
      'mod': 6,
      'modpack': 4471,
      'resourcepack': 12,
      'shader': 6552,
      'world': 17,
      'datapack': 6945,
    };
    final loaders = {'Forge': 1, 'Fabric': 4, 'Quilt': 5, 'NeoForge': 6};
    final q = Uri(
      queryParameters: {
        'gameId': '432',
        'classId': '${classes[kind]}',
        'searchFilter': query,
        'pageSize': '20',
        'index': '${page * 20}',
        'sortField': '2',
        'sortOrder': 'desc',
        if (game.isNotEmpty) 'gameVersion': game,
        if (loader.isNotEmpty && kind == 'mod' && loaders.containsKey(loader))
          'modLoaderType': '${loaders[loader]}',
      },
    ).query;
    return asList((await cf('mods/search?$q'))['data'])
        .map(
          (e) => {
            'id': '${e['id']}',
            'title': e['name'],
            'description': e['summary'],
            'downloads': e['downloadCount'],
            'author': asList(e['authors']).map((a) => a['name']).join(', '),
            'icon': asMap(e['logo'])['thumbnailUrl'],
            'provider': provider,
            'kind': kind,
            'url': asMap(e['links'])['websiteUrl'],
          },
        )
        .toList();
  }

  Future<List<Json>> versions(
    Json project, {
    String game = '',
    String loader = '',
    DownloadJob? job,
  }) async {
    if (project['provider'] == 'Modrinth') {
      final q = Uri(
        queryParameters: {
          if (game.isNotEmpty) 'game_versions': jsonEncode([game]),
          if (loader.isNotEmpty && project['kind'] == 'mod')
            'loaders': jsonEncode([loader.toLowerCase()]),
          if (project['kind'] == 'datapack')
            'loaders': jsonEncode(['datapack']),
        },
      ).query;
      final rows = asList(
        await network.json([
          'https://api.modrinth.com/v2/project/${project['id']}/version?$q',
        ], job: job),
      );
      return rows.map((e) => _mrVersion(asMap(e), project)).toList();
    }
    final types = {'Forge': 1, 'Fabric': 4, 'Quilt': 5, 'NeoForge': 6};
    final q = Uri(
      queryParameters: {
        'pageSize': '50',
        if (game.isNotEmpty) 'gameVersion': game,
        if (loader.isNotEmpty && types.containsKey(loader))
          'modLoaderType': '${types[loader]}',
      },
    ).query;
    return asList(
      (await cf('mods/${project['id']}/files?$q', job: job))['data'],
    ).map((e) => _cfVersion(asMap(e), project)).toList();
  }

  Json _mrVersion(Json raw, Json project) {
    final files = asList(raw['files']);
    if (files.isEmpty) throw const FormatException('此资源版本没有文件');
    final file = asMap(
      files.where((f) => f['primary'] == true).firstOrNull ?? files.first,
    );
    final hashes = asMap(file['hashes']);
    return {
      'id': raw['id'],
      'projectId': raw['project_id'],
      'name': raw['name'],
      'filename': file['filename'],
      'urls': [file['url']],
      'hash': hashes['sha512'] ?? hashes['sha1'],
      'algorithm': hashes['sha512'] == null ? 'sha1' : 'sha512',
      'size': file['size'],
      'dependencies': raw['dependencies'],
      'provider': 'Modrinth',
      'kind': project['kind'],
      'published': raw['date_published'],
      'gameVersions': raw['game_versions'],
      'loaders': raw['loaders'],
    };
  }

  Json _cfVersion(Json raw, Json project) {
    final hashes = asList(raw['hashes']);
    final hash = hashes.where((e) => e['algo'] == 1).firstOrNull;
    return {
      'id': '${raw['id']}',
      'projectId': '${raw['modId']}',
      'name': raw['displayName'],
      'filename': raw['fileName'],
      'urls': raw['downloadUrl'] == null ? <String>[] : [raw['downloadUrl']],
      'hash': hash?['value'],
      'algorithm': 'sha1',
      'size': raw['fileLength'],
      'dependencies': raw['dependencies'],
      'provider': 'CurseForge',
      'kind': project['kind'],
      'published': raw['fileDate'],
      'gameVersions': raw['gameVersions'],
    };
  }

  Future<Json> curseFile(
    String project,
    String file, {
    DownloadJob? job,
  }) async => _cfVersion(
    asMap((await cf('mods/$project/files/$file', job: job))['data']),
    {'kind': 'mod'},
  );

  DownloadFile downloadFile(Json version, String target) {
    final urls = asList(version['urls']).cast<String>();
    if (urls.isEmpty) {
      throw StateError(
        '作者禁止第三方直接下载，请手动下载并导入：https://www.curseforge.com/minecraft/mc-mods/${version['projectId']}/files/${version['id']}',
      );
    }
    return DownloadFile(
      target,
      urls,
      hash: version['hash'],
      algorithm: version['algorithm'] ?? 'sha1',
      size: version['size'],
    );
  }

  Future<void> install(
    Json selected,
    LocalVersion target,
    DownloadJob job, {
    String? world,
    bool update = false,
  }) async {
    final kind = selected['kind'];
    final subdir = switch (kind) {
      'mod' => 'mods',
      'resourcepack' => 'resourcepacks',
      'shader' => 'shaderpacks',
      'datapack' =>
        world == null
            ? throw StateError('数据包必须指定目标世界')
            : 'saves/$world/datapacks',
      _ => throw StateError('此资源应通过整合包或世界安装入口处理'),
    };
    if (kind == 'mod' && target.loader.isEmpty) {
      throw StateError('原版没有 Mod 加载器，请先安装对应加载器');
    }
    final pending = <Json>[];
    final visited = <String>{};
    Future<void> resolve(Json version) async {
      job.check();
      final identity = '${version['provider']}:${version['projectId']}';
      if (!visited.add(identity)) return;
      if (visited.length > 120) throw StateError('依赖数量异常，停止安装');
      for (final raw in asList(version['dependencies'])) {
        final dep = asMap(raw);
        final mr = version['provider'] == 'Modrinth';
        if (mr
            ? dep['dependency_type'] != 'required'
            : dep['relationType'] != 3) {
          continue;
        }
        Json required;
        if (mr && dep['version_id'] != null) {
          required = _mrVersion(
            await this.mr('version/${dep['version_id']}', job: job),
            {'kind': 'mod'},
          );
        } else {
          final id = '${mr ? dep['project_id'] : dep['modId']}';
          if (id == 'null') throw StateError('依赖缺少项目 ID，不能自动安装');
          final candidates = await versions(
            {'id': id, 'provider': version['provider'], 'kind': 'mod'},
            game: target.game,
            loader: target.loader,
            job: job,
          );
          if (candidates.isEmpty) {
            throw StateError(
              '依赖 $id 没有兼容 ${target.game} / ${target.loader} 的文件',
            );
          }
          required = candidates.first;
        }
        await resolve(required);
      }
      if (version['provider'] == 'Modrinth' && version['kind'] == 'mod') {
        if (!asList(version['gameVersions']).contains(target.game) ||
            !asList(version['loaders']).contains(target.loader.toLowerCase())) {
          throw StateError('依赖 ${version['filename']} 与当前游戏版本或加载器不兼容');
        }
      }
      pending.add(version);
    }

    job.stage = '解析必要依赖';
    job.notify();
    if (kind == 'mod') {
      await resolve(selected);
    } else {
      pending.add(selected);
    }
    final indexFile = File(p.join(target.contentPath, '.mcd-resources.json'));
    final index = await indexFile.exists()
        ? asMap(decodeJson(await indexFile.readAsString()))
        : <String, dynamic>{};
    for (final version in pending) {
      job.check();
      final relative = '$subdir/${version['filename']}';
      final destination = safeChild(target.contentPath, relative);
      await guardPath(target.contentPath, destination);
      final descriptor = downloadFile(version, destination);
      if (await File(destination).exists() && !await validFile(descriptor)) {
        throw StateError('同名文件已存在且内容不同：${version['filename']}，请先备份或移除');
      }
      job.stage = '下载 ${version['filename']}';
      job.notify();
      await network.download(descriptor, job);
      if (update) {
        for (final entry in index.entries.toList()) {
          final old = asMap(entry.value);
          if (old['projectId'] == version['projectId'] &&
              old['provider'] == version['provider'] &&
              entry.key != relative) {
            final oldPath = safeChild(target.contentPath, entry.key);
            await guardPath(target.contentPath, oldPath);
            if (old['hash'] != null &&
                await validFile(
                  DownloadFile(
                    oldPath,
                    [],
                    hash: old['hash'],
                    algorithm: old['algorithm'] ?? 'sha1',
                  ),
                )) {
              var backup = '$oldPath.disabled';
              if (await File(backup).exists()) {
                backup =
                    '$oldPath.${DateTime.now().millisecondsSinceEpoch}.disabled';
              }
              await File(oldPath).rename(backup);
              index.remove(entry.key);
            } else if (await File(oldPath).exists()) {
              throw StateError('旧文件已被修改：${entry.key}，新版本已下载，请手动处理旧文件');
            }
          }
        }
      }
      index[relative] = version;
      await guardPath(target.contentPath, indexFile.path);
      await writeJson(indexFile.path, index);
    }
  }

  Future<List<Json>> findUpdates(LocalVersion target, DownloadJob job) async {
    final indexFile = File(p.join(target.contentPath, '.mcd-resources.json'));
    if (!await indexFile.exists()) return [];
    final index = asMap(decodeJson(await indexFile.readAsString()));
    final updates = <Json>[];
    for (final entry in index.entries) {
      job.check();
      final old = asMap(entry.value);
      if (entry.key.endsWith('.disabled') ||
          !await File(safeChild(target.contentPath, entry.key)).exists()) {
        continue;
      }
      final rows = await versions(
        {
          'id': old['projectId'],
          'provider': old['provider'],
          'kind': old['kind'],
        },
        game: target.game,
        loader: old['kind'] == 'mod' ? target.loader : '',
        job: job,
      );
      if (rows.isNotEmpty && rows.first['id'] != old['id']) {
        updates.add({...rows.first, 'oldName': old['filename']});
      }
    }
    return updates;
  }
}
