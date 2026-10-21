import 'package:flutter/material.dart';
import '../app_state.dart';
import '../core/models.dart';
import 'common.dart';
import 'download_page.dart';
import 'versions_page.dart';
import 'tasks_page.dart';
import 'settings_page.dart';

class AppShell extends StatefulWidget {
  final AppState state;
  const AppShell({super.key, required this.state});
  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int page = 0;
  bool focusCurseForge = false;
  String category = 'game';
  String? targetId;
  AppState get s => widget.state;
  final categories = const [
    ('game', '原版游戏', Icons.sports_esports_outlined),
    ('modpack', '整合包', Icons.inventory_2_outlined),
    ('mod', 'Mod', Icons.extension_outlined),
    ('resourcepack', '资源包', Icons.texture_outlined),
    ('shader', '光影包', Icons.wb_sunny_outlined),
    ('datapack', '数据包', Icons.data_object),
    ('world', '世界', Icons.public_outlined),
  ];
  void browse(LocalVersion version, String kind) => setState(() {
    targetId = version.id;
    category = kind;
    page = 0;
  });
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final active = s.jobs.where((j) => j.active).length;
    return Scaffold(
      body: Column(
        children: [
          Container(
            height: 58,
            padding: const EdgeInsets.symmetric(horizontal: 18),
            color: Theme.of(context).cardTheme.color,
            child: Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: scheme.primary,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(
                    Icons.downloading_rounded,
                    color: Colors.white,
                    size: 24,
                  ),
                ),
                const SizedBox(width: 12),
                const Text(
                  'MC Download',
                  style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
                ),
                const SizedBox(width: 10),
                smallChip(context, 'Windows'),
                const SizedBox(width: 22),
                for (final (index, label, icon) in [
                  (0, '下载', Icons.download_outlined),
                  (1, '版本管理', Icons.grid_view_outlined),
                  (
                    2,
                    active == 0 ? '任务' : '任务 · $active',
                    Icons.list_alt_outlined,
                  ),
                  (3, '设置', Icons.tune),
                ])
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: TextButton.icon(
                      style: TextButton.styleFrom(
                        foregroundColor: page == index
                            ? scheme.primary
                            : scheme.onSurfaceVariant,
                        backgroundColor: page == index
                            ? scheme.primary.withValues(alpha: .08)
                            : null,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      onPressed: () => setState(() {
                        page = index;
                        focusCurseForge = false;
                      }),
                      icon: Icon(icon, size: 18),
                      label: Text(label),
                    ),
                  ),
                const Spacer(),
                IconButton(
                  tooltip: '切换明暗主题',
                  onPressed: () {
                    s.settings.dark = !s.settings.dark;
                    s.changed();
                  },
                  icon: Icon(
                    s.settings.dark
                        ? Icons.light_mode_outlined
                        : Icons.dark_mode_outlined,
                    size: 20,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: Row(
              children: [
                SizedBox(
                  width: 164,
                  child: Material(
                    color: Theme.of(context).cardTheme.color,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
                          child: Text(
                            page == 0
                                ? '下载内容'
                                : ['', '本地游戏', '下载中心', '应用设置'][page],
                            style: TextStyle(
                              fontSize: 11,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                        if (page == 0) ...[
                          for (final (id, label, icon) in categories)
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 1,
                              ),
                              child: ListTile(
                                dense: true,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                selected: id == category,
                                selectedTileColor: scheme.primary.withValues(
                                  alpha: .08,
                                ),
                                leading: Icon(icon, size: 20),
                                title: Text(label),
                                onTap: () => setState(() => category = id),
                              ),
                            ),
                        ] else
                          Padding(
                            padding: const EdgeInsets.all(12),
                            child: ListTile(
                              selected: true,
                              dense: true,
                              selectedTileColor: scheme.primary.withValues(
                                alpha: .08,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                              leading: Icon(
                                [
                                  Icons.download,
                                  Icons.folder_copy_outlined,
                                  Icons.list_alt_outlined,
                                  Icons.settings_outlined,
                                ][page],
                                size: 20,
                              ),
                              title: Text(
                                ['下载', '已安装版本', '所有任务', '常规与网络'][page],
                              ),
                            ),
                          ),
                        const Spacer(),
                        Padding(
                          padding: const EdgeInsets.all(20),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '独立下载 · 本地管理',
                                style: TextStyle(
                                  color: scheme.onSurfaceVariant,
                                  fontSize: 11,
                                ),
                              ),
                              const SizedBox(height: 6),
                              const Text(
                                'Windows / Java Edition',
                                style: TextStyle(fontSize: 10),
                              ),
                              const SizedBox(height: 16),
                              TextButton.icon(
                                onPressed: () => setState(() => page = 3),
                                icon: const Icon(
                                  Icons.route_outlined,
                                  size: 16,
                                ),
                                label: Text(
                                  s.settings.sourceMode == SourceMode.official
                                      ? '官方源优先'
                                      : '镜像源优先',
                                  style: const TextStyle(fontSize: 12),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const VerticalDivider(width: 1),
                Expanded(
                  child: Column(
                    children: [
                      Container(
                        height: 44,
                        padding: const EdgeInsets.symmetric(horizontal: 18),
                        child: Row(
                          children: [
                            Icon(
                              Icons.folder_outlined,
                              size: 18,
                              color: scheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: s.settings.roots.isEmpty
                                  ? const Text(
                                      '尚未选择游戏目录',
                                      style: TextStyle(fontSize: 12),
                                    )
                                  : DropdownButtonHideUnderline(
                                      child: DropdownButton<String>(
                                        value: s.settings.selectedRoot,
                                        isExpanded: true,
                                        isDense: true,
                                        style: Theme.of(
                                          context,
                                        ).textTheme.bodySmall,
                                        items: s.settings.roots
                                            .map(
                                              (r) => DropdownMenuItem(
                                                value: r,
                                                child: Text(
                                                  r,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                ),
                                              ),
                                            )
                                            .toList(),
                                        onChanged: (r) {
                                          if (r != null) {
                                            action(
                                              context,
                                              () => s.selectRoot(r),
                                            );
                                          }
                                        },
                                      ),
                                    ),
                            ),
                            const SizedBox(width: 16),
                            TextButton.icon(
                              onPressed: () => addRoot(context, s),
                              icon: const Icon(Icons.add, size: 16),
                              label: const Text('添加目录'),
                            ),
                          ],
                        ),
                      ),
                      const Divider(height: 1),
                      if (s.recoveryNotice != null)
                        InfoStrip(
                          s.recoveryNotice!,
                          warning: true,
                          action: TextButton(
                            onPressed: () {
                              s.recoveryNotice = null;
                              s.refresh();
                            },
                            child: const Text('知道了'),
                          ),
                        ),
                      if (s.persistenceError != null)
                        InfoStrip(
                          s.persistenceError!,
                          warning: true,
                          action: TextButton(
                            onPressed: () => action(context, s.save),
                            child: const Text('重试保存'),
                          ),
                        ),
                      if (s.discoveredAtStartup > 0)
                        InfoStrip(
                          '已自动加入 ${s.discoveredAtStartup} 个已有游戏目录，可在上方切换。',
                          action: IconButton(
                            tooltip: '关闭提示',
                            onPressed: () {
                              s.discoveredAtStartup = 0;
                              s.refresh();
                            },
                            icon: const Icon(Icons.close, size: 16),
                          ),
                        ),
                      Expanded(
                        child: switch (page) {
                          0 => DownloadPage(
                            state: s,
                            category: category,
                            targetId: targetId,
                            onTask: () => setState(() => page = 2),
                            onSettings: () => setState(() {
                              page = 3;
                              focusCurseForge = true;
                            }),
                          ),
                          1 => VersionsPage(
                            state: s,
                            onBrowse: browse,
                            onTask: () => setState(() => page = 2),
                          ),
                          2 => TasksPage(state: s),
                          _ => SettingsPage(
                            state: s,
                            focusCurseForge: focusCurseForge,
                          ),
                        },
                      ),
                    ],
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
