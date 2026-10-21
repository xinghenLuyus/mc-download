import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:mc_download/core/models.dart';
import 'package:mc_download/core/network.dart';
import 'package:mc_download/core/installer.dart';
import 'package:mc_download/core/modpacks.dart';
import 'package:mc_download/core/resources.dart';
import 'package:mc_download/core/repository.dart';

// Run with dart run tool/probe_interfaces.dart [--proxy=http://127.0.0.1:7890].
// No game installation, launcher mutation, account access, or Java execution.
Future<void> main(List<String> args) async {
  final temp = await Directory.systemTemp.createTemp('mcd-interfaces-');
  final settings = AppSettings()..proxyMode = ProxyMode.direct;
  for (final arg in args) {
    if (arg.startsWith('--proxy=')) {
      settings.proxyMode = ProxyMode.manual;
      settings.proxyUrl = arg.substring(8);
    }
    if (arg == '--system') settings.proxyMode = ProxyMode.system;
    if (arg.startsWith('--mirror=')) settings.mirrorUrl = arg.substring(9);
  }
  settings.curseKey = Platform.environment['CURSEFORGE_API_KEY'] ?? '';
  final net = NetworkService(settings);
  final installer = MinecraftInstaller(net, temp.path);
  final resources = ResourceService(net);
  final packs = ModpackService(installer, resources);
  final results = <Json>[];
  Future<void> probe(String name, Future<Json> Function() run) async {
    final clock = Stopwatch()..start();
    try {
      final detail = await run();
      results.add({
        'name': name,
        'ok': true,
        'milliseconds': clock.elapsedMilliseconds,
        ...detail,
      });
      print(
        'PASS $name (${clock.elapsedMilliseconds} ms) ${jsonEncode(detail)}',
      );
    } catch (e) {
      results.add({
        'name': name,
        'ok': false,
        'milliseconds': clock.elapsedMilliseconds,
        'error': '$e',
      });
      print('FAIL $name: $e');
    }
  }

  final job = DownloadJob(
    id: 'probe',
    title: '接口验证',
    kind: 'probe',
    request: {},
    status: JobStatus.running,
  );
  try {
    await probe('Manual HTTP proxy / HTTPS CONNECT', () async {
      final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <Socket>[];
      var tunnels = 0;
      proxy.listen((request) async {
        try {
          if (request.method != 'CONNECT') {
            request.response.statusCode = 405;
            await request.response.close();
            return;
          }
          final target = Uri.parse('https://${request.uri}');
          if (target.host != 'piston-meta.mojang.com' || target.port != 443) {
            request.response.statusCode = 403;
            await request.response.close();
            return;
          }
          final upstream = await Socket.connect(
            target.host,
            target.port,
            timeout: const Duration(seconds: 15),
          );
          final downstream = await request.response.detachSocket(
            writeHeaders: false,
          );
          sockets.addAll([upstream, downstream]);
          tunnels++;
          downstream.write('HTTP/1.1 200 Connection Established\r\n\r\n');
          await downstream.flush();
          upstream.listen(
            downstream.add,
            onError: (_) => downstream.destroy(),
            onDone: downstream.destroy,
          );
          downstream.listen(
            upstream.add,
            onError: (_) => upstream.destroy(),
            onDone: upstream.destroy,
          );
        } catch (_) {
          try {
            await request.response.close();
          } catch (_) {}
        }
      });
      final proxied = NetworkService(
        AppSettings()
          ..proxyMode = ProxyMode.manual
          ..proxyUrl = 'http://127.0.0.1:${proxy.port}',
      );
      try {
        final result = asMap(await proxied.json([SourcePolicy.manifest]));
        if (asList(result['versions']).isEmpty || tunnels == 0) {
          throw StateError('Proxy tunnel was not used');
        }
        return {
          'tunnels': tunnels,
          'versions': asList(result['versions']).length,
        };
      } finally {
        proxied.close();
        for (final socket in sockets) {
          socket.destroy();
        }
        await proxy.close(force: true);
      }
    });
    await probe('Mojang manifest', () async {
      final rows = await installer.fetchVersions();
      if (!rows.any((v) => v.id == '1.21.1')) {
        throw StateError('Missing reference version');
      }
      return {'count': rows.length, 'latest': rows.first.id};
    });
    await probe('Mojang version metadata + verified asset', () async {
      final meta = await installer.vanilla('1.21.1', job);
      final index = asMap(meta['assetIndex']);
      final indexPath = p.join(temp.path, 'asset-index.json');
      await net.download(
        DownloadFile(
          indexPath,
          net.sources.candidates(index['url']),
          hash: index['sha1'],
          size: index['size'],
        ),
        job,
      );
      final objects = asMap(
        asMap(jsonDecode(await File(indexPath).readAsString()))['objects'],
      );
      final small = objects.values
          .map(asMap)
          .where((f) => (f['size'] as int) > 0 && (f['size'] as int) < 2000)
          .first;
      final hash = small['hash'] as String;
      await net.download(
        DownloadFile(
          p.join(temp.path, 'small-asset'),
          [
            'https://resources.download.minecraft.net/${hash.substring(0, 2)}/$hash',
          ],
          hash: hash,
          size: small['size'],
        ),
        job,
      );
      return {
        'libraries': asList(meta['libraries']).length,
        'assets': objects.length,
        'assetSha1Verified': true,
      };
    });
    await Future.wait(
      ['Fabric', 'Quilt', 'Forge', 'NeoForge', 'OptiFine'].map(
        (loader) => probe('$loader version list', () async {
          final game = loader == 'OptiFine' ? '1.20.1' : '1.21.1';
          final rows = await installer.loaderVersions(game, loader);
          if (rows.isEmpty) throw StateError('No compatible versions');
          return {
            'game': game,
            'count': rows.length,
            'sample': rows.first['version'],
          };
        }),
      ),
    );
    await probe('Fabric profile + Windows library plan', () async {
      final versions = await installer.loaderVersions('1.21.1', 'Fabric');
      final patch = asMap(
        await net.json([
          'https://meta.fabricmc.net/v2/versions/loader/1.21.1/${versions.first['version']}/profile/json',
        ]),
      );
      final files = installer.libraries(temp.path, asList(patch['libraries']));
      if (files.isEmpty || patch['mainClass'] == null) {
        throw StateError('Incomplete loader profile');
      }
      return {'libraries': files.length, 'mainClass': patch['mainClass']};
    });
    for (final loader in ['Forge', 'NeoForge']) {
      await probe('$loader installer archive + processor metadata', () async {
        final rows = await installer.loaderVersions('1.21.1', loader);
        final version = rows.first['version'] as String;
        final neo = loader == 'NeoForge';
        final path = mavenPath(
          '${neo ? 'net.neoforged:neoforge' : 'net.minecraftforge:forge'}:$version:installer',
        );
        final url =
            '${neo ? 'https://maven.neoforged.net/releases' : 'https://maven.minecraftforge.net'}/$path';
        final target = p.join(temp.path, '$loader-installer.jar');
        await net.download(
          DownloadFile(
            target,
            net.sources.candidates(
              url,
              mirrorPath: neo
                  ? '/neoforge/version/$version/download/installer.jar'
                  : null,
            ),
          ),
          job,
        );
        final archive = await readZip(target);
        final profile = archiveJson(archive, 'install_profile.json');
        final patch = archiveJson(
          archive,
          (profile['json'] as String).replaceFirst(RegExp(r'^/'), ''),
        );
        if (profile['minecraft'] != '1.21.1') {
          throw StateError('Installer game mismatch');
        }
        return {
          'version': version,
          'processors': asList(profile['processors']).length,
          'libraries': asList(patch['libraries']).length,
        };
      });
    }
    await probe('BMCLAPI manifest', () async {
      final data = asMap(
        await net.json([
          '${settings.mirrorUrl}/mc/game/version_manifest_v2.json',
        ]),
      );
      return {'count': asList(data['versions']).length};
    });
    await probe('BMCLAPI library mapping + SHA-1', () async {
      final meta = await installer.vanilla('1.21.1', job);
      final artifact = asList(meta['libraries'])
          .map(asMap)
          .map((lib) => asMap(asMap(lib['downloads'])['artifact']))
          .where(
            (a) =>
                a['url'] is String &&
                Uri.parse(a['url']).host == 'libraries.minecraft.net' &&
                (a['size'] as int) < 100000,
          )
          .first;
      final url = '${settings.mirrorUrl}/libraries/${artifact['path']}';
      await net.download(
        DownloadFile(
          p.join(temp.path, 'library-sample.jar'),
          [url],
          hash: artifact['sha1'],
          size: artifact['size'],
        ),
        job,
      );
      return {'path': artifact['path'], 'sha1Verified': true};
    });
    await probe('BMCLAPI client redirect / range', () async {
      final result = await net.open(
        '${settings.mirrorUrl}/version/1.21.1/client',
        headers: {'Range': 'bytes=0-31'},
      );
      final status = result.response.statusCode;
      final range = result.response.headers.value('content-range');
      result.request.abort();
      if (status != 200 && status != 206) throw HttpException('HTTP $status');
      return {
        'status': status,
        'range': range,
        'finalHost': Uri.parse(result.url).host,
      };
    });
    for (final kind in [
      'mod',
      'modpack',
      'resourcepack',
      'shader',
      'datapack',
    ]) {
      await probe('Modrinth $kind search + versions', () async {
        final rows = await resources.search(
          provider: 'Modrinth',
          kind: kind,
          game: '1.21.1',
        );
        if (rows.isEmpty) throw StateError('Empty search');
        final versions = await resources.versions(rows.first, game: '1.21.1');
        if (versions.isEmpty) throw StateError('No matching files');
        return {
          'count': rows.length,
          'project': rows.first['title'],
          'filename': versions.first['filename'],
        };
      });
    }
    await probe('mrpack download + manifest detection', () async {
      final project = {
        'id': 'fabulously-optimized',
        'provider': 'Modrinth',
        'kind': 'modpack',
      };
      final versions = await resources.versions(project, game: '1.21.1');
      final version = versions
          .where((v) => (v['size'] as num) < 8 * 1024 * 1024)
          .first;
      final target = p.join(temp.path, 'sample.mrpack');
      await net.download(resources.downloadFile(version, target), job);
      final info = await packs.inspect(target);
      return {
        'format': info.format,
        'game': info.game,
        'loader': info.loader,
        'files': asList(info.manifest['files']).length,
      };
    });
    if (settings.curseKey.isNotEmpty) {
      await probe('CurseForge search + file metadata', () async {
        final rows = await resources.search(
          provider: 'CurseForge',
          kind: 'mod',
          game: '1.21.1',
        );
        final files = await resources.versions(rows.first, game: '1.21.1');
        return {'count': rows.length, 'files': files.length};
      });
    } else {
      results.add({
        'name': 'CurseForge',
        'skipped': true,
        'reason': 'No user API key supplied',
      });
    }
    final report = {
      'timeUtc': DateTime.now().toUtc().toIso8601String(),
      'host': Platform.operatingSystem,
      'mode': settings.proxyMode.name,
      'results': results,
      'requests': net.audit,
      'notTested': [
        'Windows build and UI',
        'Windows system proxy/PAC',
        'Java installer processors',
        'actual game launch',
      ],
    };
    await Directory('orther/reports').create(recursive: true);
    await File('orther/reports/interface-report.json').writeAsString(pretty(report));
    print('Report: orther/reports/interface-report.json');
    if (results.any((r) => r['ok'] == false)) exitCode = 1;
  } finally {
    net.close();
    await temp.delete(recursive: true);
  }
}
