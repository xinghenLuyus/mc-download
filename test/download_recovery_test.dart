import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mc_download/core/models.dart';
import 'package:mc_download/core/network.dart';
import 'package:mc_download/core/resources.dart';
import 'package:mc_download/core/manual_downloads.dart';
import 'support/http_fixture.dart';

void main() {
  late Directory temp;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('mcd-recovery-');
  });
  tearDown(() async => temp.delete(recursive: true));
  NetworkService network(TestClient client) => NetworkService(
    AppSettings()
      ..proxyMode = ProxyMode.direct
      ..curseKey = 'private-key',
    clientFactory: () => client,
  );
  DownloadJob job() => DownloadJob(
    id: 'stable',
    title: 'fixture',
    kind: 'pack',
    request: {'root': temp.path},
    status: JobStatus.running,
  );

  test(
    'empty CurseForge URL uses encoded official CDN candidates and MD5, ignoring unknown zero size',
    () async {
      final bytes = utf8.encode('download payload');
      final client = TestClient((request) {
        if (request.uri.host == 'api.curseforge.com') {
          return TestResponse(
            200,
            text: jsonEncode({
              'data': {
                'id': 12345678,
                'modId': 8,
                'fileName': '中文 a+#.jar',
                'downloadUrl': '',
                'fileLength': 0,
                'hashes': [
                  {'algo': 2, 'value': md5.convert(bytes).toString()},
                ],
              },
            }),
          );
        }
        return request.uri.host == 'edge.forgecdn.net'
            ? TestResponse(403)
            : TestResponse(200, bytes: bytes);
      });
      final net = network(client);
      try {
        final resources = ResourceService(net);
        final version = await resources.curseFile('8', '12345678');
        expect(version['size'], isNull);
        expect(version['algorithm'], 'md5');
        expect(Uri.parse(version['urls'][0]).pathSegments, [
          'files',
          '12345',
          '678',
          '中文 a+#.jar',
        ]);
        final target = '${temp.path}/file.jar';
        await net.download(resources.downloadFile(version, target), job());
        expect(await File(target).readAsBytes(), bytes);
        expect(
          client.requests.map((r) => r.headers.value('x-api-key')),
          everyElement('private-key'),
        );
        expect(client.requests.length, 3);
        expect(net.audit.join(), isNot(contains('private-key')));
      } finally {
        net.close();
      }
    },
  );

  test(
    'legacy persisted version without URLs is also repaired, and malformed names are rejected',
    () async {
      final net = network(TestClient((_) => TestResponse(200)));
      try {
        final resources = ResourceService(net);
        final file = resources.downloadFile({
          'provider': 'CurseForge',
          'id': '10000000',
          'filename': 'old.jar',
          'urls': [],
        }, '${temp.path}/old.jar');
        expect(
          file.urls.first,
          'https://edge.forgecdn.net/files/10000/0/old.jar',
        );
        expect(
          () => curseDownloadUrls(null, '12', '../outside.jar'),
          throwsFormatException,
        );
        expect(
          () => curseDownloadUrls(
            'http://edge.forgecdn.net/file',
            '12',
            'file.jar',
          ),
          throwsFormatException,
        );
      } finally {
        net.close();
      }
    },
  );

  test(
    'missing files are collected while others finish, survive restart, and accept verified manual files before resume',
    () async {
      final good = utf8.encode('good'), blocked = utf8.encode('blocked');
      final client = TestClient(
        (request) => request.uri.path.endsWith('blocked.jar')
            ? TestResponse(403)
            : TestResponse(200, bytes: good),
      );
      final net = network(client);
      final task = job();
      final files = [
        DownloadFile(
          '${temp.path}/.mcd-staging/stable/mods/blocked.jar',
          curseDownloadUrls(null, '123456', 'blocked.jar'),
          hash: sha1.convert(blocked).toString(),
          size: blocked.length,
        ),
        DownloadFile(
          '${temp.path}/.mcd-staging/stable/mods/good.jar',
          ['https://fixture.invalid/good.jar'],
          hash: sha1.convert(good).toString(),
          size: good.length,
        ),
      ];
      try {
        await expectLater(
          downloadRecoverably(
            net,
            files,
            task,
            temp.path,
            websites: {
              files.first.path:
                  'https://www.curseforge.com/projects/8/files/123456',
            },
          ),
          throwsA(
            isA<ManualFilesRequired>().having((e) => e.count, 'count', 1),
          ),
        );
        expect(await File(files.last.path).readAsBytes(), good);
        expect(task.completedFiles, 1);
        task.status = JobStatus.paused;
        final restored = DownloadJob.fromJson(
          asMap(jsonDecode(jsonEncode(task.toJson()))),
        );
        expect(asList(restored.request['missingFiles']).length, 1);
        final wrong = File('${temp.path}/wrong.jar');
        await wrong.writeAsString('wrong');
        expect(await importManualFiles(restored, [wrong.path]), 0);
        final downloaded = File('${temp.path}/blocked (1).jar');
        await downloaded.writeAsBytes(blocked);
        expect(await importManualFiles(restored, [downloaded.path]), 1);
        expect(restored.request['missingFiles'], isEmpty);
        final previous = client.requests.length;
        restored.status = JobStatus.running;
        await downloadRecoverably(net, files, restored, temp.path);
        expect(client.requests.length, previous);
        expect(await File(files.first.path).readAsBytes(), blocked);
      } finally {
        net.close();
      }
    },
  );

  test(
    'invalid key and cancellation cannot become manual file requests',
    () async {
      final client = TestClient((_) => TestResponse(401));
      final net = network(client);
      final task = job();
      try {
        final file = DownloadFile('${temp.path}/file.jar', [
          'https://edge.forgecdn.net/files/file.jar',
        ]);
        await expectLater(
          downloadRecoverably(net, [file], task, temp.path),
          throwsA(
            isA<CurseForgeAccessException>().having(
              (e) => e.statusCode,
              'code',
              401,
            ),
          ),
        );
        expect(task.request['missingFiles'], isNull);
        expect(client.requests.length, 1);
        task.status = JobStatus.paused;
        await expectLater(
          downloadRecoverably(net, [file], task, temp.path),
          throwsA(isA<JobPaused>()),
        );
        expect(client.requests.length, 1);
      } finally {
        net.close();
      }
    },
  );

  test('manual import rejects paths outside root', () async {
    final task = job()..status = JobStatus.paused;
    task.request['missingFiles'] = [
      {'path': '../escape.jar', 'hash': 'a' * 40},
    ];
    await expectLater(importManualFiles(task, []), throwsFormatException);
  });

  test(
    'resolved metadata persists in the job and mismatched identities cannot be cached',
    () async {
      var mismatch = false;
      final client = TestClient(
        (request) => TestResponse(
          200,
          text: jsonEncode({
            'data': request.uri.path.endsWith('/files/9')
                ? {
                    'id': mismatch ? 10 : 9,
                    'modId': 8,
                    'fileName': 'fixture.jar',
                    'downloadUrl': null,
                  }
                : {
                    'classId': 6,
                    'links': {
                      'websiteUrl':
                          'https://www.curseforge.com/minecraft/mc-mods/fixture',
                    },
                  },
          }),
        ),
      );
      final net = network(client), task = job();
      try {
        final resources = ResourceService(net);
        final first = await resources.cursePackFile('8', '9', job: task);
        final restored = DownloadJob.fromJson(
          asMap(jsonDecode(jsonEncode(task.toJson()))),
        );
        expect(
          await ResourceService(net).cursePackFile('8', '9', job: restored),
          first,
        );
        expect(client.requests.length, 2);
        mismatch = true;
        await expectLater(
          resources.cursePackFile('8', '9', job: job()),
          throwsFormatException,
        );
      } finally {
        net.close();
      }
    },
  );
}
