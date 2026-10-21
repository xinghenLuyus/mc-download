import 'dart:async';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'models.dart';
import 'network.dart';
import 'repository.dart';

class ManualFilesRequired implements Exception {
  final int count;
  const ManualFilesRequired(this.count);
  @override
  String toString() => '还有 $count 个文件未能自动下载，可重试或手动补齐后继续。';
}

/// Finish the other files even when an individual remote file is unavailable.
/// Do not swallow cancellation, authentication failures, or local disk errors.
Future<void> downloadRecoverably(
  NetworkService network,
  List<DownloadFile> files,
  DownloadJob job,
  String root, {
  Map<String, String> websites = const {},
}) async {
  final missing = <Json>[];
  job.request.remove('missingFiles');
  await network.batch(
    files,
    job,
    onFailure: (file, error) async {
      if (error is CurseForgeAccessException && error.statusCode != 403) {
        return false;
      }
      if (error is! HttpException &&
          error is! SocketException &&
          error is! TimeoutException &&
          error is! CurseForgeAccessException) {
        return false;
      }
      final relative = p.relative(file.path, from: root);
      safeChild(root, relative);
      missing.add({
        'path': relative,
        'filename': p.basename(file.path),
        'hash': file.hash,
        'algorithm': file.algorithm,
        'size': file.size,
        'website': websites[file.path] ?? file.urls.firstOrNull,
        'error': '$error',
      });
      // Persist partial results too, so another failure cannot hide this list.
      job.request['missingFiles'] = List<Json>.of(missing);
      job.log('等待补齐：${p.basename(file.path)}');
      return true;
    },
  );
  if (missing.isNotEmpty) throw ManualFilesRequired(missing.length);
}

Future<int> importManualFiles(DownloadJob job, List<String> paths) async {
  if (job.active) throw StateError('请先暂停任务，再补齐文件');
  final root = job.request['root'] as String?;
  if (root == null) throw StateError('任务没有可补齐的游戏目录');
  final missing = asList(job.request['missingFiles']).map(asMap).toList();
  var imported = 0;
  for (final entry in missing.toList()) {
    final target = safeChild(root, entry['path']);
    final hash = entry['hash'] as String?;
    final size = (entry['size'] as num?)?.toInt();
    // Without a hash, accept only an exact filename and known length.
    if ((hash == null || hash.isEmpty) && (size == null || size <= 0)) continue;
    for (final source in paths) {
      if ((hash == null || hash.isEmpty) &&
          p.basename(source) != entry['filename']) {
        continue;
      }
      final descriptor = DownloadFile(
        source,
        [],
        hash: hash,
        algorithm: entry['algorithm'] ?? 'sha1',
        size: size,
      );
      if (!await validFile(descriptor)) continue;
      await guardPath(root, target);
      if (!p.equals(p.absolute(source), p.absolute(target))) {
        final temporary = '$target.manual-part';
        await guardPath(root, temporary);
        await Directory(p.dirname(target)).create(recursive: true);
        try {
          await File(source).copy(temporary);
          if (!await validFile(
            DownloadFile(
              temporary,
              [],
              hash: hash,
              algorithm: descriptor.algorithm,
              size: size,
            ),
          )) {
            throw StateError('复制后校验失败：${entry['filename']}');
          }
          if (await File(target).exists()) await File(target).delete();
          await File(temporary).rename(target);
        } finally {
          if (await File(temporary).exists()) await File(temporary).delete();
        }
      }
      missing.remove(entry);
      imported++;
      break;
    }
  }
  job.request['missingFiles'] = missing;
  job.stage = missing.isEmpty ? '文件已补齐，可继续安装' : '等待手动补齐 ${missing.length} 个文件';
  job.error = missing.isEmpty ? '' : '还有 ${missing.length} 个文件需要补齐或重试';
  job.log('已校验并补齐 $imported 个文件，剩余 ${missing.length} 个');
  return imported;
}
