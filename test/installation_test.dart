import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:mc_download/core/installer.dart';
import 'package:mc_download/core/models.dart';
import 'package:mc_download/core/network.dart';
import 'package:mc_download/core/repository.dart';
import 'package:mc_download/core/modpacks.dart';
import 'package:mc_download/core/resources.dart';

void main() {
  test(
    'complete installation, inherited repair, corrupt metadata and replacement preserve user files',
    () async {
      final temp = await Directory.systemTemp.createTemp('mcd-install-');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final base = 'http://127.0.0.1:${server.port}';
      final files = <String, List<int>>{};
      Json artifact(String path, String text) {
        final bytes = utf8.encode(text);
        files[path] = bytes;
        return {
          'url': '$base$path',
          'size': bytes.length,
          'sha1': sha1.convert(bytes).toString(),
        };
      }

      final client = artifact('/client', 'fixture Minecraft jar');
      files['/version/1.20.1/client'] = files['/client']!;
      final lib = artifact('/lib', 'fixture library');
      final assetHash = sha1.convert(utf8.encode('fixture sound')).toString();
      files['/assets/${assetHash.substring(0, 2)}/$assetHash'] = utf8.encode(
        'fixture sound',
      );
      final asset = artifact(
        '/index',
        jsonEncode({
          'objects': {
            'sound/test': {'hash': assetHash, 'size': files.values.last.length},
          },
        }),
      );
      final metadata = artifact(
        '/metadata',
        jsonEncode({
          'id': '1.20.1',
          'downloads': {'client': client},
          'assetIndex': {'id': 'fixture', ...asset},
          'libraries': [
            {
              'name': 'fixture:library:1',
              'downloads': {
                'artifact': {'path': 'fixture/library/1/library-1.jar', ...lib},
              },
            },
          ],
        }),
      );
      server.listen((request) async {
        final content = files[request.uri.path];
        if (content == null) {
          request.response.statusCode = 404;
        } else {
          request.response.add(content);
        }
        await request.response.close();
      });
      final network = NetworkService(
        AppSettings()
          ..proxyMode = ProxyMode.direct
          ..sourceMode = SourceMode.mirror
          ..mirrorUrl = base
          ..fallback = false,
      );
      final installer = MinecraftInstaller(network, p.join(temp.path, 'cache'));
      installer.versions = [
        GameVersion.fromJson({'id': '1.20.1', 'type': 'release', ...metadata}),
      ];
      DownloadJob job(String id) => DownloadJob(
        id: id,
        title: id,
        kind: 'install',
        request: {},
        status: JobStatus.running,
      );
      final root = p.join(temp.path, '.minecraft');
      try {
        await installer.install(
          InstallSpec(root: root, id: 'vanilla', game: '1.20.1'),
          job('install'),
        );
        var versions = await GameRepository(root).scan();
        expect(versions.single.game, '1.20.1');
        final userFile = File(
          p.join(versions.single.path, 'saves', 'world', 'level.dat'),
        );
        await userFile.parent.create(recursive: true);
        await userFile.writeAsString('precious world');
        final libraryPath = p.join(
          root,
          'libraries',
          'fixture/library/1/library-1.jar',
        );
        await File(libraryPath).writeAsString('corrupted');
        await File(p.join(root, 'versions', 'vanilla', 'vanilla.jar')).delete();
        await installer.repair(versions.single, job('repair'));
        expect(await File(libraryPath).readAsString(), 'fixture library');
        await writeJson(p.join(root, 'versions', 'child', 'child.json'), {
          'id': 'child',
          'inheritsFrom': 'vanilla',
          'mainClass': 'fixture.Loader',
        });
        versions = await GameRepository(root).scan();
        expect(versions.firstWhere((v) => v.id == 'child').game, '1.20.1');
        await File(p.join(root, 'versions', 'vanilla', 'vanilla.jar')).delete();
        await installer.repair(
          versions.firstWhere((v) => v.id == 'child'),
          job('inherited'),
        );
        expect(
          await File(
            p.join(root, 'versions', 'vanilla', 'vanilla.jar'),
          ).exists(),
          true,
        );
        await Directory(
          p.join(root, 'versions', 'child'),
        ).delete(recursive: true);
        await File(
          p.join(root, 'versions', 'vanilla', 'vanilla.json'),
        ).writeAsString('broken');
        versions = await GameRepository(root).scan();
        expect(versions.single.error, isNotEmpty);
        await installer.repair(
          versions.single,
          job('metadata'),
          gameOverride: '1.20.1',
        );
        expect((await GameRepository(root).scan()).single.error, isEmpty);
        // Simulate interruption precisely between backup rename and final commit.
        final target = Directory(p.join(root, 'versions', 'vanilla'));
        final backup = Directory(p.join(root, '.mcd-trash', 'replace-vanilla'));
        await backup.parent.create(recursive: true);
        await target.rename(backup.path);
        await installer.install(
          InstallSpec(root: root, id: 'vanilla', game: '1.20.1', replace: true),
          job('replace'),
        );
        expect(await userFile.readAsString(), 'precious world');
        expect(
          await File(
            p.join(backup.path, 'saves/world/level.dat'),
          ).readAsString(),
          'precious world',
        );
        expect((await GameRepository(root).scan()).single.game, '1.20.1');
        final repo = GameRepository(root);
        final saved = await repo.backups();
        expect(saved.length, 1);
        await repo.restoreBackup(saved.single['path'], 'restored');
        expect(
          await File(
            p.join(root, 'versions/restored/saves/world/level.dat'),
          ).readAsString(),
          'precious world',
        );
        expect(
          await File(p.join(root, 'versions/restored/restored.jar')).exists(),
          true,
        );
        expect((await repo.readManifest('restored'))['id'], 'restored');
        await expectLater(
          repo.restoreBackup(saved.single['path'], 'restored'),
          throwsStateError,
        );
        final packs = ModpackService(installer, ResourceService(network));
        final pack = Archive();
        void add(String name, String value) {
          final bytes = utf8.encode(value);
          pack.addFile(ArchiveFile(name, bytes.length, bytes));
        }

        final resource = artifact('/resourcepack', 'fixture resource pack');
        add(
          'modrinth.index.json',
          jsonEncode({
            'formatVersion': 1,
            'game': 'minecraft',
            'name': 'Emergency fixture',
            'versionId': '1',
            'dependencies': {'minecraft': '1.20.1'},
            'files': [
              {
                'path': 'resourcepacks/fixture.zip',
                'downloads': [resource['url']],
                'hashes': {'sha1': resource['sha1']},
                'fileSize': resource['size'],
              },
            ],
          }),
        );
        add('overrides/config/example.txt', 'retained configuration');
        add('overrides/launcher_accounts.json', 'must not import accounts');
        final packFile = File(p.join(temp.path, 'fixture.mrpack'));
        await packFile.writeAsBytes(ZipEncoder().encode(pack));
        final info = await packs.inspect(packFile.path);
        await packs.install(info, root, 'pack', job('pack'));
        final installed = (await repo.scan()).firstWhere((v) => v.id == 'pack');
        expect(
          await File(
            p.join(installed.path, 'config/example.txt'),
          ).readAsString(),
          'retained configuration',
        );
        expect(
          await File(
            p.join(installed.path, 'resourcepacks/fixture.zip'),
          ).readAsString(),
          'fixture resource pack',
        );
        expect(
          await File(p.join(installed.path, 'launcher_accounts.json')).exists(),
          false,
        );
        final exported = p.join(temp.path, 'exported.mrpack');
        await packs.export(installed, exported, job('export'));
        expect((await packs.inspect(exported)).game, '1.20.1');
        expect(
          (await readZip(exported)).findFile('overrides/config/example.txt'),
          isNotNull,
        );
        final malicious = Archive()
          ..addFile(ArchiveFile('overrides/../../escape', 1, [1]));
        await expectLater(
          extractPrefix(
            malicious,
            'overrides/',
            installed.path,
            root,
            job('unsafe'),
          ),
          throwsFormatException,
        );
      } finally {
        network.close();
        await server.close(force: true);
        await temp.delete(recursive: true);
      }
    },
  );
}
