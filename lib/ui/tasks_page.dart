import 'package:flutter/material.dart';
import '../app_state.dart';
import '../core/models.dart';
import 'common.dart';
import 'manual_download_dialog.dart';

class TasksPage extends StatelessWidget {
  final AppState state;
  const TasksPage({super.key, required this.state});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(28),
    child: Column(
      children: [
        SectionHeading(
          '下载任务',
          '查看进度、实际下载地址与日志。暂停后会保留已校验文件和续传缓存。',
          trailing: TextButton(
            onPressed: () {
              state.jobs.removeWhere(
                (j) =>
                    j.status == JobStatus.completed ||
                    j.status == JobStatus.cancelled,
              );
              state.changed();
            },
            child: const Text('清除已结束记录'),
          ),
        ),
        Expanded(
          child: state.jobs.isEmpty
              ? const EmptyState(
                  '暂无下载任务',
                  '选择一个游戏版本或社区资源开始下载。',
                  icon: Icons.cloud_download_outlined,
                )
              : ListView.separated(
                  itemCount: state.jobs.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 14),
                  itemBuilder: (context, i) {
                    final job = state.jobs[i];
                    final names = {
                      JobStatus.queued: '排队中',
                      JobStatus.running: '进行中',
                      JobStatus.paused: '已暂停',
                      JobStatus.completed: '已完成',
                      JobStatus.failed: '失败',
                      JobStatus.cancelled: '已取消',
                    };
                    return Card(
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(
                                  job.status == JobStatus.completed
                                      ? Icons.check_circle_outline
                                      : job.status == JobStatus.failed
                                      ? Icons.error_outline
                                      : Icons.downloading_outlined,
                                  color: job.status == JobStatus.failed
                                      ? Theme.of(context).colorScheme.error
                                      : Theme.of(context).colorScheme.primary,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    job.title,
                                    style: const TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                smallChip(context, names[job.status]!),
                                const SizedBox(width: 10),
                                if (job.active) ...[
                                  IconButton(
                                    tooltip: '暂停',
                                    onPressed: () => job.stop(pause: true),
                                    icon: const Icon(Icons.pause, size: 20),
                                  ),
                                  IconButton(
                                    tooltip: '取消',
                                    onPressed: () => job.stop(),
                                    icon: const Icon(Icons.close, size: 20),
                                  ),
                                ] else if (job.status != JobStatus.completed)
                                  TextButton(
                                    onPressed: state.runningId == job.id
                                        ? null
                                        : () => action(
                                            context,
                                            () async => state.retry(job),
                                          ),
                                    child: const Text('继续 / 重试'),
                                  ),
                                if (!job.active &&
                                    asList(
                                      job.request['missingFiles'],
                                    ).isNotEmpty)
                                  TextButton(
                                    onPressed: () => showManualDownloads(
                                      context,
                                      state,
                                      job,
                                    ),
                                    child: const Text('补齐文件'),
                                  ),
                                IconButton(
                                  tooltip: '查看日志',
                                  onPressed: () =>
                                      showLog(context, job.title, job.logs),
                                  icon: const Icon(
                                    Icons.article_outlined,
                                    size: 20,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 16),
                            if (job.status == JobStatus.running)
                              LinearProgressIndicator(
                                value: job.progress,
                                minHeight: 5,
                                borderRadius: BorderRadius.circular(4),
                              ),
                            const SizedBox(height: 10),
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    job.stage,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodySmall,
                                  ),
                                ),
                                if (job.totalFiles > 0)
                                  Text(
                                    job.currentFileSize == null
                                        ? '${job.completedFiles} / ${job.totalFiles}'
                                        : '${bytesLabel(job.currentFileReceived)} / ${bytesLabel(job.currentFileSize!)}',
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodySmall,
                                  ),
                                const SizedBox(width: 18),
                                if (job.bytesPerSecond > 0)
                                  Text(
                                    '${bytesLabel(job.bytesPerSecond)}/s',
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodySmall,
                                  ),
                              ],
                            ),
                            if (job.currentUrl.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 12),
                                child: SelectableText(
                                  job.currentUrl,
                                  style: TextStyle(
                                    fontFamily: 'Consolas',
                                    fontSize: 11,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            if (job.error.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 12),
                                child: InfoStrip(job.error, warning: true),
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    ),
  );
}
