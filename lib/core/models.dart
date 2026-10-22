import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'release_credentials.dart';

typedef Json = Map<String, dynamic>;
Json asMap(dynamic value) =>
    value is Map ? Map<String, dynamic>.from(value) : {};
dynamic decodeJson(String text) =>
    jsonDecode(text.startsWith('\ufeff') ? text.substring(1) : text);
List<dynamic> asList(dynamic value) => value is List ? value : [];
String pretty(dynamic value) =>
    const JsonEncoder.withIndent('  ').convert(value);

enum ProxyMode { system, direct, manual }

enum SourceMode { official, mirror }

enum JobStatus { queued, running, paused, completed, failed, cancelled }

class AppSettings {
  List<String> roots = [];
  List<String> dismissedRoots = [];
  bool autoDiscover = true;
  String? selectedRoot;
  ProxyMode proxyMode = ProxyMode.system;
  String proxyUrl = 'http://127.0.0.1:7890';
  SourceMode sourceMode = SourceMode.official;
  String mirrorUrl = 'https://bmclapi2.bangbang93.com';
  bool fallback = true;
  int concurrency = 8;
  String javaPath = 'auto';
  String curseKey = '';
  String arch = 'x64';
  bool isolate = true;
  Map<String, bool> rootIsolation = {};
  bool dark = false;

  bool get usesBundledCurseForgeKey => hasBundledCurseForgeKey;
  String get effectiveCurseKey =>
      usesBundledCurseForgeKey ? bundledCurseForgeKey : curseKey;

  String get defaultResourceProvider =>
      effectiveCurseKey.trim().isEmpty ? 'Modrinth' : 'CurseForge';

  bool isolationFor(String root) => rootIsolation[root] ?? isolate;

  AppSettings();
  AppSettings.fromJson(Json j) {
    roots = asList(j['roots']).cast<String>();
    dismissedRoots = asList(j['dismissedRoots']).cast<String>();
    autoDiscover = j['autoDiscover'] != false;
    selectedRoot = j['selectedRoot'];
    proxyMode = ProxyMode.values.firstWhere(
      (e) => e.name == j['proxyMode'],
      orElse: () => ProxyMode.system,
    );
    proxyUrl = j['proxyUrl'] ?? proxyUrl;
    sourceMode = j['sourceMode'] == 'mirror'
        ? SourceMode.mirror
        : SourceMode.official;
    mirrorUrl = j['mirrorUrl'] ?? mirrorUrl;
    fallback = j['fallback'] != false;
    concurrency = ((j['concurrency'] as num?)?.toInt() ?? 8).clamp(1, 32);
    javaPath = j['javaPath'] ?? javaPath;
    curseKey = usesBundledCurseForgeKey ? '' : j['curseKey'] ?? '';
    arch = j['arch'] ?? arch;
    isolate = j['isolate'] != false;
    rootIsolation = {
      for (final entry in asMap(j['rootIsolation']).entries)
        if (entry.value is bool) entry.key: entry.value as bool,
    };
    dark = j['dark'] == true;
  }
  Json toJson() => {
    'roots': roots,
    'dismissedRoots': dismissedRoots,
    'autoDiscover': autoDiscover,
    'selectedRoot': selectedRoot,
    'proxyMode': proxyMode.name,
    'proxyUrl': proxyUrl,
    'sourceMode': sourceMode.name,
    'mirrorUrl': mirrorUrl,
    'fallback': fallback,
    'concurrency': concurrency,
    'javaPath': javaPath,
    'curseKey': usesBundledCurseForgeKey ? '' : curseKey,
    'arch': arch,
    'isolate': isolate,
    'rootIsolation': rootIsolation,
    'dark': dark,
  };
}

class GameVersion {
  final String id, type, url, released;
  final String? sha1;
  GameVersion.fromJson(Json j)
    : id = j['id'],
      type = j['type'] ?? 'release',
      url = j['url'],
      released = j['releaseTime'] ?? '',
      sha1 = j['sha1'];
}

class LocalVersion {
  final String root, id, game, loader, loaderVersion, contentPath;
  final Json manifest;
  final Map<String, String> components;
  final bool isolationKnown, identityKnown;
  final String error;
  LocalVersion({
    required this.root,
    required this.id,
    required this.game,
    required this.loader,
    required this.loaderVersion,
    required this.contentPath,
    required this.manifest,
    this.components = const {},
    this.isolationKnown = true,
    this.identityKnown = true,
    this.error = '',
  });
  String get path => p.join(root, 'versions', id);
  String get label => components.isNotEmpty
      ? components.entries.map((e) => '${e.key} ${e.value}'.trim()).join(' · ')
      : loader.isEmpty
      ? identityKnown
            ? '原版'
            : '未识别'
      : '$loader $loaderVersion'.trim();
}

class InstallSpec {
  final String root, id, game, loader, loaderVersion;
  final bool isolate, replace;
  InstallSpec({
    required this.root,
    required this.id,
    required this.game,
    this.loader = '',
    this.loaderVersion = '',
    this.isolate = true,
    this.replace = false,
  });
  InstallSpec.fromJson(Json j)
    : root = j['root'],
      id = j['id'],
      game = j['game'],
      loader = j['loader'] ?? '',
      loaderVersion = j['loaderVersion'] ?? '',
      isolate = j['isolate'] != false,
      replace = j['replace'] == true;
  Json toJson() => {
    'root': root,
    'id': id,
    'game': game,
    'loader': loader,
    'loaderVersion': loaderVersion,
    'isolate': isolate,
    'replace': replace,
  };
}

class DownloadFile {
  final String path;
  final List<String> urls;
  final String? hash;
  final String algorithm;
  final int? size;
  final Map<String, String> headers;
  DownloadFile(
    this.path,
    this.urls, {
    this.hash,
    this.algorithm = 'sha1',
    this.size,
    this.headers = const {},
  });
}

class JobCancelled implements Exception {}

class JobPaused implements Exception {}

class DownloadJob {
  final String id, title, kind;
  final Json request;
  JobStatus status;
  String stage = '等待中', error = '', currentUrl = '';
  int completedFiles = 0, totalFiles = 0, received = 0;
  int? currentFileSize;
  int currentFileReceived = 0;
  double bytesPerSecond = 0;
  bool committing = false;
  DateTime updated = DateTime.now();
  final List<String> logs = [];
  final Set<HttpClientRequest> connections = {};
  final Set<Process> processes = {};
  final Set<void Function()> streamStops = {};
  void Function()? onChanged;
  DownloadJob({
    required this.id,
    required this.title,
    required this.kind,
    required this.request,
    this.status = JobStatus.queued,
  });
  factory DownloadJob.fromJson(Json j) {
    final job = DownloadJob(
      id: j['id'],
      title: j['title'],
      kind: j['kind'],
      request: asMap(j['request']),
      status: JobStatus.values.firstWhere(
        (e) => e.name == j['status'],
        orElse: () => JobStatus.failed,
      ),
    );
    job.stage = j['stage'] ?? '';
    job.error = j['error'] ?? '';
    job.logs.addAll(asList(j['logs']).cast<String>());
    if (job.status == JobStatus.running || job.status == JobStatus.queued) {
      job.status = JobStatus.paused;
      job.stage = '上次退出时中断，点击继续后校验并恢复';
    }
    return job;
  }
  Json toJson() => {
    'id': id,
    'title': title,
    'kind': kind,
    'request': request,
    'status': status.name,
    'stage': stage,
    'error': error,
    'logs': logs,
  };
  bool get active => status == JobStatus.running || status == JobStatus.queued;
  double? get progress => currentFileSize != null && currentFileSize! > 0
      ? (currentFileReceived / currentFileSize!).clamp(0.0, 1.0)
      : totalFiles == 0
      ? null
      : completedFiles / totalFiles;
  void check() {
    if (status == JobStatus.paused) throw JobPaused();
    if (status == JobStatus.cancelled) throw JobCancelled();
  }

  void notify() {
    updated = DateTime.now();
    onChanged?.call();
  }

  void log(String text) {
    logs.add('${DateTime.now().toIso8601String().substring(11, 19)}  $text');
    if (logs.length > 500) logs.removeAt(0);
    notify();
  }

  void stop({bool pause = false}) {
    if (committing) {
      log('正在提交安装结果，请等待本次提交结束');
      return;
    }
    status = pause ? JobStatus.paused : JobStatus.cancelled;
    for (final connection in connections.toList()) {
      connection.abort();
    }
    for (final stop in streamStops.toList()) {
      stop();
    }
    for (final process in processes.toList()) {
      process.kill();
    }
    notify();
  }
}

String bytesLabel(num n) {
  if (n < 1024) return '${n.toInt()} B';
  if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
  if (n < 1024 * 1024 * 1024) {
    return '${(n / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  return '${(n / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}
