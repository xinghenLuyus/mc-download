import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:mc_download/core/discovery.dart';
import 'package:mc_download/core/repository.dart';
import 'package:mc_download/core/platform_support.dart';

void main() {
  late Directory temp;
  setUp(
    () async => temp = await Directory.systemTemp.createTemp('mcd-discovery-'),
  );
  tearDown(() async => temp.delete(recursive: true));

  test(
    'official roots are discovered, canonicalized and deduplicated',
    () async {
      final roaming = p.join(temp.path, 'AppData', 'Roaming');
      final root = Directory(p.join(roaming, '.minecraft'));
      await root.create(recursive: true);
      final discovery = GameDirectoryDiscovery(
        windows: true,
        environment: {'APPDATA': roaming, 'USERPROFILE': temp.path},
      );
      expect(
        (await discovery.defaults()).single.path,
        await root.resolveSymbolicLinks(),
      );
      await root.delete();
      expect(await discovery.defaults(), isEmpty);
    },
  );

  test(
    'launcher scan reads HMCL and PCL paths without entering asset trees',
    () async {
      final base = Directory(p.join(temp.path, 'launcher'));
      await base.create();
      final nested = Directory(
        p.join(base.path, 'instances', 'pack', '.minecraft'),
      );
      await nested.create(recursive: true);
      final outside = Directory(p.join(temp.path, 'custom-root'));
      await Directory(
        p.join(outside.path, 'versions', '1.20.1'),
      ).create(recursive: true);
      await writeJson(
        p.join(outside.path, 'versions', '1.20.1', '1.20.1.json'),
        {'id': '1.20.1'},
      );
      await writeJson(p.join(base.path, 'config', 'game-directories.json'), {
        'directories': [
          {'path': '../custom-root'},
        ],
      });
      await Directory(p.join(base.path, 'PCL')).create();
      await File(
        p.join(base.path, 'PCL', 'Setup.ini'),
      ).writeAsString('LaunchFolders:默认>\$instances/pack/.minecraft|\r\n');
      await Directory(
        p.join(base.path, 'assets', 'hidden', '.minecraft'),
      ).create(recursive: true);
      await File(p.join(base.path, 'HMCL.jar')).writeAsString('never executed');
      final result = await GameDirectoryDiscovery().fromLauncher(
        p.join(base.path, 'HMCL.jar'),
      );
      expect(result.directories.map((e) => e.path).toSet(), {
        await nested.resolveSymbolicLinks(),
        await outside.resolveSymbolicLinks(),
      });
      expect(result.limited, false);
    },
  );

  test(
    'bounded scan, cancellation, corrupt config and directory links',
    () async {
      await File(p.join(temp.path, 'hmcl.json')).writeAsString('bad json');
      await Directory(
        p.join(temp.path, 'a', 'b', '.minecraft'),
      ).create(recursive: true);
      final discovery = GameDirectoryDiscovery();
      final limited = await discovery.fromLauncher(temp.path, maxDepth: 1);
      expect(limited.limited, true);
      expect(limited.warnings, isNotEmpty);
      expect(
        (await discovery.fromLauncher(
          temp.path,
          cancelled: () => true,
        )).directories,
        isEmpty,
      );
      if (!Platform.isWindows) {
        await Link(p.join(temp.path, 'loop')).create(temp.path);
        final result = await discovery.fromLauncher(temp.path);
        expect(result.directories.length, 1);
      }
    },
  );

  test(
    'portable data stays beside exe regardless of working directory',
    () async {
      final executable = p.join(temp.path, 'MC Download', 'mc_download.exe');
      final result = await applicationDataDirectory(
        executablePath: executable,
        workingDirectory: p.join(temp.path, 'shortcut-working-directory'),
        windows: true,
      );
      expect(result, p.join(temp.path, 'MC Download', '.mcdownload'));
      expect(await Directory(result).exists(), false);
    },
  );

  test('development data stays in the project working directory', () async {
    expect(
      await applicationDataDirectory(
        workingDirectory: temp.path,
        windows: false,
      ),
      p.join(temp.path, '.mcdownload'),
    );
  });
}
