import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'core/models.dart';
import 'core/network.dart';
import 'core/repository.dart';
import 'core/installer.dart';
import 'core/resources.dart';
import 'core/modpacks.dart';
import 'core/discovery.dart';
import 'core/java_runtime.dart';

class AppState extends ChangeNotifier {
  final String dataPath;
  late AppSettings settings;
  late NetworkService network;
  late MinecraftInstaller installer;
  late ResourceService resources;
  late ModpackService packs;
  List<GameVersion> remoteVersions = [];
  List<LocalVersion> localVersions = [];
  List<DownloadJob> jobs = [];
  bool loadingVersions = false, scanning = false;
  String? versionsError, scanError;
  String? persistenceError;
  String? recoveryNotice;
  int discoveredAtStartup = 0;
  final GameDirectoryDiscovery discovery;
  final Future<List<JavaRuntime>> Function()? javaDiscovery;
  String? runningId;
  Timer? _notifyTimer, _saveTimer;
  Future<void> _saving = Future.value();
  bool _disposed = false;
  int _scanGeneration = 0;
  AppState(
    this.dataPath, {
    GameDirectoryDiscovery? discovery,
    this.javaDiscovery,
  }) : discovery = discovery ?? GameDirectoryDiscovery();

  Future<List<JavaRuntime>> installedJava() =>
      javaDiscovery?.call() ?? discoverJava(gameRoots: settings.roots);

  Future<void> initialize({bool remote = true}) async {
    await Directory(dataPath).create(recursive: true);
    final file = File(p.join(dataPath, 'settings.json'));
    try {
      settings = await file.exists()
          ? AppSettings.fromJson(asMap(decodeJson(await file.readAsString())))
          : AppSettings();
    } catch (_) {
      settings = AppSettings();
      final backup = File('${file.path}.bak');
      try {
        settings = AppSettings.fromJson(
          asMap(decodeJson(await backup.readAsString())),
        );
        recoveryNotice = '设置文件损坏，已从上次备份恢复。';
      } catch (_) {
        recoveryNotice = '设置文件无法读取，已使用默认设置。原文件已保留。';
      }
      if (await file.exists()) {
        await file.copy(
          '${file.path}.damaged-${DateTime.now().millisecondsSinceEpoch}',
        );
      }
    }
    String? preferredRoot;
    if (settings.autoDiscover) {
      for (final candidate in await discovery.defaults(
        executableDirectory: p.dirname(dataPath),
      )) {
        final key = discovery.identity(candidate.path);
        final recorded = settings.roots
            .where((r) => discovery.identity(r) == key)
            .firstOrNull;
        if (recorded != null || !settings.dismissedRoots.contains(key)) {
          preferredRoot ??= recorded ?? candidate.path;
        }
        if (!settings.roots.any((r) => discovery.identity(r) == key) &&
            !settings.dismissedRoots.contains(key)) {
          settings.roots.add(candidate.path);
          discoveredAtStartup++;
        }
      }
    }
    if (!settings.roots.contains(settings.selectedRoot)) {
      settings.selectedRoot = preferredRoot ?? settings.roots.firstOrNull;
    }
    network = NetworkService(settings)..onAudit = refresh;
    installer = MinecraftInstaller(network, p.join(dataPath, 'cache'));
    resources = ResourceService(network);
    packs = ModpackService(installer, resources);
    final tasksFile = File(p.join(dataPath, 'tasks.json'));
    try {
      if (await tasksFile.exists()) {
        final data = decodeJson(await tasksFile.readAsString());
        jobs = asList(data is Map ? data['tasks'] : data)
            .map((e) => DownloadJob.fromJson(asMap(e)))
            .toList();
      }
    } catch (_) {
      try {
        final data = asMap(
          decodeJson(await File('${tasksFile.path}.bak').readAsString()),
        );
        jobs = asList(data['tasks'])
            .map((e) => DownloadJob.fromJson(asMap(e)))
            .toList();
        recoveryNotice = '${recoveryNotice ?? ''} 任务文件损坏，已从备份恢复。'.trim();
      } catch (_) {
        recoveryNotice = '${recoveryNotice ?? ''} 任务文件无法读取，原文件已保留。'.trim();
      }
      if (await tasksFile.exists()) {
        await tasksFile.copy(
          '${tasksFile.path}.damaged-${DateTime.now().millisecondsSinceEpoch}',
        );
      }
    }
    for (final job in jobs) {
      job.onChanged = changed;
    }
    final cacheFile = File(p.join(dataPath, 'cache', 'version-manifest.json'));
    try {
      if (await cacheFile.exists()) {
        remoteVersions = asList(
          asMap(decodeJson(await cacheFile.readAsString()))['versions'],
        ).map((e) => GameVersion.fromJson(asMap(e))).toList();
        installer.versions = remoteVersions;
      }
    } catch (_) {}
    await scan();
    if (discoveredAtStartup > 0) await saveSafely();
    if (remote) unawaited(loadVersions());
  }

  String requireRoot() =>
      settings.selectedRoot ?? (throw StateError('请先添加游戏目录'));
  void changed() {
    if (_disposed) return;
    refresh();
    // Throttle, rather than debounce: progress notifications must not postpone
    // persistence forever while a long-running download is active.
    _saveTimer ??= Timer(const Duration(seconds: 1), () {
      _saveTimer = null;
      unawaited(saveSafely());
    });
  }

  void refresh() {
    if (_disposed) return;
    _notifyTimer ??= Timer(const Duration(milliseconds: 150), () {
      _notifyTimer = null;
      if (!_disposed) notifyListeners();
    });
  }

  Future<void> saveSafely() async {
    try {
      await save();
    } catch (e) {
      persistenceError = '无法保存任务和设置：$e';
      refresh();
    }
  }

  Future<void> save() {
    final config = settings.toJson();
    final tasks = jobs.map((j) => j.toJson()).toList();
    _saving = _saving.catchError((_) {}).then((_) async {
      Future<void> store(String name, Json data) async {
        final path = p.join(dataPath, name);
        final file = File(path);
        if (await file.exists()) {
          try {
            decodeJson(await file.readAsString());
            await file.copy('$path.bak');
          } on FormatException {
            // Never replace a valid backup with a corrupt primary file.
          }
        }
        await writeJson(path, data);
      }

      await store('settings.json', config);
      await store('tasks.json', {'tasks': tasks});
      persistenceError = null;
    });
    return _saving;
  }

  Future<void> loadVersions() async {
    if (loadingVersions) return;
    loadingVersions = true;
    versionsError = null;
    changed();
    try {
      remoteVersions = await installer.fetchVersions();
    } catch (e) {
      versionsError = '$e';
    } finally {
      loadingVersions = false;
      changed();
    }
  }

  Future<void> scan() async {
    final generation = ++_scanGeneration;
    scanning = true;
    scanError = null;
    changed();
    final root = settings.selectedRoot;
    try {
      final result = root == null
          ? <LocalVersion>[]
          : await GameRepository(root).scan();
      if (generation == _scanGeneration) localVersions = result;
    } catch (e) {
      if (generation == _scanGeneration) scanError = '$e';
    } finally {
      if (generation == _scanGeneration) scanning = false;
      changed();
    }
  }

  Future<void> addRoot(String path) async {
    await addRoots([path]);
  }

  Future<String> createRoot(String parent, String name) async {
    validateId(name, label: '文件夹名称');
    if (!p.isAbsolute(parent) || !await Directory(parent).exists()) {
      throw const FileSystemException('请选择已存在的父目录');
    }
    final base = await Directory(parent).resolveSymbolicLinks();
    final target = safeChild(base, name);
    if (await FileSystemEntity.type(target, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw const FileSystemException('同名文件或目录已存在，请更换名称，或直接选择已有目录');
    }
    await Directory(target).create();
    await addRoot(target);
    return settings.selectedRoot!;
  }

  Future<void> addRoots(Iterable<String> paths) async {
    final verified = <String>[];
    for (var path in paths) {
      if (path.trim().isEmpty || !p.isAbsolute(path)) {
        throw const FormatException('请选择绝对路径的游戏目录');
      }
      path = p.normalize(p.absolute(path));
      if (await Directory(path).exists()) {
        path = await Directory(path).resolveSymbolicLinks();
      }
      final unsafe =
          p.dirname(path) == path ||
          (Platform.isWindows &&
              [
                Platform.environment['WINDIR'],
                Platform.environment['USERPROFILE'],
              ].whereType<String>().any((v) => p.equals(v, path)));
      if (unsafe) throw StateError('请选择专门存放游戏的文件夹');
      safeChild(p.rootPrefix(path), p.relative(path, from: p.rootPrefix(path)));
      if (await FileSystemEntity.type(path) == FileSystemEntityType.file) {
        throw const FileSystemException('所选路径是文件，请选择文件夹');
      }
      await Directory(path).create(recursive: true);
      path = await Directory(path).resolveSymbolicLinks();
      verified.add(path);
    }
    if (verified.isEmpty) return;
    final previousRoots = List<String>.of(settings.roots);
    final previousDismissed = List<String>.of(settings.dismissedRoots);
    final previousSelection = settings.selectedRoot;
    final imported = <String>[];
    for (final path in verified) {
      final key = discovery.identity(path);
      final existing = settings.roots
          .where((r) => discovery.identity(r) == key)
          .firstOrNull;
      if (existing == null) settings.roots.add(path);
      settings.dismissedRoots.remove(key);
      imported.add(existing ?? path);
    }
    settings.selectedRoot = imported.first;
    try {
      await save();
    } catch (_) {
      settings.roots = previousRoots;
      settings.dismissedRoots = previousDismissed;
      settings.selectedRoot = previousSelection;
      rethrow;
    }
    await scan();
  }

  Future<void> selectRoot(String root) async {
    settings.selectedRoot = root;
    await save();
    await scan();
  }

  Future<void> setRootIsolation(String root, bool? isolate) async {
    if (!settings.roots.contains(root)) throw StateError('请先添加游戏目录');
    final previous = settings.rootIsolation[root];
    if (isolate == null) {
      settings.rootIsolation.remove(root);
    } else {
      settings.rootIsolation[root] = isolate;
    }
    try {
      await save();
    } catch (_) {
      if (previous == null) {
        settings.rootIsolation.remove(root);
      } else {
        settings.rootIsolation[root] = previous;
      }
      rethrow;
    }
    refresh();
  }

  Future<void> removeRoot(String root) async {
    final key = discovery.identity(root);
    if (!settings.dismissedRoots.contains(key)) {
      settings.dismissedRoots.add(key);
    }
    settings.roots.remove(root);
    settings.rootIsolation.remove(root);
    if (settings.selectedRoot == root) {
      settings.selectedRoot = settings.roots.firstOrNull;
    }
    await save();
    await scan();
  }

  DownloadJob enqueue(String title, String kind, Json request) {
    if (['install', 'pack', 'remotePack'].contains(kind) &&
        jobs.any(
          (j) =>
              j.active &&
              j.request['root'] == request['root'] &&
              j.request['id'] == request['id'],
        )) {
      throw StateError('该版本已有安装任务');
    }
    final job = DownloadJob(
      id: '${DateTime.now().microsecondsSinceEpoch}',
      title: title,
      kind: kind,
      request: request,
    )..onChanged = changed;
    jobs.insert(0, job);
    changed();
    unawaited(saveSafely());
    unawaited(_pump());
    return job;
  }

  void retry(DownloadJob job) {
    if (runningId == job.id) throw StateError('正在停止连接，请稍后再继续');
    if (job.active || job.status == JobStatus.completed) return;
    job.status = JobStatus.queued;
    job.error = '';
    job.stage = '等待恢复';
    job.notify();
    unawaited(_pump());
  }

  Future<void> _pump() async {
    if (runningId != null || _disposed) return;
    final job = jobs.reversed
        .where((j) => j.status == JobStatus.queued)
        .firstOrNull;
    if (job == null) return;
    runningId = job.id;
    job.status = JobStatus.running;
    job.log(
      '任务开始 · ${settings.sourceMode == SourceMode.official ? '官方源优先' : '镜像源优先'} · 代理 ${settings.proxyMode.name}',
    );
    try {
      await _execute(job);
      job.check();
      job.status = JobStatus.completed;
      job.stage = '已完成';
      job.log('任务完成');
    } on JobPaused {
      job.stage = '已暂停，可继续';
    } on JobCancelled {
      job.stage = '已取消，缓存可用于重试';
    } catch (e, stack) {
      job.status = JobStatus.failed;
      job.error = '$e';
      job.stage = '失败';
      job.log('$e');
      debugPrintStack(stackTrace: stack);
    } finally {
      runningId = null;
      job.notify();
      await saveSafely();
      await scan();
      unawaited(_pump());
    }
  }

  Future<LocalVersion> _target(Json request) async {
    final versions = await GameRepository(request['root']).scan();
    return versions.where((v) => v.id == request['target']).firstOrNull ??
        (throw StateError('目标版本已经不存在'));
  }

  Future<void> _execute(DownloadJob job) async {
    final r = job.request;
    switch (job.kind) {
      case 'saveGame':
        await installer.saveGame(
          r['game'],
          r['server'] == true,
          r['path'],
          job,
        );
      case 'install':
        await installer.install(InstallSpec.fromJson(r), job);
      case 'repair':
        await installer.repair(await _target(r), job, gameOverride: r['game']);
      case 'pack':
        await packs.install(
          await packs.inspect(r['file']),
          r['root'],
          r['id'],
          job,
        );
      case 'remotePack':
        final version = asMap(r['version']);
        final path = resources.cachePath(
          p.join(dataPath, 'cache', 'packs'),
          version,
        );
        await network.download(resources.downloadFile(version, path), job);
        await packs.install(await packs.inspect(path), r['root'], r['id'], job);
      case 'resource':
        await resources.install(
          asMap(r['version']),
          await _target(r),
          job,
          world: r['world'],
          update: r['update'] == true,
        );
      case 'save':
        await network.download(
          resources.downloadFile(asMap(r['version']), r['path']),
          job,
        );
      case 'world':
        String file;
        if (r['file'] != null) {
          file = r['file'];
        } else {
          final version = asMap(r['version']);
          file = safeChild(
            p.join(dataPath, 'cache', 'worlds'),
            version['filename'],
          );
          await network.download(resources.downloadFile(version, file), job);
        }
        await packs.installWorld(file, await _target(r), r['name'], job);
      case 'export':
        await packs.export(await _target(r), r['path'], job);
      case 'updates':
        final target = await _target(r);
        final updates = await resources.findUpdates(target, job);
        for (final update in updates) {
          await resources.install(update, target, job, update: true);
        }
        job.log(
          updates.isEmpty
              ? '已跟踪的资源均为最新版本'
              : '更新 ${updates.length} 项，旧文件保留为 .disabled',
        );
      default:
        throw StateError('无法恢复的任务类型 ${job.kind}');
    }
  }

  Future<List<Json>> contentFiles(LocalVersion version, String category) async {
    final folder = Directory(safeChild(version.contentPath, category));
    if (!await folder.exists()) return [];
    final rows = <Json>[];
    await for (final e in folder.list(followLinks: false)) {
      if (e is File || e is Directory) {
        final stat = await e.stat();
        rows.add({
          'name': p.basename(e.path),
          'path': e.path,
          'directory': e is Directory,
          'size': stat.size,
          'disabled': e.path.endsWith('.disabled'),
        });
      }
    }
    rows.sort(
      (a, b) => (a['name'] as String).toLowerCase().compareTo(
        (b['name'] as String).toLowerCase(),
      ),
    );
    return rows;
  }

  Future<void> toggleFile(LocalVersion version, String file) async {
    await guardPath(version.contentPath, file);
    final target = file.endsWith('.disabled')
        ? file.substring(0, file.length - 9)
        : '$file.disabled';
    if (await File(target).exists()) throw StateError('目标文件名已存在');
    await File(file).rename(target);
    final indexPath = p.join(version.contentPath, '.mcd-resources.json');
    final indexFile = File(indexPath);
    if (await indexFile.exists()) {
      final index = asMap(decodeJson(await indexFile.readAsString()));
      final old = p
          .relative(file, from: version.contentPath)
          .replaceAll('\\', '/');
      if (index.containsKey(old)) {
        index[p
            .relative(target, from: version.contentPath)
            .replaceAll('\\', '/')] = index.remove(
          old,
        );
      }
      await guardPath(version.contentPath, indexPath);
      await writeJson(indexPath, index);
    }
    changed();
  }

  Future<void> trashContent(LocalVersion version, String file) async {
    if (!p.isWithin(version.contentPath, file)) throw StateError('文件不在内容目录');
    await guardPath(version.contentPath, file);
    final target = safeChild(
      version.contentPath,
      '.mcd-trash/${DateTime.now().microsecondsSinceEpoch}/${p.basename(file)}',
    );
    await guardPath(version.contentPath, target);
    await Directory(p.dirname(target)).create(recursive: true);
    if (await FileSystemEntity.isDirectory(file)) {
      await Directory(file).rename(target);
    } else {
      await File(file).rename(target);
    }
    changed();
  }

  Future<void> importFiles(
    LocalVersion version,
    String category,
    List<String> files,
  ) async {
    for (final file in files) {
      final target = safeChild(
        version.contentPath,
        '$category/${p.basename(file)}',
      );
      await guardPath(version.contentPath, target);
      if (await File(target).exists()) {
        throw StateError('同名文件已存在：${p.basename(file)}');
      }
      await File(target).parent.create(recursive: true);
      await File(file).copy(target);
    }
    changed();
  }

  @override
  void dispose() {
    _disposed = true;
    _notifyTimer?.cancel();
    _saveTimer?.cancel();
    for (final job in jobs.where((j) => j.active)) {
      job.stop(pause: true);
    }
    network.close();
    super.dispose();
  }
}
