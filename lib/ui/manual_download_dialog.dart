import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../app_state.dart';
import '../core/models.dart';
import '../core/manual_downloads.dart';
import 'common.dart';

Future<void> showManualDownloads(
  BuildContext context,
  AppState state,
  DownloadJob job,
) async {
  var busy = false;
  String? result;
  await showDialog<void>(
    context: context,
    builder: (dialog) => StatefulBuilder(
      builder: (context, update) {
        final files = asList(job.request['missingFiles']).map(asMap).toList();
        return AlertDialog(
          title: Text('补齐下载文件 · 剩余 ${files.length} 个'),
          content: SizedBox(
            width: 720,
            height: 400,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  '从对应版本的官网页面下载，再选择文件导入。通过哈希或文件名与大小校验后才能继续；已完成的下载会保留。',
                  style: TextStyle(fontSize: 12),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: busy
                      ? null
                      : () async {
                          update(() {
                            busy = true;
                            result = null;
                          });
                          try {
                            final picked = await FilePicker.platform.pickFiles(
                              allowMultiple: true,
                              dialogTitle: '选择已下载的缺失文件',
                            );
                            if (picked != null) {
                              if (job.active || state.runningId == job.id) {
                                throw StateError('任务正在运行或停止连接，请稍后再导入');
                              }
                              final count = await importManualFiles(
                                job,
                                picked.paths.whereType<String>().toList(),
                              );
                              await state.save();
                              result = count == 0
                                  ? '没有匹配的文件。请检查版本、哈希和文件大小；缺少校验信息的文件无法自动确认。'
                                  : '已校验并补齐 $count 个文件。';
                            }
                          } catch (e) {
                            result = '$e';
                          } finally {
                            if (context.mounted) update(() => busy = false);
                          }
                        },
                  icon: const Icon(Icons.file_open_outlined, size: 18),
                  label: const Text('选择已下载文件'),
                ),
                if (busy) const LinearProgressIndicator(),
                if (result != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(result!, style: const TextStyle(fontSize: 12)),
                  ),
                Expanded(
                  child: ListView.builder(
                    itemCount: files.length,
                    itemBuilder: (_, index) {
                      final file = files[index];
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: SelectableText(
                          '${file['filename']}',
                          style: const TextStyle(fontSize: 13),
                        ),
                        subtitle: Text(
                          file['hash'] == null
                              ? '未提供哈希，需匹配文件名与大小'
                              : '${file['algorithm']}: ${file['hash']}',
                          style: const TextStyle(fontSize: 11),
                        ),
                        trailing: file['website'] == null
                            ? null
                            : TextButton(
                                onPressed: busy
                                    ? null
                                    : () => action(
                                        context,
                                        () => openWeb(file['website']),
                                      ),
                                child: const Text('打开下载页面'),
                              ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: busy ? null : () => Navigator.pop(dialog),
              child: const Text('关闭'),
            ),
            FilledButton(
              onPressed: busy || job.active || state.runningId == job.id
                  ? null
                  : () {
                      Navigator.pop(dialog);
                      action(context, () async => state.retry(job));
                    },
              child: Text(files.isEmpty ? '继续安装' : '重新尝试自动下载'),
            ),
          ],
        );
      },
    ),
  );
}
