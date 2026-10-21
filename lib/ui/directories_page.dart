import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../app_state.dart';
import 'common.dart';
import 'directory_dialog.dart';

class DirectoriesPage extends StatelessWidget {
  final AppState state;
  final VoidCallback onInstall;
  const DirectoriesPage({
    super.key,
    required this.state,
    required this.onInstall,
  });

  Future<void> create(BuildContext context) => showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (_) => NewGameDirectoryDialog(
      state: state,
      initialParent: p.dirname(state.dataPath),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final root = state.settings.selectedRoot;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeading(
            '游戏目录',
            '每个目录独立管理版本和文件，空目录也可以直接添加。',
            compact: true,
            trailing: Wrap(
              spacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: () => addRoot(context, state),
                  icon: const Icon(Icons.folder_open, size: 18),
                  label: const Text('添加已有目录'),
                ),
                FilledButton.icon(
                  onPressed: () => create(context),
                  icon: const Icon(Icons.create_new_folder_outlined, size: 18),
                  label: const Text('新建空目录'),
                ),
              ],
            ),
          ),
          Expanded(
            child: root == null
                ? EmptyState(
                    '先准备一个游戏目录',
                    '可以新建 .minecraft，或添加启动器正在使用的目录。无需预先安装游戏。',
                    button: FilledButton(
                      onPressed: () => create(context),
                      child: const Text('新建空目录'),
                    ),
                  )
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(
                        width: 250,
                        child: Card(
                          child: ListView(
                            padding: const EdgeInsets.all(6),
                            children: [
                              for (final path in state.settings.roots)
                                ListTile(
                                  selected: path == root,
                                  selectedTileColor: Theme.of(
                                    context,
                                  ).colorScheme.primary.withValues(alpha: .08),
                                  leading: const Icon(
                                    Icons.folder_outlined,
                                    size: 20,
                                  ),
                                  title: Text(
                                    p.basename(path),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  subtitle: Text(
                                    path,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 11),
                                  ),
                                  onTap: () => action(
                                    context,
                                    () => state.selectRoot(path),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _DirectoryDetails(
                          key: ValueKey(root),
                          state: state,
                          root: root,
                          onInstall: onInstall,
                        ),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _DirectoryDetails extends StatefulWidget {
  final AppState state;
  final String root;
  final VoidCallback onInstall;
  const _DirectoryDetails({
    super.key,
    required this.state,
    required this.root,
    required this.onInstall,
  });
  @override
  State<_DirectoryDetails> createState() => _DirectoryDetailsState();
}

class _DirectoryDetailsState extends State<_DirectoryDetails> {
  late Future<bool> exists = Directory(widget.root).exists();
  Future<void> refresh() async {
    setState(() => exists = Directory(widget.root).exists());
    await widget.state.scan();
  }

  Future<void> remove() async {
    if (!await confirm(
      context,
      '移除目录记录？',
      '仅从 MC Download 中取消关联，目录内的游戏、模组和存档都会保留。',
    )) {
      return;
    }
    if (mounted) {
      await action(context, () => widget.state.removeRoot(widget.root));
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    final root = widget.root;
    final isolated = s.settings.isolationFor(root);
    final mode = s.settings.rootIsolation[root];
    return Card(
      child: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          Text(p.basename(root), style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          SelectableText(root, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 12),
          FutureBuilder<bool>(
            future: exists,
            builder: (_, snapshot) => InfoStrip(
              snapshot.hasError
                  ? '无法读取目录：${snapshot.error}'
                  : !snapshot.hasData
                  ? '正在检查目录…'
                  : !snapshot.data!
                  ? '此目录已不存在或无法访问，请重新选择目录。'
                  : s.scanning
                  ? '正在扫描已安装版本…'
                  : s.scanError != null
                  ? '扫描失败：${s.scanError}'
                  : s.localVersions.isEmpty
                  ? '目录已就绪，尚未安装游戏。可以直接安装第一个版本。'
                  : '已安装 ${s.localVersions.length} 个版本，可切换到版本管理查看。',
              warning:
                  snapshot.hasError ||
                  snapshot.data == false ||
                  s.scanError != null,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: widget.onInstall,
                icon: const Icon(Icons.download_outlined, size: 18),
                label: const Text('安装游戏'),
              ),
              OutlinedButton.icon(
                onPressed: () => action(context, () => openFolder(root)),
                icon: const Icon(Icons.folder_open, size: 18),
                label: const Text('打开目录'),
              ),
              TextButton.icon(
                onPressed: () => action(context, refresh),
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('刷新'),
              ),
              TextButton.icon(
                onPressed: remove,
                icon: const Icon(Icons.link_off, size: 18),
                label: const Text('移除记录'),
              ),
            ],
          ),
          const Divider(height: 32),
          Text('新版本的默认隔离方式', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            key: ValueKey('$root:$mode:${s.settings.isolate}'),
            initialValue: mode == null
                ? 'global'
                : mode
                ? 'isolated'
                : 'shared',
            decoration: const InputDecoration(labelText: '此目录的安装默认值'),
            items: [
              DropdownMenuItem(
                value: 'global',
                child: Text('跟随全局（${s.settings.isolate ? '版本隔离' : '共享目录'}）'),
              ),
              const DropdownMenuItem(value: 'isolated', child: Text('版本隔离')),
              const DropdownMenuItem(value: 'shared', child: Text('共享目录')),
            ],
            onChanged: (value) => action(
              context,
              () => s.setRootIsolation(
                root,
                value == 'global' ? null : value == 'isolated',
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            isolated
                ? '模组、资源包、配置和存档放在 versions/<版本名>/ 下，各版本互不干扰。'
                : '模组、资源包、配置和存档放在游戏根目录下，由使用共享目录的版本共用。',
            style: const TextStyle(fontSize: 12, height: 1.7),
          ),
          const SizedBox(height: 10),
          const Text(
            '仅作为新安装版本的默认值，安装时仍可更改。已有版本在版本管理中单独调整；整合包始终使用版本隔离。',
            style: TextStyle(fontSize: 12, height: 1.7),
          ),
        ],
      ),
    );
  }
}
