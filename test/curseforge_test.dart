import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mc_download/core/models.dart';
import 'package:mc_download/core/network.dart';
import 'package:mc_download/core/resources.dart';
import 'package:mc_download/core/installer.dart';
import 'package:mc_download/core/modpacks.dart';
import 'support/http_fixture.dart';

DownloadJob job(String id) => DownloadJob(
  id: id,
  title: id,
  kind: 'save',
  request: {},
  status: JobStatus.running,
);

void main() {
  test(
    'CurseForge pack requires key before downloading Minecraft files',
    () async {
      final directory = await Directory.systemTemp.createTemp('mcd-cf-pack-');
      final client = TestClient((_) => TestResponse(200));
      final network = NetworkService(
        AppSettings()..proxyMode = ProxyMode.direct,
        clientFactory: () => client,
      );
      try {
        final file = '${directory.path}/pack.zip';
        await File(file).writeAsBytes(
          ZipEncoder().encode(
            Archive()..addFile(ArchiveFile.string('manifest.json', '{}')),
          ),
        );
        final packs = ModpackService(
          MinecraftInstaller(network, '${directory.path}/cache'),
          ResourceService(network),
        );
        final info = PackInfo(
          file: file,
          prefix: '',
          format: 'CurseForge',
          name: 'fixture',
          game: '1.20.1',
          manifest: {},
        );
        await expectLater(
          packs.install(info, '${directory.path}/game', 'pack', job('pack')),
          throwsA(isA<CurseForgeAccessException>()),
        );
        expect(client.requests, isEmpty);
        expect(await Directory('${directory.path}/game').exists(), false);
      } finally {
        network.close();
        await directory.delete(recursive: true);
      }
    },
  );
  test(
    'missing configured key blocks query, cached CDN download and provider files',
    () async {
      final client = TestClient((_) => TestResponse(200, text: '{"data":[]}'));
      final network = NetworkService(
        AppSettings()..proxyMode = ProxyMode.direct,
        clientFactory: () => client,
      );
      final directory = await Directory.systemTemp.createTemp(
        'mcd-cf-missing-',
      );
      try {
        final resources = ResourceService(network);
        await expectLater(
          resources.search(provider: 'CurseForge', kind: 'mod'),
          throwsA(isA<CurseForgeAccessException>()),
        );
        final path = '${directory.path}/cached.jar';
        await File(path).writeAsString('cached');
        await expectLater(
          network.download(
            DownloadFile(path, ['https://edge.forgecdn.net/files/file.jar']),
            job('cached'),
          ),
          throwsA(isA<CurseForgeAccessException>()),
        );
        expect(
          () => resources.downloadFile({
            'provider': 'CurseForge',
            'urls': ['https://example.com/file.jar'],
          }, path),
          throwsA(isA<CurseForgeAccessException>()),
        );
        expect(client.requests, isEmpty);
      } finally {
        network.close();
        await directory.delete(recursive: true);
      }
    },
  );

  test('query, CDN redirect and Range continuation use saved key', () async {
    final payload = utf8.encode('verified CurseForge download');
    final client = TestClient((request) {
      if (request.uri.host == 'api.curseforge.com') {
        return TestResponse(200, text: '{"data":[]}');
      }
      if (request.uri.host == 'edge.forgecdn.net') {
        return TestResponse(
          302,
          headers: {
            'location': 'https://mediafilez.forgecdn.net/files/file.jar',
          },
        );
      }
      return TestResponse(
        206,
        bytes: payload.sublist(3),
        headers: {
          'content-range': 'bytes 3-${payload.length - 1}/${payload.length}',
        },
      );
    });
    final network = NetworkService(
      AppSettings()
        ..proxyMode = ProxyMode.direct
        ..curseKey = ' personal-key ',
      clientFactory: () => client,
    );
    final directory = await Directory.systemTemp.createTemp('mcd-cf-range-');
    try {
      final resources = ResourceService(network);
      expect(
        await resources.search(provider: 'CurseForge', kind: 'mod'),
        isEmpty,
      );
      final path = '${directory.path}/file.jar';
      await File('$path.part').writeAsBytes(payload.sublist(0, 3));
      final file = resources.downloadFile({
        'provider': 'CurseForge',
        'urls': ['https://edge.forgecdn.net/files/file.jar'],
        'hash': sha1.convert(payload).toString(),
        'size': payload.length,
      }, path);
      await network.download(file, job('range'));
      expect(await File(path).readAsBytes(), payload);
      expect(client.requests.length, 3);
      for (final request in client.requests) {
        expect(request.headers.value('x-api-key'), 'personal-key');
      }
      for (final request in client.requests.skip(1)) {
        expect(request.headers.value('range'), 'bytes=3-');
      }
      expect(network.audit.join('\n'), isNot(contains('personal-key')));
    } finally {
      network.close();
      await directory.delete(recursive: true);
    }
  });

  test(
    'key and credentials never follow a CDN redirect to another site',
    () async {
      final client = TestClient(
        (request) => request.uri.host == 'edge.forgecdn.net'
            ? TestResponse(
                302,
                headers: {'location': 'https://download.example.com/file.jar'},
              )
            : TestResponse(200, text: 'file'),
      );
      final network = NetworkService(
        AppSettings()
          ..proxyMode = ProxyMode.direct
          ..curseKey = 'secret-key',
        clientFactory: () => client,
      );
      try {
        expect(
          await network.text(
            ['https://edge.forgecdn.net/file.jar'],
            headers: {'Authorization': 'Bearer fixture'},
          ),
          'file',
        );
        expect(client.requests.first.headers.value('x-api-key'), 'secret-key');
        expect(client.requests.last.headers.value('x-api-key'), isNull);
        expect(client.requests.last.headers.value('authorization'), isNull);
        final api = Uri.parse('https://api.curseforge.com/');
        for (final address in [
          'https://evilforgecdn.net/file',
          'https://forgecdn.net.example.com/file',
          'https://api.curseforge.com.example.com/',
        ]) {
          expect(
            network.headersForRequest(
              Uri.parse(address),
              origin: api,
              headers: {'x-api-key': 'secret-key'},
            )['x-api-key'],
            isNull,
          );
        }
      } finally {
        network.close();
      }
    },
  );

  for (final status in [401, 403]) {
    test(
      'CurseForge $status returns actionable failure without retries',
      () async {
        final client = TestClient((_) => TestResponse(status));
        final network = NetworkService(
          AppSettings()
            ..proxyMode = ProxyMode.direct
            ..curseKey = 'invalid-key',
          clientFactory: () => client,
        );
        try {
          await expectLater(
            network.json(['https://api.curseforge.com/v1/games/432']),
            throwsA(
              isA<CurseForgeAccessException>().having(
                (e) => e.message,
                'message',
                contains('$status'),
              ),
            ),
          );
          expect(client.requests.length, 1);
          expect(network.audit.join('\n'), isNot(contains('invalid-key')));
        } finally {
          network.close();
        }
      },
    );
  }

  test('Modrinth remains usable without a CurseForge key', () async {
    final client = TestClient((_) => TestResponse(200, text: '{"hits":[]}'));
    final network = NetworkService(
      AppSettings()..proxyMode = ProxyMode.direct,
      clientFactory: () => client,
    );
    try {
      expect(
        await ResourceService(
          network,
        ).search(provider: 'Modrinth', kind: 'mod'),
        isEmpty,
      );
      expect(client.requests.single.headers.value('x-api-key'), isNull);
    } finally {
      network.close();
    }
  });
}
