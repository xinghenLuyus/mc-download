import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:mc_download/core/models.dart';
import 'package:mc_download/core/network.dart';
import 'package:mc_download/core/installer.dart';
import 'package:mc_download/core/repository.dart';
import 'package:mc_download/core/resources.dart';

// Actual downloads and installer processors, never launches Minecraft.
// Keeps its isolated fixture for inspection and reuse. No user launcher directory.
Future<void> main(List<String> args) async {
  final base = p.absolute('orther', 'local-data', 'installation-probe');
  final settings = AppSettings()..proxyMode = ProxyMode.direct;
  final network = NetworkService(settings);
  final installer = MinecraftInstaller(network, p.join(base, 'cache'));
  final results = <Json>[];
  try {
    await installer.fetchVersions();
    final loader = args.isEmpty ? 'Fabric' : args.first;
    final loaders = await installer.loaderVersions('1.20.1', loader);
    final selected = loaders.firstWhere((e) => e['stable'] == true);
    final root = p.join(base, loader.toLowerCase());
    final job = DownloadJob(
      id: 'real-$loader',
      title: loader,
      kind: 'install',
      request: {},
      status: JobStatus.running,
    );
    String last = '';
    job.onChanged = () {
      if (job.stage != last) {
        last = job.stage;
        stdout.writeln('${DateTime.now().toIso8601String()} $last');
      }
    };
    final watch = Stopwatch()..start();
    final installedThisRun = !await Directory(
      p.join(root, 'versions', 'emergency'),
    ).exists();
    if (installedThisRun) {
      await installer.install(
        InstallSpec(
          root: root,
          id: 'emergency',
          game: '1.20.1',
          loader: loader,
          loaderVersion: selected['version'],
        ),
        job,
      );
    }
    final version = (await GameRepository(root).scan()).single;
    if (version.game != '1.20.1' || version.loader != loader) {
      throw StateError('版本扫描识别错误');
    }
    final manifest = await GameRepository(root).readManifest(version.id);
    final library = installer
        .libraries(root, asList(manifest['libraries']))
        .first;
    await File(library.path).writeAsString('corrupted fixture');
    await installer.repair(version, job);
    if (!await validFile(library)) throw StateError('支持库修复未通过校验');
    bool resourceVerified = false;
    if (loader == 'Fabric') {
      final resources = ResourceService(network);
      final rows = await resources.search(
        provider: 'Modrinth',
        kind: 'mod',
        query: 'Fabric API',
        game: '1.20.1',
        loader: loader,
      );
      final project = rows.firstWhere((e) => e['id'] == 'P7dR8mSH');
      final files = await resources.versions(
        project,
        game: '1.20.1',
        loader: loader,
      );
      await resources.install(files.first, version, job);
      final installed = resources.downloadFile(
        files.first,
        p.join(version.contentPath, 'mods', files.first['filename']),
      );
      resourceVerified = await validFile(installed);
      if (!resourceVerified) throw StateError('Modrinth 资源校验未通过');
    }
    results.add({
      'loader': loader,
      'loaderVersion': version.loaderVersion,
      'ok': true,
      'installedThisRun': installedThisRun,
      'seconds': watch.elapsed.inSeconds,
      'libraryRepair': true,
      if (loader == 'Fabric') 'modrinthResourceVerified': resourceVerified,
      'host': Platform.operatingSystem,
      'gameLaunched': false,
    });
    stdout.writeln('PASS ${pretty(results.single)}');
    await writeJson(
      p.absolute('orther', 'reports', 'installation-${loader.toLowerCase()}-report.json'),
      {
        'time': DateTime.now().toIso8601String(),
        'results': results,
        'logs': job.logs,
      },
    );
  } finally {
    network.close();
  }
}
