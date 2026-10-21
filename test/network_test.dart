import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mc_download/core/models.dart';
import 'package:mc_download/core/network.dart';
import 'package:mc_download/core/repository.dart';
import 'package:mc_download/core/installer.dart';
import 'package:mc_download/app_state.dart';

void main() {
  test('manual HTTP proxy authentication uses supplied credentials', () async {
    final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var authenticated = false;
    proxy.listen((request) async {
      if (request.headers.value('proxy-authorization') ==
          'Basic ${base64Encode(utf8.encode('user:p:a'))}') {
        authenticated = true;
        request.response.write('{"throughProxy":true}');
      } else {
        request.response.statusCode = 407;
        request.response.headers.set(
          'proxy-authenticate',
          'Basic realm="fixture"',
        );
      }
      await request.response.close();
    });
    final network = NetworkService(
      AppSettings()
        ..proxyMode = ProxyMode.manual
        ..proxyUrl = 'http://user:p%3Aa@127.0.0.1:${proxy.port}',
    );
    try {
      final value = await network.json([
        'http://download.example.invalid/probe',
      ]);
      expect(value['throughProxy'], true);
      expect(authenticated, true);
      expect(network.audit.join('\n'), isNot(contains('p%3Aa')));
    } finally {
      network.close();
      await proxy.close(force: true);
    }
  });
  test('pause keeps partial bytes and resumes with verified content', () async {
    final dir = await Directory.systemTemp.createTemp('mcd-pause-');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final bytes = List<int>.generate(256 * 1024, (i) => i % 251);
    final started = Completer<void>();
    final release = Completer<void>();
    final received = Completer<void>();
    var first = true;
    String? range;
    server.listen((request) async {
      request.response.bufferOutput = false;
      request.response.headers.contentType = ContentType.binary;
      range = request.headers.value('range');
      final offset = range == null
          ? 0
          : int.parse(range!.substring(6).split('-').first);
      request.response.statusCode = offset == 0 ? 200 : 206;
      if (offset > 0) {
        request.response.headers.set(
          'content-range',
          'bytes $offset-${bytes.length - 1}/${bytes.length}',
        );
      }
      try {
        if (first) {
          first = false;
          request.response.add(bytes.sublist(0, 64 * 1024));
          await request.response.flush();
          started.complete();
          await release.future;
          request.response.add(bytes.sublist(64 * 1024));
        } else {
          request.response.add(bytes.sublist(offset));
        }
        await request.response.close();
      } on Exception {
        /* The paused client closes the first response. */
      }
    });
    final network = NetworkService(AppSettings()..proxyMode = ProxyMode.direct);
    final job = DownloadJob(
      id: 'pause',
      title: 'pause',
      kind: 'save',
      request: {},
      status: JobStatus.running,
    );
    final file = DownloadFile(
      '${dir.path}/game.jar',
      ['http://127.0.0.1:${server.port}/file'],
      hash: sha1.convert(bytes).toString(),
      size: bytes.length,
    );
    try {
      job.onChanged = () {
        if (job.received > 0 && !received.isCompleted) received.complete();
      };
      final pending = network.batch([file], job);
      final stopped = expectLater(pending, throwsA(isA<JobPaused>()));
      await started.future;
      await received.future.timeout(const Duration(seconds: 5));
      job.stop(pause: true);
      await stopped;
      release.complete();
      expect(await File('${file.path}.part').length(), greaterThan(0));
      job.status = JobStatus.running;
      await network.download(file, job);
      expect(range, startsWith('bytes='));
      expect(await File(file.path).readAsBytes(), bytes);
    } finally {
      if (!release.isCompleted) release.complete();
      network.close();
      await server.close(force: true);
      await dir.delete(recursive: true);
    }
  });

  test(
    'invalid installer cache is redownloaded instead of permanently reused',
    () async {
      final dir = await Directory.systemTemp.createTemp('mcd-jar-');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final zip = ZipEncoder().encode(
        Archive()..addFile(ArchiveFile.string('install_profile.json', '{}')),
      );
      var requests = 0;
      server.listen((request) async {
        requests++;
        request.response.add(zip);
        await request.response.close();
      });
      final network = NetworkService(
        AppSettings()..proxyMode = ProxyMode.direct,
      );
      try {
        final path = '${dir.path}/installer.jar';
        await File(path).writeAsString('<html>bad cache</html>');
        final installer = MinecraftInstaller(network, dir.path);
        final archive = await installer.fetchArchive(
          DownloadFile(path, ['http://127.0.0.1:${server.port}/jar']),
          DownloadJob(
            id: 'jar',
            title: 'jar',
            kind: 'install',
            request: {},
            status: JobStatus.running,
          ),
          requiredEntry: 'install_profile.json',
        );
        expect(archive.findFile('install_profile.json'), isNotNull);
        expect(requests, 1);
      } finally {
        network.close();
        await server.close(force: true);
        await dir.delete(recursive: true);
      }
    },
  );
  test(
    'HTTP range continuation, hash validation and malformed JSON fallback',
    () async {
      final dir = await Directory.systemTemp.createTemp('mcd-http-');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final bytes = utf8.encode(List.filled(1000, 'Minecraft').join());
      String? range;
      server.listen((request) async {
        if (request.uri.path == '/bad-json') {
          request.response.write('<html>not json</html>');
        } else if (request.uri.path == '/json') {
          request.response.write('{"ok":true}');
        } else {
          range = request.headers.value('range');
          final start = range == null
              ? 0
              : int.parse(range!.substring(6).split('-').first);
          request.response.statusCode = start == 0 ? 200 : 206;
          request.response.headers.set('etag', '"fixture"');
          if (start > 0) {
            request.response.headers.set(
              'content-range',
              'bytes $start-${bytes.length - 1}/${bytes.length}',
            );
          }
          request.response.add(bytes.sublist(start));
        }
        await request.response.close();
      });
      final network = NetworkService(
        AppSettings()..proxyMode = ProxyMode.direct,
      );
      try {
        final base = 'http://127.0.0.1:${server.port}';
        expect(
          (await network.json(['$base/bad-json', '$base/json']))['ok'],
          true,
        );
        final target = '${dir.path}/file.jar';
        await File('$target.part').writeAsBytes(bytes.sublist(0, 700));
        final job = DownloadJob(
          id: 'fixture',
          title: 'fixture',
          kind: 'save',
          request: {},
          status: JobStatus.running,
        );
        await network.download(
          DownloadFile(
            target,
            ['$base/file'],
            hash: sha1.convert(bytes).toString(),
            size: bytes.length,
          ),
          job,
        );
        expect(range, 'bytes=700-');
        expect(await File(target).readAsBytes(), bytes);
        expect(await File('$target.part').exists(), false);
      } finally {
        network.close();
        await server.close(force: true);
        await dir.delete(recursive: true);
      }
    },
  );

  test('Windows path rules and NeoForge game version mappings', () {
    for (final path in [
      '../outside',
      r'C:\outside',
      '/outside',
      r'mods\..\outside',
      'mods/file.',
      'mods/CON.jar',
      'mods/file?.jar',
    ]) {
      expect(() => safeChild('/tmp/root', path), throwsFormatException);
    }
    for (final id in ['CON', 'test/', 'test.', 'NUL.json']) {
      expect(() => validateId(id), throwsFormatException);
    }
    expect(neoForgeGame('21.1.219'), '1.21.1');
    expect(neoForgeGame('21.0.1-beta'), '1.21');
    expect(neoForgeGame('26.1.0.1-beta'), '26.1');
    expect(
      windowsRules([
        {
          'action': 'allow',
          'os': {'name': 'linux'},
        },
      ], 'x64'),
      false,
    );
    expect(
      mavenPath('net.fabricmc:fabric-loader:0.16.10'),
      'net/fabricmc/fabric-loader/0.16.10/fabric-loader-0.16.10.jar',
    );
  });

  test('persisted interrupted jobs restore as paused', () async {
    final dir = await Directory.systemTemp.createTemp('mcd-store-');
    final state = AppState(dir.path);
    await state.initialize(remote: false);
    state.jobs.add(
      DownloadJob(
        id: 'old',
        title: 'in flight',
        kind: 'install',
        request: {'root': '/tmp/game', 'id': 'test'},
        status: JobStatus.running,
      ),
    );
    await state.save();
    state.dispose();
    final restored = AppState(dir.path);
    await restored.initialize(remote: false);
    expect(restored.jobs.single.status, JobStatus.paused);
    restored.dispose();
    await dir.delete(recursive: true);
  });

  test('corrupted configuration recovers from a valid backup', () async {
    final dir = await Directory.systemTemp.createTemp('mcd-recover-');
    final state = AppState(dir.path);
    await state.initialize(remote: false);
    state.settings.autoDiscover = false;
    state.settings.mirrorUrl = 'https://mirror.example';
    await state.save();
    await state.save();
    state.dispose();
    await File('${dir.path}/settings.json').writeAsString('damaged');
    final restored = AppState(dir.path);
    await restored.initialize(remote: false);
    expect(restored.settings.mirrorUrl, 'https://mirror.example');
    expect(restored.recoveryNotice, contains('恢复'));
    restored.dispose();
    await dir.delete(recursive: true);
  });
}
