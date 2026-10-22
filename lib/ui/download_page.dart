import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../app_state.dart';
import '../core/models.dart';
import '../core/repository.dart';
import '../core/network.dart';
import 'common.dart';
import '../core/version_metadata.dart';
import 'import_flow.dart';

class DownloadPage extends StatelessWidget {
  final AppState state;
  final String category;
  final String? targetId;
  final VoidCallback onTask;
  final VoidCallback? onSettings;
  const DownloadPage({
    super.key,
    required this.state,
    required this.category,
    this.targetId,
    required this.onTask,
    this.onSettings,
  });
  @override
  Widget build(BuildContext context) => category == 'game'
      ? GameDownloadView(state: state, onTask: onTask)
      : ResourceBrowser(
          key: ValueKey('$category:${state.settings.selectedRoot}:$targetId'),
          state: state,
          kind: category,
          initialTarget: targetId,
          onTask: onTask,
          onSettings: onSettings,
        );
}

class GameDownloadView extends StatefulWidget {
  final AppState state;
  final VoidCallback onTask;
  const GameDownloadView({
    super.key,
    required this.state,
    required this.onTask,
  });
  @override
  State<GameDownloadView> createState() => _GameDownloadViewState();
}

class _GameDownloadViewState extends State<GameDownloadView> {
  String query = '', type = 'release';
  Future<void> saveGame(String version, bool server) async {
    await action(context, () async {
      final path = await FilePicker.platform.saveFile(
        fileName: '${server ? 'server' : 'minecraft'}-$version.jar',
        dialogTitle: '保存游戏文件',
      );
      if (path == null) return;
      widget.state.enqueue(
        '下载 $version ${server ? '服务端' : '客户端'}',
        'saveGame',
        {'game': version, 'server': server, 'path': path},
      );
      widget.onTask();
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    final rows = s.remoteVersions
        .where(
          (v) =>
              (type == 'all' ||
                  (type == 'old'
                      ? v.type.startsWith('old_')
                      : v.type == type)) &&
              v.id.toLowerCase().contains(query.toLowerCase()),
        )
        .toList();
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeading(
            '下载 Minecraft',
            compact: true,
            '选择游戏版本，再按需安装加载器和组件。',
            trailing: IconButton(
              tooltip: '刷新版本列表',
              onPressed: s.loadingVersions ? null : s.loadVersions,
              icon: const Icon(Icons.refresh),
            ),
          ),
          const InfoStrip('所有游戏文件直接安装到当前游戏目录，可交给 PCL、HMCL 等启动器使用。'),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search, size: 20),
                    hintText: '搜索版本，例如 1.21.1',
                  ),
                  onChanged: (v) => setState(() => query = v),
                ),
              ),
              const SizedBox(width: 16),
              SegmentedButton<String>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: 'release', label: Text('正式版')),
                  ButtonSegment(value: 'snapshot', label: Text('快照')),
                  ButtonSegment(value: 'old', label: Text('远古版')),
                  ButtonSegment(value: 'all', label: Text('全部')),
                ],
                selected: {type},
                onSelectionChanged: (v) => setState(() => type = v.first),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Text('可用版本', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(width: 10),
              smallChip(context, '${rows.length}'),
              const Spacer(),
              Text(
                s.settings.sourceMode == SourceMode.official
                    ? '版本列表：Mojang 官方优先'
                    : '版本列表：已配置镜像优先',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (s.versionsError != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: InfoStrip(
                '获取最新列表失败：${s.versionsError}${s.remoteVersions.isNotEmpty ? '。正在显示本地缓存。' : ''}',
                warning: true,
              ),
            ),
          Expanded(
            child: s.loadingVersions && rows.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : rows.isEmpty
                ? EmptyState(
                    '暂无版本',
                    s.versionsError == null
                        ? '调整筛选条件或刷新版本列表'
                        : '检查网络、代理或下载源后重试',
                    button: OutlinedButton(
                      onPressed: s.loadVersions,
                      child: const Text('重新获取'),
                    ),
                  )
                : Card(
                    key: const ValueKey('resource-results'),
                    child: ListView.separated(
                      itemCount: rows.length,
                      separatorBuilder: (_, _) =>
                          const Divider(height: 1, indent: 68),
                      itemBuilder: (context, i) {
                        final v = rows[i];
                        return ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 8,
                          ),
                          leading: Container(
                            width: 36,
                            height: 36,
                            decoration: BoxDecoration(
                              color: Theme.of(
                                context,
                              ).colorScheme.primary.withValues(alpha: .07),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Icon(
                              v.type == 'release'
                                  ? Icons.grass_outlined
                                  : Icons.science_outlined,
                              size: 22,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ),
                          title: Text(
                            v.id,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          subtitle: Padding(
                            padding: const EdgeInsets.only(top: 5),
                            child: Text(
                              '${v.type == 'release'
                                  ? '正式版'
                                  : v.type == 'snapshot'
                                  ? '快照版'
                                  : '远古版'}  ·  ${v.released.split('T').first}',
                              style: const TextStyle(fontSize: 11),
                            ),
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              OutlinedButton(
                                onPressed: () => showInstall(
                                  context,
                                  s,
                                  v.id,
                                  widget.onTask,
                                ),
                                child: const Text('安装'),
                              ),
                              PopupMenuButton<bool>(
                                tooltip: '保存游戏文件',
                                onSelected: (server) => saveGame(v.id, server),
                                itemBuilder: (_) => [
                                  const PopupMenuItem(
                                    value: false,
                                    child: Text('保存客户端 JAR'),
                                  ),
                                  const PopupMenuItem(
                                    value: true,
                                    child: Text('保存服务端 JAR'),
                                  ),
                                ],
                              ),
                            ],
                          ),
                          onTap: () =>
                              showInstall(context, s, v.id, widget.onTask),
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

Future<void> showInstall(
  BuildContext context,
  AppState state,
  String game,
  VoidCallback onTask,
) async {
  if (state.settings.selectedRoot == null) {
    await addRoot(context, state);
    if (!context.mounted || state.settings.selectedRoot == null) return;
  }
  final queued = await showDialog<bool>(
    context: context,
    builder: (_) => InstallDialog(state: state, game: game),
  );
  if (queued == true) onTask();
}

class InstallDialog extends StatefulWidget {
  final AppState state;
  final String game;
  final LocalVersion? existing;
  const InstallDialog({
    super.key,
    required this.state,
    required this.game,
    this.existing,
  });
  @override
  State<InstallDialog> createState() => _InstallDialogState();
}

class _InstallDialogState extends State<InstallDialog> {
  late String game = widget.game;
  late final TextEditingController name = TextEditingController(
    text: widget.existing?.id ?? game,
  );
  late bool isolate = widget.existing == null
      ? widget.state.settings.isolationFor(widget.state.requireRoot())
      : widget.existing!.contentPath == widget.existing!.path;
  String loader = '', selected = '';
  List<Json> loaders = [];
  bool loading = false;
  String? error;
  int generation = 0;
  @override
  void initState() {
    super.initState();
    final old = widget.existing;
    if (old != null && old.loader.isNotEmpty) selectLoader(old.loader);
  }

  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  Future<void> selectLoader(String value) async {
    final token = ++generation;
    setState(() {
      loader = value;
      loaders = [];
      selected = '';
      error = null;
      loading = value.isNotEmpty;
      if (widget.existing == null) {
        name.text = '$game${value.isEmpty ? '' : '-$value'}';
      }
    });
    if (value.isEmpty) return;
    try {
      final rows = await widget.state.installer.loaderVersions(game, value);
      if (mounted && token == generation) {
        setState(() {
          loaders = rows;
          final preferred = widget.existing?.loader == value
              ? releaseLoaderVersion(
                  game,
                  value,
                  widget.existing!.loaderVersion,
                )
              : '';
          selected = rows.any((row) => row['version'] == preferred)
              ? preferred
              : (rows.where((e) => e['stable'] == true).firstOrNull ??
                        rows.firstOrNull)?['version'] ??
                    '';
          if (rows.isEmpty) error = '此游戏版本没有可用的 $value';
        });
      }
    } catch (e) {
      if (mounted && token == generation) setState(() => error = '$e');
    } finally {
      if (mounted && token == generation) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Row(
      children: [
        const Icon(Icons.download_outlined),
        const SizedBox(width: 12),
        Text(widget.existing == null ? '安装 Minecraft $game' : '调整版本与组件'),
      ],
    ),
    content: SizedBox(
      width: 580,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 8),
            TextField(
              controller: name,
              readOnly: widget.existing != null,
              decoration: const InputDecoration(labelText: '安装名称'),
            ),
            if (widget.existing != null) ...[
              const SizedBox(height: 16),
              const InfoStrip(
                '重新生成游戏与加载器文件，保留本地内容并备份旧版本。更换游戏版本后，原 Mod 的兼容性需要重新确认。',
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: game,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Minecraft 版本'),
                items: {game, ...widget.state.remoteVersions.map((v) => v.id)}
                    .map((v) => DropdownMenuItem(value: v, child: Text(v)))
                    .toList(),
                onChanged: (v) {
                  setState(() => game = v!);
                  selectLoader('');
                },
              ),
            ],
            const SizedBox(height: 22),
            const Text('选择加载器', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final value in [
                  '',
                  'Fabric',
                  'Forge',
                  'NeoForge',
                  'Quilt',
                  'OptiFine',
                ])
                  ChoiceChip(
                    label: Text(value.isEmpty ? '仅原版' : value),
                    selected: loader == value,
                    onSelected: (_) => selectLoader(value),
                  ),
              ],
            ),
            if (loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 20),
                child: LinearProgressIndicator(),
              ),
            if (loaders.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 18),
                child: DropdownButtonFormField<String>(
                  initialValue: selected,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: '组件版本'),
                  items: loaders
                      .map(
                        (e) => DropdownMenuItem<String>(
                          value: e['version'],
                          child: Text(
                            '${e['version']}${e['stable'] == true ? '   稳定版' : ''}',
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: (v) => setState(() => selected = v!),
                ),
              ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: InfoStrip(error!, warning: true),
              ),
            const SizedBox(height: 18),
            CheckboxListTile(
              value: isolate,
              onChanged: widget.existing != null
                  ? null
                  : (v) => setState(() => isolate = v!),
              contentPadding: EdgeInsets.zero,
              title: const Text('启用版本隔离', style: TextStyle(fontSize: 13)),
              subtitle: const Text(
                'Mod、资源包和存档放在该版本目录中',
                style: TextStyle(fontSize: 11),
              ),
            ),
            if (['Forge', 'NeoForge', 'OptiFine'].contains(loader))
              const InfoStrip('安装需要 Java。可在设置中指定 java.exe；本工具不会启动游戏。'),
            if (loader == 'OptiFine')
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: InfoStrip(
                  'OptiFine 列表和文件由 ${widget.state.settings.mirrorUrl} 提供。',
                ),
              ),
            const SizedBox(height: 18),
            Text('安装位置', style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 6),
            ValueListenableBuilder(
              valueListenable: name,
              builder: (_, value, _) => SelectableText(
                p.join(widget.state.requireRoot(), 'versions', value.text),
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton.icon(
        onPressed: loading || (loader.isNotEmpty && selected.isEmpty)
            ? null
            : () {
                try {
                  validateId(name.text.trim());
                  widget.state.enqueue(
                    '安装 ${name.text.trim()}',
                    'install',
                    InstallSpec(
                      root: widget.state.requireRoot(),
                      id: name.text.trim(),
                      game: game,
                      loader: loader,
                      loaderVersion: selected,
                      isolate: isolate,
                      replace: widget.existing != null,
                    ).toJson(),
                  );
                  Navigator.pop(context, true);
                } catch (e) {
                  setState(() => error = '$e');
                }
              },
        icon: const Icon(Icons.download, size: 18),
        label: const Text('开始安装'),
      ),
    ],
  );
}

class ResourceBrowser extends StatefulWidget {
  final AppState state;
  final String kind;
  final String? initialTarget;
  final VoidCallback onTask;
  final VoidCallback? onSettings;
  const ResourceBrowser({
    super.key,
    required this.state,
    required this.kind,
    this.initialTarget,
    required this.onTask,
    this.onSettings,
  });
  @override
  State<ResourceBrowser> createState() => _ResourceBrowserState();
}

class _ResourceBrowserState extends State<ResourceBrowser> {
  final query = TextEditingController();
  final game = TextEditingController();
  late String provider;
  String loader = '';
  String? target;
  List<Json> rows = [];
  bool loading = false, configureKey = false, showFilters = false;
  String? error;
  int page = 0, generation = 0;
  AppState get s => widget.state;
  LocalVersion? get selected =>
      s.localVersions.where((v) => v.id == target).firstOrNull;
  @override
  void initState() {
    super.initState();
    target = widget.initialTarget;
    if (selected != null) {
      game.text = selected!.game;
      loader = selected!.loader;
    }
    provider = s.settings.defaultResourceProvider;
    load();
  }

  @override
  void dispose() {
    query.dispose();
    game.dispose();
    super.dispose();
  }

  Future<void> load() async {
    final token = ++generation;
    setState(() {
      loading = true;
      error = null;
      configureKey = false;
    });
    try {
      final results = await s.resources.search(
        provider: provider,
        kind: widget.kind,
        query: query.text.trim(),
        game: game.text.trim(),
        loader: loader,
        page: page,
      );
      if (mounted && generation == token) setState(() => rows = results);
    } catch (e) {
      if (mounted && generation == token) {
        setState(() {
          error = '$e';
          configureKey =
              !s.settings.usesBundledCurseForgeKey &&
              (e is CurseForgeAccessException ||
                  (widget.kind == 'world' &&
                      provider == 'Modrinth' &&
                      s.settings.effectiveCurseKey.trim().isEmpty));
          rows = [];
        });
      }
    } finally {
      if (mounted && generation == token) setState(() => loading = false);
    }
  }

  Future<void> importPack() => importModpack(
    context,
    widget.state,
    onTask: widget.onTask,
    onSettings: widget.onSettings,
  );

  @override
  Widget build(BuildContext context) {
    final names = {
      'modpack': '整合包',
      'mod': 'Mod',
      'resourcepack': '资源包',
      'shader': '光影包',
      'datapack': '数据包',
      'world': '世界',
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeading(
            '下载${names[widget.kind]}',
            compact: true,
            '从社区资源平台浏览，安装到指定版本或另存为文件。',
            trailing: widget.kind == 'modpack'
                ? OutlinedButton.icon(
                    onPressed: importPack,
                    icon: const Icon(Icons.file_open_outlined, size: 18),
                    label: const Text('导入整合包'),
                  )
                : null,
          ),
          Row(
            children: [
              SizedBox(
                width: 150,
                child: DropdownButtonFormField<String>(
                  initialValue: provider,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: '资源平台'),
                  items: ['Modrinth', 'CurseForge']
                      .map(
                        (e) => DropdownMenuItem(
                          value: e,
                          child: Text(e, overflow: TextOverflow.ellipsis),
                        ),
                      )
                      .toList(),
                  onChanged: (v) {
                    setState(() {
                      provider = v!;
                      page = 0;
                    });
                    load();
                  },
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: query,
                  onSubmitted: (_) {
                    page = 0;
                    load();
                  },
                  decoration: InputDecoration(
                    hintText: '搜索${names[widget.kind]}名称',
                    prefixIcon: const Icon(Icons.search, size: 20),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton(
                onPressed: () {
                  page = 0;
                  load();
                },
                child: const Text('搜索'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              SizedBox(
                width: 230,
                child: DropdownButtonFormField<String>(
                  key: ValueKey('target:$target'),
                  initialValue: s.localVersions.any((v) => v.id == target)
                      ? target
                      : null,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: '目标版本',
                    hintText: '仅浏览 / 另存为',
                  ),
                  items: [
                    const DropdownMenuItem<String>(
                      value: '',
                      child: Text('仅浏览 / 另存为'),
                    ),
                    ...s.localVersions.map(
                      (v) => DropdownMenuItem(
                        value: v.id,
                        child: Text(
                          '${v.id} · ${v.label}',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                  ],
                  onChanged: (id) {
                    setState(() {
                      target = id;
                      game.text = selected?.game ?? '';
                      loader = selected?.loader ?? '';
                      page = 0;
                    });
                    load();
                  },
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  '接口：${provider == 'Modrinth' ? 'api.modrinth.com' : 'api.curseforge.com'} · 文件来自平台原始地址',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              TextButton.icon(
                key: const ValueKey('resource-filter-toggle'),
                onPressed: () => setState(() => showFilters = !showFilters),
                icon: Icon(
                  showFilters ? Icons.expand_less : Icons.tune,
                  size: 16,
                ),
                label: Text(
                  showFilters
                      ? '收起筛选'
                      : '筛选${[if (target != null && target!.isNotEmpty) '目标版本', if (game.text.isNotEmpty) game.text, if (loader.isNotEmpty) loader].isEmpty ? '' : ' · 已应用'}',
                ),
              ),
            ],
          ),
          if (showFilters) ...[
            Row(
              children: [
                SizedBox(
                  width: 130,
                  child: TextField(
                    controller: game,
                    decoration: const InputDecoration(
                      labelText: '游戏版本',
                      hintText: '全部',
                    ),
                    onSubmitted: (_) {
                      page = 0;
                      load();
                    },
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 140,
                  child: DropdownButtonFormField<String>(
                    key: ValueKey(loader),
                    isExpanded: true,
                    initialValue:
                        [
                          '',
                          'Fabric',
                          'Forge',
                          'NeoForge',
                          'Quilt',
                        ].contains(loader)
                        ? loader
                        : '',
                    decoration: const InputDecoration(labelText: '加载器'),
                    items: ['', 'Fabric', 'Forge', 'NeoForge', 'Quilt']
                        .map(
                          (v) => DropdownMenuItem(
                            value: v,
                            child: Text(v.isEmpty ? '全部' : v),
                          ),
                        )
                        .toList(),
                    onChanged: (v) {
                      setState(() {
                        loader = v!;
                        page = 0;
                      });
                      load();
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
          ],
          if (loading) const LinearProgressIndicator(),
          Expanded(
            child: error != null
                ? EmptyState(
                    '资源获取失败',
                    error!,
                    button: OutlinedButton(
                      onPressed: configureKey && widget.onSettings != null
                          ? widget.onSettings
                          : load,
                      child: Text(
                        configureKey && widget.onSettings != null
                            ? '配置 CurseForge Key'
                            : '重试',
                      ),
                    ),
                  )
                : rows.isEmpty && !loading
                ? const EmptyState('没有匹配资源', '试试其他关键词、版本、加载器或资源平台。')
                : Card(
                    key: const ValueKey('resource-results'),
                    child: ListView.separated(
                      itemCount: rows.length,
                      separatorBuilder: (_, _) =>
                          const Divider(height: 1, indent: 72),
                      itemBuilder: (context, i) {
                        final r = rows[i];
                        return ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 5,
                          ),
                          leading: Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: Theme.of(
                                context,
                              ).colorScheme.primary.withValues(alpha: .08),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Icon(
                              widget.kind == 'modpack'
                                  ? Icons.inventory_2_outlined
                                  : Icons.extension_outlined,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ),
                          title: Text(
                            r['title'],
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const SizedBox(height: 3),
                              Text(
                                r['description'] ?? '',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 12),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                '${r['author']}  ·  ${bytesLabel((r['downloads'] as num?) ?? 0).replaceAll(' B', '').replaceAll('KB', '千次').replaceAll('MB', '百万次')} 下载',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => showDialog<void>(
                            context: context,
                            builder: (_) => ResourceDialog(
                              state: s,
                              project: r,
                              game: game.text.trim(),
                              loader: loader,
                              target: selected,
                              onTask: widget.onTask,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: page == 0 || loading
                    ? null
                    : () {
                        page--;
                        load();
                      },
                child: const Text('上一页'),
              ),
              Text(
                '第 ${page + 1} 页',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              TextButton(
                onPressed: rows.length < 20 || loading
                    ? null
                    : () {
                        page++;
                        load();
                      },
                child: const Text('下一页'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class ResourceDialog extends StatefulWidget {
  final AppState state;
  final Json project;
  final String game, loader;
  final LocalVersion? target;
  final VoidCallback onTask;
  const ResourceDialog({
    super.key,
    required this.state,
    required this.project,
    required this.game,
    required this.loader,
    this.target,
    required this.onTask,
  });
  @override
  State<ResourceDialog> createState() => _ResourceDialogState();
}

class _ResourceDialogState extends State<ResourceDialog> {
  List<Json> rows = [];
  bool loading = true;
  String? error;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final r = await widget.state.resources.versions(
        widget.project,
        game: widget.game,
        loader: widget.loader,
      );
      if (mounted) setState(() => rows = r);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> choose(Json version, bool save) async {
    await action(context, () async {
      final s = widget.state;
      final target = widget.target;
      if (save) {
        final destination = await FilePicker.platform.saveFile(
          fileName: version['filename'],
          dialogTitle: '另存为资源文件',
        );
        if (destination == null) return;
        s.enqueue('下载 ${version['filename']}', 'save', {
          'version': version,
          'path': destination,
        });
      } else if (widget.project['kind'] == 'modpack') {
        final root = s.requireRoot();
        final id = await input(
          context,
          '安装整合包',
          value: (widget.project['title'] as String).replaceAll(
            RegExp(r'[<>:"/\\|?*]'),
            '-',
          ),
        );
        if (id == null) return;
        validateId(id);
        s.enqueue('安装整合包 $id', 'remotePack', {
          'version': version,
          'root': root,
          'id': id,
        });
      } else {
        if (target == null) throw StateError('请先在下载页选择目标版本，或选择另存为');
        String? world;
        if (widget.project['kind'] == 'datapack') {
          final worlds = await s.contentFiles(target, 'saves');
          if (!mounted) return;
          world = await showDialog<String>(
            context: context,
            builder: (ctx) => SimpleDialog(
              title: const Text('选择目标世界'),
              children: worlds
                  .where((w) => w['directory'] == true)
                  .map(
                    (w) => SimpleDialogOption(
                      onPressed: () => Navigator.pop(ctx, w['name']),
                      child: Text(w['name']),
                    ),
                  )
                  .toList(),
            ),
          );
          if (world == null) return;
        }
        if (widget.project['kind'] == 'world') {
          if (!mounted) return;
          final name = await input(
            context,
            '世界名称',
            value: widget.project['title'],
          );
          if (name == null) return;
          validateId(name);
          s.enqueue('安装世界 $name', 'world', {
            'version': version,
            'root': target.root,
            'target': target.id,
            'name': name,
          });
        } else {
          s.enqueue('安装 ${version['filename']}', 'resource', {
            'version': version,
            'root': target.root,
            'target': target.id,
            'world': world,
            'update': true,
          });
        }
      }
      if (mounted) Navigator.pop(context);
      widget.onTask();
    });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.project['title']),
    content: SizedBox(
      width: 740,
      height: 470,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.project['description'] ?? '',
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 12),
          Text(
            '平台：${widget.project['provider']}  ·  ${widget.game.isEmpty ? '全部游戏版本' : widget.game} ${widget.loader}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          if (widget.target != null)
            InfoStrip(
              '安装到 ${widget.target!.id} · ${widget.target!.contentPath}',
            ),
          const SizedBox(height: 12),
          Expanded(
            child: loading
                ? const Center(child: CircularProgressIndicator())
                : error != null
                ? EmptyState('获取失败', error!)
                : rows.isEmpty
                ? const EmptyState('没有兼容文件', '调整游戏版本和加载器后重试')
                : ListView.separated(
                    itemCount: rows.length,
                    separatorBuilder: (_, _) => const Divider(),
                    itemBuilder: (_, i) {
                      final v = rows[i];
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              v['name'],
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              '${v['filename']} · ${bytesLabel(v['size'] ?? 0)}',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            const SizedBox(height: 4),
                            SelectableText(
                              asList(v['urls']).join('\n').isEmpty
                                  ? '此文件限制第三方下载，请在项目官网获取'
                                  : asList(v['urls']).join('\n'),
                              style: const TextStyle(fontSize: 10),
                            ),
                            const SizedBox(height: 8),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                TextButton(
                                  onPressed: asList(v['urls']).isEmpty
                                      ? null
                                      : () => choose(v, true),
                                  child: const Text('另存为'),
                                ),
                                const SizedBox(width: 8),
                                FilledButton(
                                  onPressed: asList(v['urls']).isEmpty
                                      ? null
                                      : () => choose(v, false),
                                  child: const Text('安装'),
                                ),
                              ],
                            ),
                          ],
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
        onPressed: () => action(context, () => openWeb(widget.project['url'])),
        child: const Text('项目官网'),
      ),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('关闭'),
      ),
    ],
  );
}
