import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'models.dart';
import 'app_version.dart';
import 'system_proxy.dart';

bool isCurseForgeEndpoint(Uri uri) =>
    uri.host == 'api.curseforge.com' ||
    uri.host == 'forgecdn.net' ||
    uri.host.endsWith('.forgecdn.net');

class CurseForgeAccessException implements Exception {
  final String message;
  final int? statusCode;
  const CurseForgeAccessException(this.message, {this.statusCode});
  @override
  String toString() => message;
}

String safeUrl(String value) {
  final u = Uri.parse(value);
  return u
      .replace(userInfo: '', query: u.hasQuery ? '…' : null, fragment: '')
      .toString();
}

class SourcePolicy {
  final AppSettings settings;
  SourcePolicy(this.settings);
  static const manifest =
      'https://piston-meta.mojang.com/mc/game/version_manifest_v2.json';
  List<String> candidates(String original, {String? mirrorPath}) {
    final uri = Uri.parse(original);
    final base = settings.mirrorUrl.replaceAll(RegExp(r'/+$'), '');
    String? alternate;
    if (mirrorPath != null) {
      alternate = '$base$mirrorPath';
    } else if ([
      'piston-meta.mojang.com',
      'piston-data.mojang.com',
      'launchermeta.mojang.com',
      'launcher.mojang.com',
    ].contains(uri.host)) {
      alternate = '$base${uri.path}';
    } else if (uri.host == 'resources.download.minecraft.net') {
      alternate = '$base/assets${uri.path}';
    } else if (uri.host == 'libraries.minecraft.net') {
      alternate = '$base/libraries${uri.path}';
    } else if (uri.host == 'maven.minecraftforge.net') {
      alternate = '$base/maven${uri.path}';
    } else if (uri.host == 'maven.neoforged.net' &&
        uri.path.startsWith('/releases/')) {
      alternate = '$base/maven/${uri.path.substring('/releases/'.length)}';
    } else if (uri.host == 'maven.fabricmc.net') {
      alternate = '$base/maven${uri.path}';
    } else if (uri.host == 'meta.fabricmc.net') {
      alternate = '$base/fabric-meta${uri.path}';
    }
    if (alternate == null || alternate == original) return [original];
    final first = settings.sourceMode == SourceMode.official
        ? original
        : alternate;
    final second = first == original ? alternate : original;
    return settings.fallback ? [first, second] : [first];
  }
}

class NetworkService {
  final AppSettings settings;
  final HttpClient Function() _clientFactory;
  final Future<SystemProxyResult> Function(Uri) _systemProxy;
  final Map<String, HttpClient> _clients = {};
  final Map<String, ({DateTime time, String proxy})> _systemCache = {};
  final Map<String, Future<String>> _resolving = {};
  final List<String> audit = [];
  final Set<String> _batchJobs = {};
  void Function()? onAudit;
  NetworkService(
    this.settings, {
    HttpClient Function()? clientFactory,
    Future<SystemProxyResult> Function(Uri)? systemProxyResolver,
  }) : _clientFactory = clientFactory ?? HttpClient.new,
       _systemProxy = systemProxyResolver ?? resolveSystemProxy;
  SourcePolicy get sources => SourcePolicy(settings);

  String requireCurseForgeKey() {
    final key = settings.curseKey.trim();
    if (key.isEmpty) {
      throw const CurseForgeAccessException(
        '请先在“设置 → CurseForge”填写并保存 API Key，再进行 CurseForge 查询或下载；设置页提供申请指引。',
      );
    }
    if (key.contains(RegExp(r'[\r\n]'))) {
      throw const CurseForgeAccessException(
        'CurseForge API Key 含有换行，请在设置中重新粘贴完整 Key。',
      );
    }
    return key;
  }

  void checkCurseForgeUrl(Uri uri) {
    if (!isCurseForgeEndpoint(uri)) return;
    requireCurseForgeKey();
    if (uri.scheme != 'https') {
      throw const CurseForgeAccessException('CurseForge 查询和下载必须使用 HTTPS 地址。');
    }
  }

  Map<String, String> headersForRequest(
    Uri uri, {
    required Uri origin,
    Map<String, String> headers = const {},
  }) {
    checkCurseForgeUrl(uri);
    final sameOrigin =
        uri.scheme == origin.scheme &&
        uri.host == origin.host &&
        uri.port == origin.port;
    final result = <String, String>{};
    for (final entry in headers.entries) {
      final name = entry.key.toLowerCase();
      if (sameOrigin ||
          !['x-api-key', 'authorization', 'cookie'].contains(name)) {
        result[name] = entry.value;
      }
    }
    // Recompute for every redirect and Range request. Never forward the key to
    // an arbitrary host provided by a resource URL or a redirect response.
    if (isCurseForgeEndpoint(uri)) result['x-api-key'] = requireCurseForgeKey();
    return result;
  }

  void checkCurseForgeStatus(Uri uri, int status) {
    if (!isCurseForgeEndpoint(uri)) return;
    if (status == 401) {
      throw const CurseForgeAccessException(
        'CurseForge 鉴权失败（401）：API Key 无效、已失效或未获授权，请在设置中检查 Key 并重新验证。',
        statusCode: 401,
      );
    }
    if (status == 403) {
      throw const CurseForgeAccessException(
        'CurseForge 拒绝访问（403）：请检查 API Key 的权限；作者限制第三方下载的文件需在官网手动获取后导入。',
        statusCode: 403,
      );
    }
  }

  void record(String message) {
    audit.add(
      '${DateTime.now().toIso8601String().substring(11, 19)}  $message',
    );
    if (audit.length > 300) audit.removeAt(0);
    onAudit?.call();
  }

  Future<String> proxyFor(Uri uri) async {
    if (settings.proxyMode == ProxyMode.direct) return 'DIRECT';
    if (settings.proxyMode == ProxyMode.manual) {
      final proxy = Uri.tryParse(settings.proxyUrl);
      if (proxy == null ||
          proxy.scheme != 'http' ||
          proxy.host.isEmpty ||
          !proxy.hasPort ||
          proxy.port == 0) {
        throw const FormatException('手动代理请输入 http://主机:端口，可含用户名和密码；暂不支持 SOCKS');
      }
      return 'PROXY ${proxy.host}:${proxy.port}';
    }
    final origin = '${uri.scheme}://${uri.host}:${uri.port}';
    final key = uri.replace(fragment: '').toString();
    final old = _systemCache[key] ?? _systemCache[origin];
    if (old != null && DateTime.now().difference(old.time).inSeconds < 120) {
      return old.proxy;
    }
    return _resolving.putIfAbsent(key, () async {
      try {
        final result = await _systemProxy(uri);
        if (_systemCache.length >= 256) {
          _systemCache.remove(_systemCache.keys.first);
        }
        _systemCache[result.perUrl ? key : origin] = (
          time: DateTime.now(),
          proxy: result.route,
        );
        return result.route;
      } finally {
        _resolving.remove(key);
      }
    });
  }

  void clearProxyCache() {
    _systemCache.clear();
  }

  void close() {
    for (final c in _clients.values) {
      c.close(force: true);
    }
    _clients.clear();
  }

  Future<HttpClient> _client(Uri uri) async {
    final route = await proxyFor(uri);
    final key = '${settings.proxyMode.name}:${settings.proxyUrl}:$route';
    return _clients.putIfAbsent(key, () {
      final client = _clientFactory()
        ..connectionTimeout = const Duration(seconds: 20)
        ..idleTimeout = const Duration(seconds: 20)
        ..maxConnectionsPerHost = settings.concurrency
        ..userAgent =
            'MC-Download/$appVersion (Windows; Minecraft folder manager)'
        ..findProxy = (_) => route;
      if (settings.proxyMode == ProxyMode.manual) {
        final proxy = Uri.parse(settings.proxyUrl);
        if (proxy.userInfo.isNotEmpty) {
          final split = proxy.userInfo.indexOf(':');
          final user = Uri.decodeComponent(
            split < 0 ? proxy.userInfo : proxy.userInfo.substring(0, split),
          );
          final password = split < 0
              ? ''
              : Uri.decodeComponent(proxy.userInfo.substring(split + 1));
          client.authenticateProxy = (host, port, scheme, realm) async {
            client.addProxyCredentials(
              host,
              port,
              realm ?? '',
              HttpClientBasicCredentials(user, password),
            );
            return true;
          };
        }
      }
      return client;
    });
  }

  Future<({HttpClientRequest request, HttpClientResponse response, String url})>
  open(
    String url, {
    Map<String, String> headers = const {},
    DownloadJob? job,
  }) async {
    var current = Uri.parse(url);
    if (!['http', 'https'].contains(current.scheme) ||
        current.host.isEmpty ||
        current.userInfo.isNotEmpty) {
      throw FormatException('无效下载地址：${safeUrl(url)}');
    }
    final origin = current;
    for (var i = 0; i < 8; i++) {
      job?.check();
      final requestHeaders = headersForRequest(
        current,
        origin: origin,
        headers: headers,
      );
      final client = await _client(current);
      job?.check();
      final request = await client.getUrl(current);
      request.followRedirects = false;
      requestHeaders.forEach(request.headers.set);
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      job?.connections.add(request);
      if (job != null) job.currentUrl = safeUrl(current.toString());
      record('GET ${safeUrl(current.toString())} · ${await proxyFor(current)}');
      try {
        final response = await request.close().timeout(
          const Duration(seconds: 30),
        );
        if (isCurseForgeEndpoint(current) &&
            [401, 403].contains(response.statusCode)) {
          await body(response, job).drain<void>();
          checkCurseForgeStatus(current, response.statusCode);
        }
        if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
          final location = response.headers.value('location');
          await body(response, job).drain<void>();
          job?.connections.remove(request);
          if (location == null) throw const HttpException('重定向缺少 Location');
          final next = current.resolve(location);
          if (!['http', 'https'].contains(next.scheme) ||
              next.userInfo.isNotEmpty ||
              (current.scheme == 'https' && next.scheme != 'https')) {
            throw const HttpException('拒绝不安全的下载重定向');
          }
          current = next;
          continue;
        }
        record('HTTP ${response.statusCode} ← ${safeUrl(current.toString())}');
        return (request: request, response: response, url: current.toString());
      } catch (_) {
        job?.connections.remove(request);
        request.abort();
        rethrow;
      }
    }
    throw const HttpException('下载地址重定向过多');
  }

  Stream<List<int>> body(HttpClientResponse response, DownloadJob? job) {
    final source = response.timeout(const Duration(seconds: 40));
    if (job == null) return source;
    late StreamController<List<int>> controller;
    late StreamSubscription<List<int>> subscription;
    var ended = false;
    void stop() {
      if (ended) return;
      ended = true;
      controller.addError(
        job.status == JobStatus.paused ? JobPaused() : JobCancelled(),
      );
      unawaited(subscription.cancel());
      unawaited(controller.close());
    }

    controller = StreamController<List<int>>(
      onListen: () {
        subscription = source.listen(
          controller.add,
          onError: controller.addError,
          onDone: () {
            ended = true;
            unawaited(controller.close());
          },
        );
        job.streamStops.add(stop);
        if (job.status == JobStatus.paused ||
            job.status == JobStatus.cancelled) {
          stop();
        }
      },
      onPause: () => subscription.pause(),
      onResume: () => subscription.resume(),
      onCancel: () {
        job.streamStops.remove(stop);
        return subscription.cancel();
      },
    );
    return controller.stream;
  }

  Future<dynamic> json(
    List<String> urls, {
    Map<String, String> headers = const {},
    DownloadJob? job,
  }) async {
    Object? last;
    for (final url in urls) {
      try {
        return decodeJson(await text([url], headers: headers, job: job));
      } catch (e) {
        job?.check();
        if (e is CurseForgeAccessException) rethrow;
        last = e;
        record('元数据来源失败：${safeUrl(url)}');
      }
    }
    throw last ?? const HttpException('没有可用元数据来源');
  }

  Future<String> text(
    List<String> urls, {
    Map<String, String> headers = const {},
    DownloadJob? job,
    bool Function(String)? validate,
  }) async {
    Object? last;
    for (final url in urls) {
      for (var attempt = 0; attempt < 2; attempt++) {
        job?.check();
        try {
          final connection = await open(url, headers: headers, job: job);
          try {
            if (connection.response.statusCode != 200) {
              final status = connection.response.statusCode;
              final retry = connection.response.headers.value('retry-after');
              await body(connection.response, job).drain<void>();
              if (status == 429) {
                await Future<void>.delayed(
                  Duration(
                    seconds: (int.tryParse(retry ?? '') ?? 3).clamp(1, 30),
                  ),
                );
              }
              throw HttpException('HTTP $status：${safeUrl(url)}');
            }
            final bytes = <int>[];
            await for (final data in body(connection.response, job)) {
              job?.check();
              bytes.addAll(data);
              if (bytes.length > 32 * 1024 * 1024) {
                throw const HttpException('元数据超过 32 MB');
              }
            }
            final value = utf8.decode(bytes);
            if (validate != null && !validate(value)) {
              throw const FormatException('下载源返回了无效元数据');
            }
            return value;
          } finally {
            job?.connections.remove(connection.request);
          }
        } catch (e) {
          job?.check();
          if (e is CurseForgeAccessException) rethrow;
          last = e;
        }
      }
      job?.log('来源不可用，尝试下一候选：${safeUrl(url)}');
    }
    throw last ?? const HttpException('没有可用下载源');
  }

  Future<void> download(DownloadFile item, DownloadJob job) async {
    if (_batchJobs.contains(job.id)) return _download(item, job);
    final watch = Stopwatch()..start();
    final initialBytes = job.received;
    job.totalFiles = 1;
    job.completedFiles = 0;
    job.currentFileSize = item.size;
    job.currentFileReceived = 0;
    final timer = Timer.periodic(const Duration(milliseconds: 400), (_) {
      job.bytesPerSecond =
          (job.received - initialBytes) *
          1000 /
          max(1, watch.elapsedMilliseconds);
      job.notify();
    });
    try {
      await _download(item, job);
      job.completedFiles = 1;
    } finally {
      timer.cancel();
      job.bytesPerSecond = 0;
      job.currentFileSize = null;
      job.notify();
    }
  }

  Future<void> _download(DownloadFile item, DownloadJob job) async {
    job.check();
    for (final url in item.urls) {
      checkCurseForgeUrl(Uri.parse(url));
    }
    final target = File(item.path);
    if (await validFile(item)) return;
    await target.parent.create(recursive: true);
    final partial = File('${item.path}.part');
    final etag = File('${item.path}.part.etag');
    Object? last;
    for (final url in item.urls) {
      for (var attempt = 0; attempt < 3; attempt++) {
        job.check();
        RandomAccessFile? sink;
        HttpClientRequest? active;
        try {
          var offset = await partial.exists() ? await partial.length() : 0;
          if (offset > 0 && item.hash == null && !await etag.exists()) {
            await partial.delete();
            offset = 0;
          }
          final headers = {...item.headers};
          if (offset > 0) {
            headers['Range'] = 'bytes=$offset-';
            if (await etag.exists()) {
              headers['If-Range'] = await etag.readAsString();
            }
          }
          final connection = await open(url, headers: headers, job: job);
          active = connection.request;
          final response = connection.response;
          if (response.statusCode == 416) {
            await body(response, job).drain<void>();
            if (await partial.exists()) await partial.delete();
            throw const HttpException('续传范围失效，重新下载');
          }
          if (![200, 206].contains(response.statusCode)) {
            final code = response.statusCode;
            final retry = response.headers.value('retry-after');
            await body(response, job).drain<void>();
            if (code == 429) {
              await Future<void>.delayed(
                Duration(
                  seconds: (int.tryParse(retry ?? '') ?? 4).clamp(1, 30),
                ),
              );
            }
            throw HttpException('HTTP $code');
          }
          final append = offset > 0 && response.statusCode == 206;
          final single = !_batchJobs.contains(job.id);
          if (single) {
            job.currentFileReceived = append ? offset : 0;
            job.currentFileSize =
                item.size ??
                (response.contentLength < 0
                    ? null
                    : response.contentLength + (append ? offset : 0));
          }
          if (response.statusCode == 206) {
            final range = response.headers.value('content-range') ?? '';
            if (!range.startsWith('bytes $offset-')) {
              throw const HttpException('服务器返回了错误的续传范围');
            }
          }
          final tag = response.headers.value('etag');
          if (tag != null && !tag.startsWith('W/')) {
            await etag.writeAsString(tag);
          }
          sink = await partial.open(
            mode: append ? FileMode.append : FileMode.write,
          );
          // Each received chunk reaches the file before reading the next one.
          // An aborted response cannot discard bytes buffered in an IOSink.
          await for (final chunk in body(response, job)) {
            job.check();
            await sink.writeFrom(chunk);
            job.received += chunk.length;
            if (single) job.currentFileReceived += chunk.length;
          }
          await sink.close();
          sink = null;
          if (!await validFile(
            DownloadFile(
              partial.path,
              [],
              hash: item.hash,
              algorithm: item.algorithm,
              size: item.size,
            ),
          )) {
            await partial.delete();
            throw const HttpException('文件大小或哈希校验失败');
          }
          job.check();
          if (await target.exists()) await target.delete();
          await partial.rename(target.path);
          if (await etag.exists()) await etag.delete();
          return;
        } catch (e) {
          if (sink != null) {
            try {
              await sink.close();
            } catch (_) {}
          }
          active?.abort();
          job.check();
          if (e is CurseForgeAccessException) {
            if (e.statusCode != 403) rethrow;
            last = e;
            break;
          }
          last = e;
          job.log('重试 ${attempt + 1}/3 · ${safeUrl(url)} · $e');
          await Future<void>.delayed(
            Duration(milliseconds: 400 * (attempt + 1)),
          );
        } finally {
          if (active != null) job.connections.remove(active);
        }
      }
      // A different mirror may serve a different entity; never splice unchecked bytes.
      if (item.hash == null && await partial.exists()) await partial.delete();
      if (await etag.exists()) await etag.delete();
    }
    throw HttpException('下载失败 ${item.path}：$last');
  }

  Future<void> batch(
    List<DownloadFile> files,
    DownloadJob job, {
    Future<bool> Function(DownloadFile, Object)? onFailure,
  }) async {
    job.check();
    for (final file in files) {
      for (final url in file.urls) {
        checkCurseForgeUrl(Uri.parse(url));
      }
    }
    _batchJobs.add(job.id);
    job.currentFileSize = null;
    final unique = {for (final f in files) f.path: f}.values.toList();
    job.totalFiles = unique.length;
    job.completedFiles = 0;
    job.notify();
    var index = 0;
    Object? failure;
    final watch = Stopwatch()..start();
    final initialBytes = job.received;
    final timer = Timer.periodic(const Duration(milliseconds: 400), (_) {
      job.bytesPerSecond =
          (job.received - initialBytes) *
          1000 /
          max(1, watch.elapsedMilliseconds);
      job.notify();
    });
    try {
      await Future.wait(
        List.generate(min(settings.concurrency, unique.length), (_) async {
          while (index < unique.length && failure == null) {
            final item = unique[index++];
            try {
              job.check();
              await download(item, job);
              job.completedFiles++;
            } catch (e) {
              try {
                job.check();
                if (onFailure == null || !await onFailure(item, e)) {
                  failure ??= e;
                }
              } catch (terminal) {
                failure ??= terminal;
              }
            }
          }
        }),
      );
      if (failure != null) throw failure!;
    } finally {
      timer.cancel();
      _batchJobs.remove(job.id);
      job.bytesPerSecond = 0;
      job.notify();
    }
  }
}

Future<bool> validFile(DownloadFile item) async {
  final f = File(item.path);
  if (!await f.exists()) return false;
  final length = await f.length();
  if (item.size != null && item.size != length) return false;
  if (item.hash != null && item.hash!.isNotEmpty) {
    final result = await fileHash(f.path, item.algorithm);
    return result.toLowerCase() == item.hash!.toLowerCase();
  }
  return length > 0;
}

Future<String> fileHash(String file, String algorithm) async {
  if (await File(file).length() <= 512 * 1024) {
    return _hashStream(file, algorithm);
  }
  return Isolate.run(() => _hashStream(file, algorithm));
}

Future<String> _hashStream(String file, String algorithm) async {
  final hash = switch (algorithm) {
    'sha512' => sha512,
    'sha256' => sha256,
    'md5' => md5,
    _ => sha1,
  };
  return (await hash.bind(File(file).openRead()).first).toString();
}
