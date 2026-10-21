import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../app_state.dart';
import '../core/models.dart';
import '../core/network.dart';
import '../core/java_runtime.dart';
import 'common.dart';

class SettingsPage extends StatefulWidget {
  final AppState state;
  const SettingsPage({super.key, required this.state});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final proxy = TextEditingController(
    text: widget.state.settings.proxyUrl,
  );
  late final mirror = TextEditingController(
    text: widget.state.settings.mirrorUrl,
  );
  late final java = TextEditingController(text: widget.state.settings.javaPath);
  late final keyField = TextEditingController(
    text: widget.state.settings.curseKey,
  );
  late ProxyMode proxyMode = widget.state.settings.proxyMode;
  late SourceMode sourceMode = widget.state.settings.sourceMode;
  late bool fallback = widget.state.settings.fallback;
  late bool isolate = widget.state.settings.isolate;
  late double concurrency = widget.state.settings.concurrency.toDouble();
  bool testing = false;
  final List<String> diagnostics = [];
  AppState get s => widget.state;
  @override
  void dispose() {
    proxy.dispose();
    mirror.dispose();
    java.dispose();
    keyField.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (proxyMode == ProxyMode.manual) {
      final u = Uri.tryParse(proxy.text.trim());
      if (u == null ||
          u.scheme != 'http' ||
          u.host.isEmpty ||
          !u.hasPort ||
          u.port <= 0 ||
          u.path.isNotEmpty && u.path != '/') {
        throw const FormatException(
          '代理请输入 http://主机:端口，支持 HTTP CONNECT，不接受 SOCKS 地址',
        );
      }
    }
    final u = Uri.tryParse(mirror.text.trim());
    if (u == null ||
        !['http', 'https'].contains(u.scheme) ||
        u.host.isEmpty ||
        u.userInfo.isNotEmpty ||
        u.hasQuery ||
        u.hasFragment) {
      throw const FormatException('请输入有效的 BMCLAPI 兼容镜像根地址');
    }
    if (java.text.trim().isEmpty) {
      throw const FormatException('请填写 Java 路径或 java');
    }
    s.settings.proxyMode = proxyMode;
    s.settings.proxyUrl = proxy.text.trim();
    s.settings.sourceMode = sourceMode;
    s.settings.mirrorUrl = mirror.text.trim().replaceAll(RegExp(r'/+$'), '');
    s.settings.fallback = fallback;
    s.settings.concurrency = concurrency.round();
    s.settings.javaPath = java.text.trim();
    s.settings.curseKey = keyField.text.trim();
    s.settings.isolate = isolate;
    s.network.clearProxyCache();
    await s.save();
    s.changed();
    if (mounted) message(context, '设置已保存，对后续请求生效');
  }

  Future<void> test() async {
    await action(context, () async {
      await save();
      setState(() {
        testing = true;
        diagnostics.clear();
      });
      try {
        final probes = {
          'Mojang 版本列表': SourcePolicy.manifest,
          '配置的镜像': '${s.settings.mirrorUrl}/mc/game/version_manifest_v2.json',
          'Fabric': 'https://meta.fabricmc.net/v2/versions/loader',
          'Quilt': 'https://meta.quiltmc.org/v3/versions/loader',
          'Modrinth': 'https://api.modrinth.com/v2/tag/game_version',
        };
        for (final entry in probes.entries) {
          final watch = Stopwatch()..start();
          try {
            final response = await s.network.json([entry.value]);
            final message =
                '${entry.key}  可用  ${watch.elapsedMilliseconds} ms  ·  ${response is List ? response.length : 'JSON'}';
            if (mounted) setState(() => diagnostics.add(message));
          } catch (e) {
            if (mounted) setState(() => diagnostics.add('${entry.key}  失败：$e'));
          }
        }
      } finally {
        if (mounted) setState(() => testing = false);
      }
    });
  }

  Widget section(String title, String subtitle, List<Widget> children) => Card(
    child: Padding(
      padding: const EdgeInsets.all(22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 20),
          ...children,
        ],
      ),
    ),
  );
  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: const EdgeInsets.all(28),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeading(
          '设置',
          '管理网络、下载来源和本地安装选项。',
          trailing: FilledButton.icon(
            onPressed: () => action(context, save),
            icon: const Icon(Icons.check, size: 18),
            label: const Text('保存设置'),
          ),
        ),
        section('代理', '统一应用于版本列表、元数据、游戏和社区资源下载。', [
          SegmentedButton<ProxyMode>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(
                value: ProxyMode.system,
                icon: Icon(Icons.desktop_windows_outlined, size: 17),
                label: Text('跟随系统'),
              ),
              ButtonSegment(value: ProxyMode.manual, label: Text('手动代理')),
              ButtonSegment(value: ProxyMode.direct, label: Text('直接连接')),
            ],
            selected: {proxyMode},
            onSelectionChanged: (v) => setState(() => proxyMode = v.first),
          ),
          const SizedBox(height: 16),
          if (proxyMode == ProxyMode.system)
            const InfoStrip(
              '读取 Windows 系统代理，支持自动配置脚本（PAC）及绕过规则。读取失败会明确报错，不自动改为直连。',
            ),
          if (proxyMode == ProxyMode.manual)
            TextField(
              controller: proxy,
              decoration: const InputDecoration(
                labelText: 'HTTP 代理地址',
                hintText: 'http://127.0.0.1:7890',
                helperText:
                    '支持 HTTP CONNECT 和用户名密码。不支持 SOCKS；请使用代理软件的 HTTP 或混合端口。',
              ),
            ),
          if (proxyMode == ProxyMode.direct) const InfoStrip('所有请求直接连接目标服务器。'),
        ]),
        const SizedBox(height: 18),
        section('下载来源', '明确优先顺序和实际请求地址，不对未知站点做隐式替换。', [
          SegmentedButton<SourceMode>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: SourceMode.official, label: Text('官方源优先')),
              ButtonSegment(value: SourceMode.mirror, label: Text('镜像源优先')),
            ],
            selected: {sourceMode},
            onSelectionChanged: (v) => setState(() => sourceMode = v.first),
          ),
          const SizedBox(height: 18),
          TextField(
            controller: mirror,
            decoration: const InputDecoration(
              labelText: 'BMCLAPI 兼容镜像根地址',
              hintText: 'https://bmclapi2.bangbang93.com',
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('允许失败后切换候选源', style: TextStyle(fontSize: 13)),
            subtitle: const Text(
              '仅对有明确映射的 Mojang、资源、支持库、Forge 和 Fabric 请求生效',
              style: TextStyle(fontSize: 11),
            ),
            value: fallback,
            onChanged: (v) => setState(() => fallback = v),
          ),
          const Divider(),
          for (final (label, url) in [
            ('游戏与版本元数据', 'piston-meta.mojang.com / piston-data.mojang.com'),
            (
              '游戏资源与支持库',
              'resources.download.minecraft.net / libraries.minecraft.net',
            ),
            ('Fabric / Quilt', 'meta.fabricmc.net / meta.quiltmc.org'),
            (
              'Forge / NeoForge',
              'maven.minecraftforge.net / maven.neoforged.net',
            ),
            ('社区资源', 'api.modrinth.com / api.curseforge.com；文件采用平台原始链接'),
            ('OptiFine', '已配置 BMCLAPI 镜像；不伪装成官方源'),
          ])
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 9),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 160,
                    child: Text(label, style: const TextStyle(fontSize: 12)),
                  ),
                  Expanded(
                    child: SelectableText(
                      url,
                      style: TextStyle(
                        fontSize: 11,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            children: [
              OutlinedButton.icon(
                onPressed: testing ? null : test,
                icon: const Icon(Icons.network_check, size: 18),
                label: Text(testing ? '检测中…' : '保存并检测接口'),
              ),
              TextButton(
                onPressed: () => showLog(context, '网络请求记录', s.network.audit),
                child: const Text('查看实际请求记录'),
              ),
            ],
          ),
          if (testing)
            const Padding(
              padding: EdgeInsets.only(top: 16),
              child: LinearProgressIndicator(),
            ),
          if (diagnostics.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 14),
              child: SelectableText(
                diagnostics.join('\n'),
                style: const TextStyle(fontSize: 12, height: 1.8),
              ),
            ),
        ]),
        const SizedBox(height: 18),
        section('安装与下载', '下载并发按文件控制，大文件支持校验和条件式续传。', [
          Row(
            children: [
              const SizedBox(width: 120, child: Text('并发文件数')),
              Expanded(
                child: Slider(
                  min: 1,
                  max: 24,
                  divisions: 23,
                  value: concurrency.clamp(1, 24),
                  label: '${concurrency.round()}',
                  onChanged: (v) => setState(() => concurrency = v),
                ),
              ),
              SizedBox(width: 36, child: Text('${concurrency.round()}')),
            ],
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('新版本默认开启版本隔离', style: TextStyle(fontSize: 13)),
            value: isolate,
            onChanged: (v) => setState(() => isolate = v),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: java,
                  decoration: const InputDecoration(
                    labelText: 'Java 可执行文件',
                    hintText: r'C:\Program Files\Java\jdk-21\bin\java.exe',
                    helperText:
                        'Forge / NeoForge / OptiFine 安装时使用。java 表示从 PATH 查找。',
                  ),
                ),
              ),
              const SizedBox(width: 12),
              OutlinedButton(
                onPressed: () => action(context, () async {
                  final result = await FilePicker.platform.pickFiles(
                    dialogTitle: '选择 java.exe',
                  );
                  if (result != null) java.text = result.files.single.path!;
                }),
                child: const Text('选择文件'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: () => action(context, () async {
              final runtimes = await discoverJava(gameRoots: s.settings.roots);
              if (!context.mounted) return;
              if (runtimes.isEmpty) {
                throw StateError('未找到可用 Java，可选择 java.exe 或通过下方官方链接安装。');
              }
              final selected = await showDialog<JavaRuntime>(
                context: context,
                builder: (context) => SimpleDialog(
                  title: const Text('选择已安装的 Java'),
                  children: [
                    for (final runtime in runtimes)
                      SimpleDialogOption(
                        onPressed: () => Navigator.pop(context, runtime),
                        child: Text(
                          'Java ${runtime.version}\n${runtime.executable}',
                        ),
                      ),
                  ],
                ),
              );
              if (selected != null) java.text = selected.executable;
            }),
            child: const Text('查找已安装的 Java'),
          ),
          TextButton(
            onPressed: () => action(context, () async {
              final result = await inspectJava(java.text.trim());
              if (context.mounted) {
                await showLog(context, 'Java 检测', [
                  'Java ${result.version}',
                  result.executable,
                ]);
              }
            }),
            child: const Text('检测 Java'),
          ),
          TextButton(
            onPressed: () => action(
              context,
              () =>
                  openWeb('https://adoptium.net/temurin/releases/?os=windows'),
            ),
            child: const Text('获取 Eclipse Temurin Java（官方）'),
          ),
        ]),
        const SizedBox(height: 18),
        section('CurseForge', '使用你自己的 API Key 访问资源搜索与文件接口。Modrinth 无需配置。', [
          TextField(
            controller: keyField,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'API Key',
              helperText: '只保存在本机应用配置中，不上传。作者限制第三方下载时需在官网手动获取。',
            ),
          ),
          const SizedBox(height: 10),
          TextButton(
            onPressed: () => action(
              context,
              () => openWeb('https://console.curseforge.com/'),
            ),
            child: const Text('前往 CurseForge 开发者平台'),
          ),
        ]),
        const SizedBox(height: 18),
        section('游戏目录', '移除记录只取消关联，不删除目录内文件。', [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: s.settings.autoDiscover,
            title: const Text('启动时检测官方游戏目录', style: TextStyle(fontSize: 13)),
            subtitle: const Text(
              '仅检测官方默认位置和工具旁的 .minecraft，不遍历磁盘；移除过的目录不会自动加回。',
              style: TextStyle(fontSize: 11),
            ),
            onChanged: (value) {
              s.settings.autoDiscover = value;
              s.changed();
            },
          ),
          for (final root in s.settings.roots)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.folder_outlined),
              title: Text(root, style: const TextStyle(fontSize: 12)),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: '打开目录',
                    onPressed: () => action(context, () => openFolder(root)),
                    icon: const Icon(Icons.open_in_new, size: 18),
                  ),
                  IconButton(
                    tooltip: '移除记录',
                    onPressed: () => action(context, () => s.removeRoot(root)),
                    icon: const Icon(Icons.link_off, size: 18),
                  ),
                ],
              ),
            ),
          TextButton.icon(
            onPressed: () => addRoot(context, s),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('添加游戏目录'),
          ),
        ]),
        const SizedBox(height: 18),
        section(
          '关于 MC Download',
          '由第三方独立制作的 Flutter 下载与文件管理工具，与 PCL / HMCL 官方无关联。',
          [
            const Text(
              'MIT License',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            const Text(
              '感谢 PCL、HMCL 及其开发者提供的设计与技术参考。',
              style: TextStyle(fontSize: 12, height: 1.8),
            ),
            const SizedBox(height: 10),
            TextButton(
              onPressed: () => showLicensePage(
                context: context,
                applicationName: 'MC Download',
                applicationVersion: '0.1.0',
              ),
              child: const Text('开源依赖许可证'),
            ),
            TextButton(
              onPressed: () => action(context, () => openFolder(s.dataPath)),
              child: const Text('打开应用数据与日志目录'),
            ),
          ],
        ),
      ],
    ),
  );
}
