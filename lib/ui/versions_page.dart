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
  bool railCollapsed = false;
  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    final term = search.trim().toLowerCase();
    final rows = s.localVersions
        .where(
          (v) => '${v.id} ${v.game} ${v.label}'.toLowerCase().contains(term),
        )
        .toList();
    final current =
        rows.where((v) => v.id == selected).firstOrNull ?? rows.firstOrNull;
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          if (s.scanError != null) InfoStrip(s.scanError!, warning: true),
          if (s.scanning) const LinearProgressIndicator(),
          Expanded(
            child: s.localVersions.isEmpty
                ? EmptyState(
                    '还没有游戏版本',
                    '添加已有的 .minecraft 目录，或从下载页安装一个版本。',
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
                        width: railCollapsed ? 36 : 210,
                        child: railCollapsed
                            ? IconButton(
                                tooltip: '展开版本列表',
                                icon: const Icon(Icons.chevron_right),
                                onPressed: () =>
                                    setState(() => railCollapsed = false),
                              )
                            : Column(
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          '已安装版本 · ${s.localVersions.length}',
                                          style: Theme.of(
                                            context,
                                          ).textTheme.titleSmall,
                                        ),
                                      ),
                                      IconButton(
                                        tooltip: '恢复备份',
                                        onPressed: restore,
                                        icon: const Icon(
                                          Icons.restore,
                                          size: 18,
                                        ),
                                      ),
                                      IconButton(
                                        tooltip: '收起版本列表',
                                        onPressed: () => setState(
                                          () => railCollapsed = true,
                                        ),
                                        icon: const Icon(
                                          Icons.chevron_left,
                                          size: 18,
                                        ),
                                      ),
                                    ],
                                  ),
                                  TextField(
                                    key: const ValueKey('version-search'),
                                    decoration: const InputDecoration(
                                      prefixIcon: Icon(Icons.search, size: 18),
                                      hintText: '搜索版本 / 加载器',
                                    ),
                                    onChanged: (value) =>
                                        setState(() => search = value),
                                  ),
                                  const SizedBox(height: 8),
                                  Expanded(
                                    child: Card(
                                      child: rows.isEmpty
                                          ? const EmptyState(
                                              '没有匹配版本',
                                              '试试其他名称或加载器',
                                            )
                                          : ListView.separated(
                                              itemCount: rows.length,
                                              separatorBuilder: (_, _) =>
                                                  const Divider(height: 1),
                                              itemBuilder: (_, i) {
                                                final version = rows[i];
                                                return ListTile(
                                                  dense: true,
                                                  contentPadding:
                                                      const EdgeInsets.symmetric(
                                                        horizontal: 12,
                                                        vertical: 3,
                                                      ),
                                                  selected:
                                                      version.id == current?.id,
                                                  selectedTileColor:
                                                      Theme.of(context)
                                                          .colorScheme
                                                          .primary
                                                          .withValues(
                                                            alpha: .07,
                                                          ),
                                                  title: Tooltip(
                                                    message: version.id,
                                                    child: Text(
                                                      version.id,
                                                      maxLines: 1,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                      style: const TextStyle(
                                                        fontSize: 13,
                                                        fontWeight:
                                                            FontWeight.w600,
                                                      ),
                                                    ),
                                                  ),
                                                  subtitle: Text(
                                                    '${version.game} · ${version.label}',
                                                    maxLines: 2,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: const TextStyle(
                                                      fontSize: 11,
                                                    ),
                                                  ),
                                                  onTap: () => setState(
                                                    () => selected = version.id,
                                                  ),
                                                );
                                              },
                                            ),
                                    ),
                                  ),
                                  TextButton.icon(
                                    onPressed: s.scanning ? null : s.scan,
                                    icon: const Icon(Icons.refresh, size: 16),
                                    label: const Text('刷新版本'),
                                  ),
                                ],
                              ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: current == null
                            ? const EmptyState('没有匹配版本', '修改左侧关键词查看其他版本')
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
  int generation = 0;
  String status = 'all';
  String? loadError;
  final query = TextEditingController();
  static const categories = {
    'mods': 'Mod',
    'resourcepacks': '资源包',
    'shaderpacks': '光影',
    'saves': '世界',
    'config': '配置',
  };
  AppState get s => widget.state;
  LocalVersion get v => widget.version;
  bool get busy => s.jobs.any((j) => j.active && j.request['root'] == v.root);
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void didUpdateWidget(covariant VersionDetail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.version != widget.version) load();
  }

  @override
  void dispose() {
    generation++;
    query.dispose();
    super.dispose();
  }

  Future<void> load() async {
    final token = ++generation;
    final folder = category;
    setState(() {
      loading = true;
      loadError = null;
    });
    try {
      final rows = await s.contentFiles(v, folder);
      if (mounted && generation == token) setState(() => files = rows);
    } catch (e) {
      if (mounted && generation == token) {
        setState(() {
          files = [];
          loadError = '$e';
        });
      }
    } finally {
      if (mounted && generation == token) setState(() => loading = false);
    }
  }

  Future<void> repair() => action(context, () async {
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
  });
  Future<void> updates() => action(context, () async {
    if (await confirm(
      context,
      '更新已跟踪资源',
      '检查此工具安装的资源，并更新到当前游戏版本和加载器兼容的最新版本。旧文件会禁用并保留。',
    )) {
      s.enqueue('更新 ${v.id} 的资源', 'updates', {'root': v.root, 'target': v.id});
      widget.onTask();
    }
  });
  Future<void> importContent() => action(context, () async {
    final folder = category;
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: folder != 'saves',
      type: FileType.any,
    );
    if (result == null || !mounted) return;
    if (folder == 'saves') {
      final name = await input(
        context,
        '世界名称',
        value: p.basenameWithoutExtension(result.files.single.name),
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
      await s.importFiles(v, folder, result.paths.whereType<String>().toList());
      await load();
    }
  });
  Future<void> openContentFolder() => action(context, () async {
    final folder = safeChild(v.contentPath, category);
    await guardPath(v.contentPath, folder);
    await openFolder(folder);
  });

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
        case 'updates':
          await updates();
        case 'modify':
          if (['LiteLoader', 'LegacyFabric', 'Cleanroom'].contains(v.loader)) {
            throw StateError('可以管理本地内容，但暂不支持修改 ${v.loader} 组件');
          }
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
  Widget build(BuildContext context) {
    final term = query.text.trim().toLowerCase();
    final visible = files
        .where(
          (file) =>
              (file['name'] as String).toLowerCase().contains(term) &&
              (category != 'mods' ||
                  status == 'all' ||
                  (status == 'disabled') == file['disabled']),
        )
        .toList();
    final summary =
        'Minecraft ${v.game} · ${v.label} · ${v.contentPath == v.path ? '版本隔离' : '共享 / 自定义目录'}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Tooltip(
                        message: v.id,
                        child: Text(
                          v.id,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const SizedBox(height: 3),
                      Tooltip(
                        message: '$summary\n${v.contentPath}',
                        child: Text(
                          summary,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                ),
                TextButton.icon(
                  onPressed: busy ? null : repair,
                  icon: const Icon(Icons.build_outlined, size: 16),
                  label: const Text('补全文件'),
                ),
                TextButton.icon(
                  onPressed: () => widget.onBrowse(v, switch (category) {
                    'resourcepacks' => 'resourcepack',
                    'shaderpacks' => 'shader',
                    'saves' => 'world',
                    _ => 'mod',
                  }),
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('下载内容'),
                ),
                PopupMenuButton<String>(
                  tooltip: '版本操作',
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
                    PopupMenuItem(
                      value: 'modify',
                      enabled: !busy,
                      child: const Text('调整版本与组件'),
                    ),
                    PopupMenuItem(
                      value: 'updates',
                      enabled: !busy,
                      child: const Text('更新已跟踪资源'),
                    ),
                    PopupMenuItem(
                      value: 'copy',
                      enabled: !busy,
                      child: const Text('复制版本'),
                    ),
                    PopupMenuItem(
                      value: 'rename',
                      enabled: !busy,
                      child: const Text('重命名'),
                    ),
                    PopupMenuItem(
                      value: 'export',
                      enabled: !busy,
                      child: const Text('导出整合包'),
                    ),
                    PopupMenuItem(
                      value: 'delete',
                      enabled: !busy,
                      child: const Text('移除版本'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        if (v.error.isNotEmpty) InfoStrip(v.error, warning: true),
        if (!v.isolationKnown)
          InfoStrip(
            '内容目录根据文件推断，安装前请确认。',
            warning: true,
            action: PopupMenuButton<bool>(
              tooltip: '确认内容目录',
              onSelected: busy
                  ? null
                  : (isolate) => action(context, () async {
                      await GameRepository(v.root).setIsolation(v, isolate);
                      await s.scan();
                    }),
              itemBuilder: (_) => const [
                PopupMenuItem(value: true, child: Text('使用版本目录')),
                PopupMenuItem(value: false, child: Text('使用游戏根目录')),
              ],
            ),
          ),
        const SizedBox(height: 6),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final entry in categories.entries)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: TextButton(
                    style: TextButton.styleFrom(
                      backgroundColor: category == entry.key
                          ? Theme.of(
                              context,
                            ).colorScheme.primary.withValues(alpha: .1)
                          : null,
                      minimumSize: const Size(64, 36),
                    ),
                    onPressed: () {
                      if (category == entry.key) return;
                      setState(() {
                        category = entry.key;
                        status = 'all';
                        query.clear();
                      });
                      load();
                    },
                    child: Text(entry.value),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        LayoutBuilder(
          builder: (context, constraints) => Row(
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('content-search'),
                  controller: query,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 10,
                    ),
                    hintText: '搜索${categories[category]}文件名',
                    prefixIcon: const Icon(Icons.search, size: 18),
                    suffixIcon: query.text.isEmpty
                        ? null
                        : IconButton(
                            tooltip: '清空搜索',
                            icon: const Icon(Icons.close, size: 16),
                            onPressed: () => setState(query.clear),
                          ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              if (category == 'mods') ...[
                SizedBox(
                  width: 120,
                  child: DropdownButtonFormField<String>(
                    initialValue: status,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 10,
                      ),
                    ),
                    items: const [
                      DropdownMenuItem(value: 'all', child: Text('全部状态')),
                      DropdownMenuItem(value: 'enabled', child: Text('已启用')),
                      DropdownMenuItem(value: 'disabled', child: Text('已禁用')),
                    ],
                    onChanged: (value) {
                      if (value != null) setState(() => status = value);
                    },
                  ),
                ),
                const SizedBox(width: 8),
              ],
              Text(
                term.isEmpty && status == 'all'
                    ? '${files.length} 项'
                    : '${visible.length} / ${files.length}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(width: 4),
              if (constraints.maxWidth > 760)
                TextButton.icon(
                  onPressed: openContentFolder,
                  icon: const Icon(Icons.folder_open_outlined, size: 18),
                  label: Text('打开 ${categories[category]} 文件夹'),
                )
              else
                IconButton(
                  tooltip: '打开 ${categories[category]} 文件夹',
                  onPressed: openContentFolder,
                  icon: const Icon(Icons.folder_open_outlined, size: 18),
                ),
              IconButton(
                tooltip: '刷新内容',
                onPressed: loading ? null : load,
                icon: const Icon(Icons.refresh, size: 18),
              ),
              IconButton(
                tooltip: '导入${categories[category]}',
                onPressed: busy ? null : importContent,
                icon: const Icon(Icons.file_upload_outlined, size: 18),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: Card(
            key: const ValueKey('version-content-list'),
            child: loading
                ? const Center(child: CircularProgressIndicator())
                : loadError != null
                ? EmptyState(
                    '读取内容失败',
                    loadError!,
                    button: TextButton(
                      onPressed: load,
                      child: const Text('重试'),
                    ),
                  )
                : visible.isEmpty
                ? EmptyState(
                    files.isEmpty ? '这里还没有内容' : '没有匹配文件',
                    files.isEmpty
                        ? '下载内容或导入本地文件，也可以直接打开文件夹管理。'
                        : '试试其他文件名，或切换启用状态。',
                  )
                : ListView.separated(
                    itemCount: visible.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final file = visible[i];
                      return ListTile(
                        dense: true,
                        minTileHeight: 44,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                        ),
                        leading: Icon(
                          file['directory']
                              ? Icons.folder_outlined
                              : Icons.description_outlined,
                          size: 18,
                        ),
                        title: Row(
                          children: [
                            Expanded(
                              child: Tooltip(
                                message: file['name'],
                                child: Text(
                                  file['name'],
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: file['disabled']
                                        ? Theme.of(
                                            context,
                                          ).colorScheme.onSurfaceVariant
                                        : null,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              file['directory']
                                  ? '文件夹'
                                  : bytesLabel(file['size']),
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (category == 'mods' && !file['directory'])
                              Switch(
                                materialTapTargetSize:
                                    MaterialTapTargetSize.shrinkWrap,
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
                              visualDensity: VisualDensity.compact,
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
}
