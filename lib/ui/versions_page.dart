import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import '../app_state.dart';
import '../core/models.dart';
import '../core/repository.dart';
import 'common.dart';
import 'download_page.dart';

class VersionsPage extends StatefulWidget {
  final AppState state;
  final void Function(LocalVersion, String) onBrowse;
  final VoidCallback onTask;
  const VersionsPage({
    super.key,
    required this.state,
    required this.onBrowse,
    required this.onTask,
  });
  @override
  State<VersionsPage> createState() => _VersionsPageState();
}

class _VersionsPageState extends State<VersionsPage> {
  String search = '';
  String? selected;
  Future<void> restore() => action(context, () async {
    final root = widget.state.requireRoot();
    if (widget.state.jobs.any((j) => j.active && j.request['root'] == root)) {
      throw StateError('请先暂停此游戏目录的任务');
    }
    final repo = GameRepository(root);
    final backups = await repo.backups();
    if (!mounted) return;
    if (backups.isEmpty) throw StateError('此目录没有可恢复的版本备份');
    final backup = await showDialog<Json>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('选择版本备份'),
        children: [
          for (final row in backups)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, row),
              child: Text('${row['id']}\n${row['date']}'),
            ),
        ],
      ),
    );
    if (backup == null || !mounted) return;
    final name = await input(
      context,
      '恢复版本名称',
      value: '${backup['id']}-恢复',
      note: '复制备份为新版本，原备份保留，不覆盖已有版本。',
    );
    if (name == null) return;
    await repo.restoreBackup(backup['path'], name);
    await widget.state.scan();
    if (mounted) setState(() => selected = name);
  });
  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    final rows = s.localVersions
        .where((v) => v.id.toLowerCase().contains(search.toLowerCase()))
        .toList();
    final current = s.localVersions.where((v) => v.id == selected).firstOrNull;
    return Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        children: [
          SectionHeading(
            '版本管理',
            '管理已有游戏文件，补全依赖，安装或更新本地内容。',
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton.icon(
                  onPressed: restore,
                  icon: const Icon(Icons.restore, size: 18),
                  label: const Text('恢复备份'),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: s.scanning ? null : s.scan,
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('刷新'),
                ),
              ],
            ),
          ),
          if (s.scanError != null) InfoStrip(s.scanError!, warning: true),
          Expanded(
            child: rows.isEmpty && s.localVersions.isEmpty
                ? EmptyState(
                    '还没有游戏版本',
                    '添加已有的 .minecraft 目录，或从下载页安装一个版本。',
                    icon: Icons.folder_copy_outlined,
                    button: OutlinedButton.icon(
                      onPressed: () => addRoot(context, s),
                      icon: const Icon(Icons.add),
                      label: const Text('添加游戏目录'),
                    ),
                  )
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 265,
                        child: Column(
                          children: [
                            TextField(
                              decoration: const InputDecoration(
                                prefixIcon: Icon(Icons.search, size: 18),
                                hintText: '搜索已安装版本',
                              ),
                              onChanged: (v) => setState(() => search = v),
                            ),
                            const SizedBox(height: 14),
                            Expanded(
                              child: Card(
                                child: ListView.separated(
                                  itemCount: rows.length,
                                  separatorBuilder: (_, _) =>
                                      const Divider(height: 1),
                                  itemBuilder: (_, i) {
                                    final v = rows[i];
                                    return ListTile(
                                      selected: v.id == selected,
                                      selectedTileColor: Theme.of(context)
                                          .colorScheme
                                          .primary
                                          .withValues(alpha: .07),
                                      leading: Icon(
                                        v.loader.isEmpty
                                            ? Icons.grass_outlined
                                            : Icons.extension_outlined,
                                        size: 22,
                                      ),
                                      title: Text(
                                        v.id,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      subtitle: Text(
                                        '${v.game} · ${v.label}',
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(fontSize: 10),
                                      ),
                                      onTap: () =>
                                          setState(() => selected = v.id),
                                    );
                                  },
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 20),
                      Expanded(
                        child: current == null
                            ? const EmptyState('选择一个版本', '在左侧查看版本详情和本地内容')
                            : VersionDetail(
                                key: ValueKey(
                                  '${current.root}:${current.id}:${current.contentPath}',
                                ),
                                state: s,
                                version: current,
                                onBrowse: widget.onBrowse,
                                onTask: widget.onTask,
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

class VersionDetail extends StatefulWidget {
  final AppState state;
  final LocalVersion version;
  final void Function(LocalVersion, String) onBrowse;
  final VoidCallback onTask;
  const VersionDetail({
    super.key,
    required this.state,
    required this.version,
    required this.onBrowse,
    required this.onTask,
  });
  @override
  State<VersionDetail> createState() => _VersionDetailState();
}

class _VersionDetailState extends State<VersionDetail> {
  String category = 'mods';
  List<Json> files = [];
  bool loading = false;
  AppState get s => widget.state;
  LocalVersion get v => widget.version;
  bool get busy => s.jobs.any((j) => j.active && j.request['root'] == v.root);
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    setState(() => loading = true);
    try {
      final rows = await s.contentFiles(v, category);
      if (mounted) setState(() => files = rows);
    } catch (e) {
      if (mounted) message(context, e, error: true);
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> renameOrCopy(bool rename) async {
    final name = await input(
      context,
      rename ? '重命名版本' : '复制版本',
      value: '${v.id}${rename ? '' : '-副本'}',
      note: '复制当前版本目录内容；共享的资源和支持库继续复用。',
    );
    if (name == null) return;
    if (!mounted) return;
    await action(context, () async {
      await GameRepository(v.root).copyVersion(v, name, rename: rename);
      await s.scan();
    });
  }

  Future<void> menu(String value) async {
    await action(context, () async {
      if (busy && !['open', 'content', 'json'].contains(value)) {
        throw StateError('此游戏目录有正在进行的任务，请先暂停任务');
      }
      switch (value) {
        case 'modify':
          if (v.contentPath != v.path && v.contentPath != v.root) {
            throw StateError('此版本使用外部自定义内容目录，请先复制为标准版本再修改');
          }
          if (!mounted) return;
          final queued = await showDialog<bool>(
            context: context,
            builder: (_) => InstallDialog(state: s, game: v.game, existing: v),
          );
          if (queued == true) widget.onTask();
        case 'open':
          await openFolder(v.path);
        case 'content':
          await openFolder(v.contentPath);
        case 'json':
          if (mounted) {
            await showLog(context, '版本元数据', pretty(v.manifest).split('\n'));
          }
        case 'copy':
          await renameOrCopy(false);
        case 'rename':
          await renameOrCopy(true);
        case 'delete':
          if (!mounted ||
              !await confirm(
                context,
                '移除版本 ${v.id}',
                '版本目录会移到游戏目录下的 .mcd-trash，包含该版本的独立存档。共享资源和支持库保留，可从备份目录恢复。',
              )) {
            return;
          }
          await GameRepository(v.root).deleteVersion(v.id);
          await s.scan();
        case 'export':
          final path = await FilePicker.platform.saveFile(
            fileName: '${v.id}.mrpack',
            dialogTitle: '导出整合包',
          );
          if (path == null) return;
          s.enqueue('导出 ${v.id}', 'export', {
            'root': v.root,
            'target': v.id,
            'path': path,
          });
          widget.onTask();
      }
    });
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      v.id,
                      style: const TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  PopupMenuButton<String>(
                    onSelected: menu,
                    itemBuilder: (_) => [
                      const PopupMenuItem(value: 'open', child: Text('打开版本目录')),
                      const PopupMenuItem(
                        value: 'content',
                        child: Text('打开内容目录'),
                      ),
                      const PopupMenuItem(
                        value: 'json',
                        child: Text('查看版本 JSON'),
                      ),
                      const PopupMenuItem(
                        value: 'modify',
                        child: Text('调整版本与组件'),
                      ),
                      const PopupMenuItem(value: 'copy', child: Text('复制版本')),
                      const PopupMenuItem(value: 'rename', child: Text('重命名')),
                      const PopupMenuItem(
                        value: 'export',
                        child: Text('导出整合包'),
                      ),
                      const PopupMenuItem(value: 'delete', child: Text('移除版本')),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  smallChip(context, 'Minecraft ${v.game}'),
                  smallChip(context, v.label),
                  smallChip(
                    context,
                    v.contentPath == v.path ? '版本隔离' : '共享 / 自定义内容目录',
                  ),
                ],
              ),
              const SizedBox(height: 14),
              if (v.error.isNotEmpty) InfoStrip(v.error, warning: true),
              SelectableText(
                v.contentPath,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: busy
                        ? null
                        : () => action(context, () async {
                            String? game;
                            if (!s.remoteVersions.any((e) => e.id == v.game)) {
                              game = await input(
                                context,
                                '确认原版 Minecraft 版本',
                                value: v.game,
                                note: '例如 1.20.1。损坏的描述文件可能无法识别版本，请按原来的版本填写。',
                              );
                              if (game == null) return;
                              validateId(game);
                            }
                            s.enqueue('补全 ${v.id}', 'repair', {
                              'root': v.root,
                              'target': v.id,
                              'game': ?game,
                            });
                            widget.onTask();
                          }),
                    icon: const Icon(Icons.build_outlined, size: 16),
                    label: const Text('补全文件'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => widget.onBrowse(v, 'mod'),
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text('下载内容'),
                  ),
                  OutlinedButton(
                    onPressed: busy ? null : () => menu('modify'),
                    child: const Text('调整组件'),
                  ),
                  OutlinedButton(
                    onPressed: busy
                        ? null
                        : () => action(context, () async {
                            if (await confirm(
                              context,
                              '更新已跟踪资源',
                              '检查此工具安装的资源，并更新到当前游戏版本和加载器兼容的最新版本。旧文件会禁用并保留。',
                            )) {
                              s.enqueue('更新 ${v.id} 的资源', 'updates', {
                                'root': v.root,
                                'target': v.id,
                              });
                              widget.onTask();
                            }
                          }),
                    child: const Text('更新资源'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 12),
      if (!v.isolationKnown)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: InfoStrip(
            '此版本的内容目录根据文件推断。安装内容前可确认目录：',
            warning: true,
            action: PopupMenuButton<bool>(
              tooltip: '确认内容目录',
              onSelected: busy
                  ? null
                  : (isolate) => action(context, () async {
                      await GameRepository(v.root).setIsolation(v, isolate);
                      await s.scan();
                    }),
              itemBuilder: (_) => [
                const PopupMenuItem(value: true, child: Text('使用版本目录')),
                const PopupMenuItem(value: false, child: Text('使用游戏根目录')),
              ],
            ),
          ),
        ),
      Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          for (final (key, title) in [
            ('mods', 'Mod'),
            ('resourcepacks', '资源包'),
            ('shaderpacks', '光影'),
            ('saves', '世界'),
            ('config', '配置'),
          ])
            ChoiceChip(
              label: Text(title),
              selected: category == key,
              onSelected: (_) {
                setState(() => category = key);
                load();
              },
            ),
        ],
      ),
      const SizedBox(height: 12),
      Row(
        children: [
          Text(
            '${files.length} 项',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const Spacer(),
          IconButton(
            tooltip: '刷新内容',
            onPressed: load,
            icon: const Icon(Icons.refresh, size: 18),
          ),
          TextButton.icon(
            onPressed: busy
                ? null
                : () => action(context, () async {
                    final result = await FilePicker.platform.pickFiles(
                      allowMultiple: category != 'saves',
                      type: FileType.any,
                    );
                    if (result == null) return;
                    if (category == 'saves') {
                      if (!context.mounted) return;
                      final name = await input(
                        context,
                        '世界名称',
                        value: p.basenameWithoutExtension(
                          result.files.single.name,
                        ),
                      );
                      if (name == null) return;
                      validateId(name);
                      s.enqueue('导入世界 $name', 'world', {
                        'root': v.root,
                        'target': v.id,
                        'file': result.files.single.path,
                        'name': name,
                      });
                      widget.onTask();
                    } else {
                      await s.importFiles(
                        v,
                        category,
                        result.paths.whereType<String>().toList(),
                      );
                      await load();
                    }
                  }),
            icon: const Icon(Icons.file_upload_outlined, size: 16),
            label: const Text('导入'),
          ),
        ],
      ),
      Expanded(
        child: loading
            ? const Center(child: CircularProgressIndicator())
            : files.isEmpty
            ? const EmptyState('这里还没有内容', '从下载页安装，或导入本地文件。')
            : Card(
                child: ListView.separated(
                  itemCount: files.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final file = files[i];
                    return ListTile(
                      dense: true,
                      leading: Icon(
                        file['directory']
                            ? Icons.folder_outlined
                            : Icons.description_outlined,
                        size: 20,
                      ),
                      title: Text(
                        file['name'],
                        style: TextStyle(
                          fontSize: 12,
                          color: file['disabled']
                              ? Theme.of(context).colorScheme.onSurfaceVariant
                              : null,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        file['directory'] ? '文件夹' : bytesLabel(file['size']),
                        style: const TextStyle(fontSize: 10),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (category == 'mods' && !file['directory'])
                            Switch(
                              value: !file['disabled'],
                              onChanged: busy
                                  ? null
                                  : (_) => action(context, () async {
                                      await s.toggleFile(v, file['path']);
                                      await load();
                                    }),
                            ),
                          IconButton(
                            tooltip: '移到备份目录',
                            onPressed: busy
                                ? null
                                : () => action(context, () async {
                                    if (await confirm(
                                      context,
                                      '移除本地内容',
                                      '将 ${file['name']} 移到内容目录内的 .mcd-trash，可手动恢复。',
                                    )) {
                                      await s.trashContent(v, file['path']);
                                      await load();
                                    }
                                  }),
                            icon: const Icon(Icons.delete_outline, size: 18),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
      ),
    ],
  );
}
