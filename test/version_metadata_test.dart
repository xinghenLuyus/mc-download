import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:mc_download/core/models.dart';
import 'package:mc_download/core/repository.dart';

void main() {
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('mcd-version-metadata-');
  });
  tearDown(() => root.delete(recursive: true));
  Future<void> version(String id, Json fields, {Json? saved}) async {
    await writeJson(p.join(root.path, 'versions', id, '$id.json'), {
      'id': id,
      ...fields,
    });
    if (saved != null) {
      await writeJson(p.join(root.path, 'versions', id, 'mcd.json'), saved);
    }
  }

  Future<LocalVersion> scan(String id) async =>
      (await GameRepository(root.path).scan()).singleWhere((v) => v.id == id);

  test(
    'official modern Forge libraries and FML arguments survive renamed instances',
    () async {
      await version('1.20.1', {'mainClass': 'net.minecraft.client.main.Main'});
      await version(
        'Create-Delight-Remake',
        {
          'inheritsFrom': '1.20.1',
          'mainClass': 'cpw.mods.bootstraplauncher.BootstrapLauncher',
          'libraries': [
            {'name': 'net.minecraftforge:fmlloader:1.20.1-47.3.33'},
            {'name': 'net.minecraftforge:fmlearlydisplay:1.20.1-47.3.33'},
          ],
          'arguments': {
            'game': [
              '--launchTarget',
              'forgeclient',
              '--fml.forgeVersion',
              '47.3.33',
              '--fml.mcVersion',
              '1.20.1',
            ],
          },
        },
        saved: {
          'game': 'stale-game',
          'loader': 'Fabric',
          'loaderVersion': 'stale-version',
          'isolate': true,
        },
      );
      final found = await scan('Create-Delight-Remake');
      expect(found.game, '1.20.1');
      expect(found.loader, 'Forge');
      expect(found.loaderVersion, '47.3.33');
      expect(found.contentPath, found.path);
      expect(found.label, 'Forge 47.3.33');
    },
  );
  test(
    'Forge is recognized from arguments alone and legacy tweak classes',
    () async {
      await version('arguments-only', {
        'arguments': {
          'game': ['--fml.mcVersion=1.20.1', '--fml.forgeVersion=47.4.0'],
        },
      });
      await version('legacy', {
        'clientVersion': '1.7.10',
        'minecraftArguments':
            '--tweakClass "cpw.mods.fml.common.launcher.FMLTweaker"',
      });
      expect((await scan('arguments-only')).loaderVersion, '47.4.0');
      expect((await scan('legacy')).loader, 'Forge');
    },
  );
  test(
    'inherited Forge and OptiFine are both shown without library-order dependence',
    () async {
      await version('base', {
        'libraries': [
          {'name': 'net.minecraftforge:forge:1.12.2-14.23.5.2859:universal'},
        ],
      });
      await version('combined', {
        'inheritsFrom': 'base',
        'libraries': [
          {'name': 'optifine:OptiFine:1.12.2_HD_U_G5'},
        ],
      });
      final found = await scan('combined');
      expect(found.game, '1.12.2');
      expect(found.loader, 'Forge');
      expect(found.components, {
        'Forge': '14.23.5.2859',
        'OptiFine': 'HD_U_G5',
      });
      expect(found.label, contains('OptiFine'));
    },
  );
  test(
    'NeoForge FML versions are not mistaken for Forge or loader-internal versions',
    () async {
      await version('neo', {
        'libraries': [
          {'name': 'net.neoforged.fancymodloader:loader:4.0.9'},
          {'name': 'net.neoforged:neoforge:21.1.80'},
        ],
        'arguments': {
          'game': [
            '--fml.mcVersion',
            '1.21.1',
            '--fml.neoForgeVersion',
            '21.1.80',
          ],
        },
      });
      await version('old-neo', {
        'arguments': {
          'game': [
            '--fml.mcVersion',
            '1.20.1',
            '--fml.forgeGroup',
            'net.neoforged',
            '--fml.forgeVersion',
            '47.1.105',
          ],
        },
      });
      expect((await scan('neo')).components, {'NeoForge': '21.1.80'});
      expect((await scan('old-neo')).loader, 'NeoForge');
    },
  );
  test(
    'HMCL patches are ordered and expanded for both scan and repair',
    () async {
      await version('patched', {
        'patches': [
          {
            'id': 'forge',
            'version': '47.3.33',
            'priority': 30000,
            'mainClass': 'cpw.mods.bootstraplauncher.BootstrapLauncher',
            'libraries': [
              {'name': 'net.minecraftforge:fmlloader:1.20.1-47.3.33'},
            ],
          },
          {
            'id': 'game',
            'version': '1.20.1',
            'priority': 0,
            'mainClass': 'net.minecraft.client.main.Main',
            'libraries': [
              {'name': 'com.mojang:logging:1.1.1'},
            ],
          },
        ],
      });
      final found = await scan('patched');
      expect(found.loader, 'Forge');
      expect(found.game, '1.20.1');
      final manifest = await GameRepository(root.path).readManifest('patched');
      expect(
        manifest['mainClass'],
        'cpw.mods.bootstraplauncher.BootstrapLauncher',
      );
      expect(manifest['libraries'], hasLength(2));
      expect(manifest['id'], 'patched');
    },
  );
  test(
    'Fabric Quilt vanilla and corrupt versions remain distinguishable',
    () async {
      await version('fabric', {
        'clientVersion': '1.21.1',
        'libraries': [
          {'name': 'net.fabricmc:fabric-loader:0.16.9'},
        ],
      });
      await version('quilt', {
        'patches': [
          {'id': 'game', 'version': '1.21.1'},
          {'id': 'quilt', 'version': '0.27.1'},
        ],
      });
      await version('vanilla', {
        'clientVersion': '1.21.1',
        'libraries': [
          {'name': 'net.minecraftforge:eventbus:6.0.5'},
        ],
      });
      await Directory(
        p.join(root.path, 'versions', 'vanilla', 'mods'),
      ).create();
      await version('broken', {'inheritsFrom': 'missing'});
      expect((await scan('fabric')).loader, 'Fabric');
      expect((await scan('quilt')).loader, 'Quilt');
      expect((await scan('vanilla')).label, '原版');
      expect((await scan('broken')).label, '未识别');
      expect((await scan('broken')).error, isNotEmpty);
    },
  );
  test(
    'uncertain entrypoints are not vanilla and stale tool records do not override vanilla',
    () async {
      await version('unknown', {
        'mainClass': 'cpw.mods.bootstraplauncher.BootstrapLauncher',
      });
      await version(
        'stale',
        {'mainClass': 'net.minecraft.client.main.Main'},
        saved: {'loader': 'Forge', 'loaderVersion': 'old'},
      );
      await version('damaged-tool-record', {
        'mainClass': 'net.minecraft.client.main.Main',
      });
      await File(
        p.join(root.path, 'versions', 'damaged-tool-record', 'mcd.json'),
      ).writeAsString('corrupt');
      await version('not-object', {});
      await File(
        p.join(root.path, 'versions', 'not-object', 'not-object.json'),
      ).writeAsString('[]');
      expect((await scan('not-object')).label, '未识别');
      expect((await scan('unknown')).label, '未识别');
      expect((await scan('stale')).label, '原版');
      expect((await scan('damaged-tool-record')).label, '原版');
    },
  );
  test(
    'NeoForge core metadata takes precedence over retained Forge libraries and legacy loaders are distinct',
    () async {
      await version('neo-core', {
        'libraries': [
          {'name': 'net.minecraftforge:fmlloader:1.20.1-47.1.105'},
          {'name': 'net.neoforged.fancymodloader:core:1.20.1-47.1.105'},
        ],
      });
      await version('legacy-fabric', {
        'mainClass': 'net.fabricmc.loader.launch.knot.KnotClient',
        'libraries': [
          {'name': 'net.fabricmc:fabric-loader:0.15.11'},
          {'name': 'net.legacyfabric:intermediary:1.7.10'},
        ],
      });
      await version('cleanroom', {
        'libraries': [
          {'name': 'com.cleanroommc:cleanroom:0.2.0'},
        ],
      });
      expect((await scan('neo-core')).components, {'NeoForge': '47.1.105'});
      expect((await scan('legacy-fabric')).loader, 'LegacyFabric');
      expect((await scan('cleanroom')).loader, 'Cleanroom');
    },
  );
}
