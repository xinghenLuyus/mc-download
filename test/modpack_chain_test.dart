import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:mc_download/core/installer.dart';
import 'package:mc_download/app_state.dart';
import 'package:mc_download/core/discovery.dart';
import 'package:mc_download/core/modpacks.dart';
import 'package:mc_download/core/models.dart';
import 'package:mc_download/core/network.dart';
import 'package:mc_download/core/repository.dart';
import 'package:mc_download/core/resources.dart';
import 'package:mc_download/core/version_metadata.dart';
import 'support/http_fixture.dart';

class QueueDiscovery extends GameDirectoryDiscovery {
  @override
  Future<List<GameDirectoryCandidate>> defaults({
    String? executableDirectory,
  }) async => [];
}

void main() {
  late Directory temp;
  late TestClient client;
  late NetworkService network;
  late MinecraftInstaller installer;
  late ResourceService resources;
  late ModpackService packs;
  late Map<String, List<int>> responses;
  String getRoot() => p.join(temp.path, 'game');
  Json artifact(String url, String text) {
    final bytes = utf8.encode(text);
    responses[url] = bytes;
    return {
      'url': url,
      'sha1': sha1.convert(bytes).toString(),
      'size': bytes.length,
    };
  }

  void json(String url, Object data) {
    responses[url] = utf8.encode(jsonEncode(data));
  }

  Future<String> zip(String name, Map<String, Object> files) async {
    final archive = Archive();
    files.forEach((path, content) {
      final bytes = content is List<int>
          ? content
          : utf8.encode(content is String ? content : jsonEncode(content));
      archive.addFile(ArchiveFile(path, bytes.length, bytes));
    });
    final file = p.join(temp.path, name);
    await File(file).writeAsBytes(ZipEncoder().encode(archive));
    return file;
  }

  Json mr({List<Json> files = const [], Json? dependencies}) => {
    'formatVersion': 1,
    'game': 'minecraft',
    'name': 'Fixture pack',
    'dependencies': dependencies ?? {'minecraft': '1.20.1'},
    'files': files,
  };
  DownloadJob job(String id) => DownloadJob(
    id: id,
    title: id,
    kind: 'pack',
    request: {},
    status: JobStatus.running,
  );
  Future<String> install(String archive, String id) async {
    final info = await packs.prepareImport(archive);
    await packs.install(info, getRoot(), id, job(id));
    return p.join(getRoot(), 'versions', id);
  }

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('mcd-pack-chain-');
    responses = {};
    client = TestClient(
      (request) => responses.containsKey(request.uri.toString())
          ? TestResponse(200, bytes: responses[request.uri.toString()])
          : TestResponse(404),
    );
    network = NetworkService(
      AppSettings()
        ..proxyMode = ProxyMode.direct
        ..fallback = false
        ..curseKey = 'fixture-key',
      clientFactory: () => client,
    );
    installer = MinecraftInstaller(network, p.join(temp.path, 'cache'));
    resources = ResourceService(network);
    packs = ModpackService(installer, resources);
    final library = artifact(
      'https://fixture.invalid/base.jar',
      'base library',
    );
    final sound = artifact('https://fixture.invalid/sound', 'sound');
    responses['https://resources.download.minecraft.net/${sound['sha1'].substring(0, 2)}/${sound['sha1']}'] =
        utf8.encode('sound');
    final index = artifact(
      'https://fixture.invalid/index.json',
      jsonEncode({
        'objects': {
          'sound': {'hash': sound['sha1'], 'size': sound['size']},
        },
      }),
    );
    json('https://fixture.invalid/version.json', {
      'id': '1.20.1',
      'mainClass': 'net.minecraft.client.main.Main',
      'downloads': {
        'client': artifact('https://fixture.invalid/client.jar', 'client'),
      },
      'libraries': [
        {
          'name': 'fixture:base:1',
          'downloads': {
            'artifact': {...library, 'path': 'fixture/base/1/base-1.jar'},
          },
        },
      ],
      'assetIndex': {'id': 'fixture', ...index},
    });
    installer.versions = [
      GameVersion.fromJson({
        'id': '1.20.1',
        'url': 'https://fixture.invalid/version.json',
      }),
    ];
  });
  tearDown(() async {
    network.clearProxyCache();
    await temp.delete(recursive: true);
  });

  test(
    'mrpack installs client, libraries, assets, loader, required files and override precedence',
    () async {
      final file = artifact(
        'https://cdn.modrinth.com/fixture.jar',
        'mod payload',
      );
      final fabric = artifact(
        'https://fixture.invalid/fabric.jar',
        'fabric loader',
      );
      json(
        'https://meta.fabricmc.net/v2/versions/loader/1.20.1/0.16.9/profile/json',
        {
          'mainClass': 'net.fabricmc.loader.impl.launch.knot.KnotClient',
          'libraries': [
            {
              'name': 'net.fabricmc:fabric-loader:0.16.9',
              'downloads': {
                'artifact': {
                  ...fabric,
                  'path':
                      'net/fabricmc/fabric-loader/0.16.9/fabric-loader-0.16.9.jar',
                },
              },
            },
          ],
        },
      );
      final original = await zip('pack.mrpack', {
        'modrinth.index.json': mr(
          dependencies: {'minecraft': '1.20.1', 'fabric-loader': '0.16.9'},
          files: [
            {
              'path': 'mods/required.jar',
              'hashes': {'sha1': file['sha1']},
              'fileSize': file['size'],
              'downloads': [file['url']],
            },
            {
              'path': 'mods/server.jar',
              'env': {'client': 'unsupported'},
              'downloads': ['https://fixture.invalid/never'],
            },
            {
              'path': 'mods/optional.jar',
              'env': {'client': 'optional'},
              'downloads': ['https://fixture.invalid/never'],
            },
          ],
        ),
        'overrides/config/settings.txt': 'common',
        'client-overrides/config/settings.txt': 'client',
        'server-overrides/config/settings.txt': 'server',
      });
      final info = await packs.prepareImport(original);
      await File(original).delete();
      await packs.install(info, getRoot(), 'fabric-pack', job('fabric-pack'));
      final version = (await GameRepository(getRoot()).scan()).single;
      expect(version.loader, 'Fabric');
      expect(version.loaderVersion, '0.16.9');
      expect(
        await File(p.join(version.path, 'mods/required.jar')).readAsString(),
        'mod payload',
      );
      expect(
        await File(p.join(version.path, 'config/settings.txt')).readAsString(),
        'client',
      );
      expect(
        await File(
          p.join(getRoot(), 'libraries/fixture/base/1/base-1.jar'),
        ).exists(),
        isTrue,
      );
      final soundHash = sha1.convert(utf8.encode('sound')).toString();
      expect(
        await File(
          p.join(
            getRoot(),
            'assets/objects/${soundHash.substring(0, 2)}/$soundHash',
          ),
        ).exists(),
        isTrue,
      );
      expect(client.requests.any((r) => r.uri.path == '/never'), isFalse);
    },
  );

  test(
    'standard HMCL patches rebuild Forge using a normalized Maven version',
    () async {
      expect(
        installerArtifactVersion('1.20.1', 'Forge', '47.3.33'),
        '1.20.1-47.3.33',
      );
      expect(
        installerArtifactVersion('1.20.1', 'Forge', '1.20.1-47.3.33'),
        '1.20.1-47.3.33',
      );
      expect(
        installerArtifactVersion('1.20.1', 'NeoForge', '47.1.105'),
        '1.20.1-47.1.105',
      );
      final forge = artifact(
        'https://fixture.invalid/fmlloader.jar',
        'forge loader',
      );
      final forgePatch = {
        'mainClass': 'net.minecraftforge.bootstrap.ForgeBootstrap',
        'arguments': {
          'game': [
            '--fml.mcVersion',
            '1.20.1',
            '--fml.forgeVersion',
            '47.3.33',
          ],
        },
        'libraries': [
          {
            'name': 'net.minecraftforge:fmlloader:1.20.1-47.3.33',
            'downloads': {
              'artifact': {
                ...forge,
                'path':
                    'net/minecraftforge/fmlloader/1.20.1-47.3.33/fmlloader-1.20.1-47.3.33.jar',
              },
            },
          },
        ],
      };
      final installerFile = await zip('forge.zip', {
        'install_profile.json': {
          'json': '/version.json',
          'libraries': [],
          'processors': [],
        },
        'version.json': forgePatch,
      });
      final cached = File(
        p.join(
          installer.cache,
          'installers/forge-1.20.1-47.3.33-installer.jar',
        ),
      );
      await cached.parent.create(recursive: true);
      await File(installerFile).copy(cached.path);
      final archive = await zip('hmcl.zip', {
        'wrapped/modpack.json': {
          'name': 'HMCL fixture',
          'gameVersion': '1.20.1',
        },
        'wrapped/minecraft/pack.json': {
          'id': 'old-name',
          'patches': [
            {'id': 'game', 'version': '1.20.1', 'priority': 0},
            {'id': 'forge', 'version': '47.3.33', 'priority': 30000},
          ],
        },
        'wrapped/minecraft/config/hmcl.txt': 'retained',
      });
      final path = await install(archive, 'hmcl-pack');
      expect((await GameRepository(getRoot()).scan()).single.loader, 'Forge');
      expect(
        await File(p.join(path, 'config/hmcl.txt')).readAsString(),
        'retained',
      );
      expect(await File(p.join(path, 'pack.json')).exists(), isFalse);
      expect(
        client.requests.any((r) => r.uri.host == 'maven.minecraftforge.net'),
        isFalse,
      );
    },
  );

  test(
    'CurseForge resources are classified instead of all being installed as mods',
    () async {
      final entries = <Json>[];
      for (final (id, type, name) in [
        (1, 6, 'mod.jar'),
        (2, 12, 'texture.zip'),
        (3, 6552, 'shader.zip'),
      ]) {
        final payload = artifact(
          'https://edge.forgecdn.net/$name',
          'payload $id',
        );
        json('https://api.curseforge.com/v1/mods/$id', {
          'data': {
            'classId': type,
            'links': {'websiteUrl': 'https://www.curseforge.com/project/$id'},
          },
        });
        json('https://api.curseforge.com/v1/mods/$id/files/10', {
          'data': {
            'id': 10,
            'modId': id,
            'fileName': name,
            'downloadUrl': payload['url'],
            'fileLength': payload['size'],
            'hashes': [
              {'algo': 1, 'value': payload['sha1']},
            ],
          },
        });
        entries.add({'projectID': id, 'fileID': 10, 'required': true});
      }
      final archive = await zip('curse.zip', {
        'manifest.json': {
          'name': 'Curse fixture',
          'minecraft': {'version': '1.20.1'},
          'files': entries,
          'overrides': 'overrides/',
        },
        'overrides/config/example.txt': 'config',
      });
      final path = await install(archive, 'curse-pack');
      expect(await File(p.join(path, 'mods/mod.jar')).exists(), isTrue);
      expect(
        await File(p.join(path, 'resourcepacks/texture.zip')).exists(),
        isTrue,
      );
      expect(
        await File(p.join(path, 'shaderpacks/shader.zip')).exists(),
        isTrue,
      );
      expect(await File(p.join(path, 'mods/texture.zip')).exists(), isFalse);
      expect(await File(p.join(path, 'config/example.txt')).exists(), isTrue);
      expect(
        client.requests
            .where((r) => isCurseForgeEndpoint(r.uri))
            .every((r) => r.headers.value('x-api-key') == 'fixture-key'),
        isTrue,
      );
    },
  );

  test(
    'failed required download never publishes a partial version and retry reuses verified files',
    () async {
      final first = artifact('https://fixture.invalid/one.jar', 'one');
      final second = artifact('https://fixture.invalid/two.jar', 'two');
      responses.remove(second['url']);
      final archive = await zip('retry.mrpack', {
        'modrinth.index.json': mr(
          files: [
            for (final entry in [('one', first), ('two', second)])
              {
                'path': 'mods/${entry.$1}.jar',
                'downloads': [entry.$2['url']],
                'hashes': {'sha1': entry.$2['sha1']},
                'fileSize': entry.$2['size'],
              },
          ],
        ),
      });
      final info = await packs.prepareImport(archive), task = job('retry');
      await expectLater(
        packs.install(info, getRoot(), 'retry-pack', task),
        throwsA(isA<HttpException>()),
      );
      expect(
        await Directory(p.join(getRoot(), 'versions/retry-pack')).exists(),
        isFalse,
      );
      final count = client.requests
          .where((r) => r.uri.toString() == first['url'])
          .length;
      responses[second['url']] = utf8.encode('two');
      await packs.install(info, getRoot(), 'retry-pack', task);
      expect(
        await File(
          p.join(getRoot(), 'versions/retry-pack/mods/two.jar'),
        ).exists(),
        isTrue,
      );
      expect(
        client.requests.where((r) => r.uri.toString() == first['url']).length,
        count,
      );
    },
  );

  test(
    'launcher-wrapped pack is unwrapped without extracting or executing bundled launchers',
    () async {
      final inner = await zip('inner.mrpack', {
        'modrinth.index.json': mr(),
        'overrides/config/value.txt': 'value',
      });
      final outer = await zip('wrapper.zip', {
        'bundle/modpack.mrpack': await File(inner).readAsBytes(),
        'bundle/Launcher.exe': 'never run',
      });
      final path = await install(outer, 'wrapped-pack');
      expect(await File(p.join(path, 'config/value.txt')).exists(), isTrue);
      expect(await File(p.join(path, 'Launcher.exe')).exists(), isFalse);
    },
  );

  test(
    'ambiguous packs, custom patches, missing hashes and unsafe paths fail before downloads',
    () async {
      final bad = await zip('bad.mrpack', {
        'modrinth.index.json': mr(
          files: [
            {
              'path': '../escape',
              'downloads': ['https://fixture.invalid/file'],
              'hashes': {},
            },
          ],
        ),
      });
      await expectLater(packs.prepareImport(bad), throwsFormatException);
      final ambiguous = await zip('ambiguous.zip', {
        'one/modrinth.index.json': mr(),
        'two/modrinth.index.json': mr(),
      });
      await expectLater(packs.inspect(ambiguous), throwsFormatException);
      final custom = await zip('custom.zip', {
        'modpack.json': {'gameVersion': '1.20.1'},
        'minecraft/pack.json': {
          'patches': [
            {'id': 'unknown-component', 'version': '1'},
          ],
        },
      });
      await expectLater(packs.inspect(custom), throwsStateError);
      expect(client.requests, isEmpty);
      final a = resources.cachePath(temp.path, {
        'provider': 'Modrinth',
        'id': 'one',
        'filename': 'pack.zip',
      });
      final b = resources.cachePath(temp.path, {
        'provider': 'Modrinth',
        'id': 'two',
        'filename': 'pack.zip',
      });
      expect(a, isNot(b));
    },
  );
  test(
    'MCBBS add-ons and MultiMC directories are preserved through standard installation',
    () async {
      final text = 'MCBBS config';
      final mcbbs = await zip('mcbbs.zip', {
        'mcbbs.packmeta': {
          'name': 'MCBBS',
          'addons': [
            {'id': 'game', 'version': '1.20.1'},
          ],
          'files': [
            {
              'type': 'addon',
              'path': 'config/settings.txt',
              'hash': sha1.convert(utf8.encode(text)).toString(),
            },
          ],
        },
        'overrides/config/settings.txt': text,
      });
      final a = await install(mcbbs, 'mcbbs-pack');
      expect(await File(p.join(a, 'config/settings.txt')).readAsString(), text);
      final mmc = await zip('mmc.zip', {
        'instance/mmc-pack.json': {
          'components': [
            {'uid': 'net.minecraft', 'version': '1.20.1'},
            {'uid': 'org.lwjgl3', 'version': '3.3.1'},
          ],
        },
        'instance/minecraft/config/value.txt': 'minecraft chosen',
        'instance/.minecraft/config/value.txt': 'alternative not merged',
      });
      final b = await install(mmc, 'mmc-pack');
      expect(
        await File(p.join(b, 'config/value.txt')).readAsString(),
        'minecraft chosen',
      );
    },
  );

  test(
    'CurseForge root overrides work and author-restricted downloads cannot publish an incomplete pack',
    () async {
      final rootOverride = await zip('root-override.zip', {
        'manifest.json': {
          'minecraft': {'version': '1.20.1'},
          'files': [],
          'overrides': '.',
        },
        'config/root.txt': 'root override',
      });
      final path = await install(rootOverride, 'root-pack');
      expect(
        await File(p.join(path, 'config/root.txt')).readAsString(),
        'root override',
      );
      expect(await File(p.join(path, 'manifest.json')).exists(), isFalse);
      json('https://api.curseforge.com/v1/mods/8', {
        'data': {
          'classId': 6,
          'links': {
            'websiteUrl':
                'https://www.curseforge.com/minecraft/mc-mods/restricted',
          },
        },
      });
      json('https://api.curseforge.com/v1/mods/8/files/9', {
        'data': {
          'id': 9,
          'modId': 8,
          'fileName': 'restricted.jar',
          'downloadUrl': null,
        },
      });
      final restricted = await zip('restricted.zip', {
        'manifest.json': {
          'minecraft': {'version': '1.20.1'},
          'files': [
            {'projectID': 8, 'fileID': 9},
          ],
        },
      });
      await expectLater(
        install(restricted, 'restricted-pack'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'manual download guidance',
            contains('restricted'),
          ),
        ),
      );
      expect(
        await Directory(p.join(getRoot(), 'versions/restricted-pack')).exists(),
        isFalse,
      );
    },
  );
  test(
    'remote modpack task downloads archive then installs and rescans the completed version',
    () async {
      final archive = await zip('remote.mrpack', {
        'modrinth.index.json': mr(),
        'overrides/config/remote.txt': 'downloaded bundle',
      });
      final bytes = await File(archive).readAsBytes();
      const url = 'https://cdn.modrinth.com/remote-bundle.mrpack';
      responses[url] = bytes;
      final state = AppState(
        p.join(temp.path, 'app-data'),
        discovery: QueueDiscovery(),
      );
      await state.initialize(remote: false);
      state.settings = network.settings
        ..roots = [getRoot()]
        ..selectedRoot = getRoot();
      state.network = network;
      state.installer = installer;
      state.resources = resources;
      state.packs = packs;
      final task = state.enqueue('remote', 'remotePack', {
        'root': getRoot(),
        'id': 'remote-pack',
        'version': {
          'provider': 'Modrinth',
          'id': 'remote',
          'filename': 'remote.mrpack',
          'urls': [url],
          'hash': sha1.convert(bytes).toString(),
          'algorithm': 'sha1',
          'size': bytes.length,
        },
      });
      final done = Completer<void>();
      void listener() {
        if (done.isCompleted) return;
        if (task.status == JobStatus.failed) {
          done.completeError(StateError(task.error));
        }
        if (task.status == JobStatus.completed &&
            !state.scanning &&
            state.localVersions.any((v) => v.id == 'remote-pack')) {
          done.complete();
        }
      }

      state.addListener(listener);
      try {
        await done.future.timeout(const Duration(seconds: 10));
        expect(
          await File(
            p.join(getRoot(), 'versions/remote-pack/config/remote.txt'),
          ).readAsString(),
          'downloaded bundle',
        );
        expect(task.status, JobStatus.completed);
      } finally {
        state.removeListener(listener);
        await state.save();
        state.dispose();
      }
    },
  );
}
