import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/app_version.dart';
import '../core/models.dart';
import '../core/network.dart';
import '../core/java_runtime.dart';
import 'common.dart';

class SettingsPage extends StatefulWidget {
  final AppState state;
  final bool focusCurseForge;
  final VoidCallback? onManageRoots;
  const SettingsPage({
    super.key,
    required this.state,
    this.focusCurseForge = false,
    this.onManageRoots,
  });
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final curseForgeSection = GlobalKey();
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
  bool testing = false, checkingKey = false, keyVisible = false;
  String? keyResult;
  List<JavaRuntime> runtimes = [];
  bool scanningJava = false;
  String? javaScanError;
  final List<String> diagnostics = [];
  AppState get s => widget.state;
  @override
  void initState() {
    super.initState();
    if (automaticJava(java.text)) java.text = 'auto';
    scanJava();
    if (widget.focusCurseForge) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final target = curseForgeSection.currentContext;
        if (mounted && target != null) {
          Scrollable.ensureVisible(
            target,
            duration: const Duration(milliseconds: 250),
          );
        }
      });
    }
  }

  Future<void> scanJava() async {
    setState(() {
      scanningJava = true;
      javaScanError = null;
    });
    try {
      final found = await s.installedJava();
      if (mounted) setState(() => runtimes = found);
    } catch (e) {
      if (mounted) setState(() => javaScanError = '$e');
    } finally {
      if (mounted) setState(() => scanningJava = false);
    }
  }

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
    if (!s.settings.usesBundledCurseForgeKey) {
      s.settings.curseKey = keyField.text.trim();
    }
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

  Future<void> saveCurseForgeKey({bool verify = false}) async {
    if (checkingKey || s.settings.usesBundledCurseForgeKey) return;
    await action(context, () async {
      final value = keyField.text.trim();
      if (verify && value.isEmpty) {
        throw const CurseForgeAccessException('请先填写 API Key。申请步骤和官方入口在此区域下方。');
      }
      if (value.contains(RegExp(r'[\r\n]'))) {
        throw const FormatException('API Key 不能包含换行，请重新粘贴完整 Key');
      }
      setState(() {
        checkingKey = true;
        keyResult = null;
      });
      try {
        s.settings.curseKey = value;
        await s.save();
        s.refresh();
        if (!mounted) return;
        if (verify) {
          await s.resources.verifyCurseForgeKey();
          if (mounted) {
            setState(
              () => keyResult = '验证通过：CurseForge API 可以访问。文件下载仍受资源作者的权限设置限制。',
            );
          }
        } else {
          setState(
            () => keyResult = value.isEmpty
                ? '已清除 Key，CurseForge 查询和下载已停用。'
                : 'Key 已保存，尚未验证。',
          );
        }
      } catch (e) {
        if (mounted) setState(() => keyResult = '${verify ? '验证' : '保存'}失败：$e');
      } finally {
        if (mounted) setState(() => checkingKey = false);
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
            subtitle: const Text(
              '全局默认值，可在目录管理中单独设置；不改变已有版本。',
              style: TextStyle(fontSize: 11),
            ),
            value: isolate,
            onChanged: (v) => setState(() => isolate = v),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  key: ValueKey('java:${java.text}:${runtimes.length}'),
                  initialValue: java.text,
                  isExpanded: true,
                  menuMaxHeight: 360,
                  decoration: const InputDecoration(
                    labelText: '安装使用的 Java',
                    helperText: '自动选择会按安装处理器的版本要求选择兼容的 Java。',
                    helperMaxLines: 2,
                  ),
                  items: [
                    const DropdownMenuItem(
                      value: 'auto',
                      child: Text('自动选择（推荐）'),
                    ),
                    for (final runtime in runtimes)
                      DropdownMenuItem(
                        value: runtime.executable,
                        child: Tooltip(
                          message: runtime.executable,
                          child: Text(
                            'Java ${runtime.version} · ${runtime.executable}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    if (java.text != 'auto' &&
                        !runtimes.any((r) => r.executable == java.text))
                      DropdownMenuItem(
                        value: java.text,
                        child: Text(
                          '手动指定 · ${java.text}',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (value) {
                    if (value != null) setState(() => java.text = value);
                  },
                ),
              ),
              const SizedBox(width: 12),
              OutlinedButton(
                onPressed: () => action(context, () async {
                  final result = await FilePicker.platform.pickFiles(
                    dialogTitle: '选择 java.exe',
                  );
                  final path = result?.files.single.path;
                  if (path == null) return;
                  final runtime = await inspectJava(path);
                  if (!mounted) return;
                  setState(() {
                    runtimes.removeWhere(
                      (r) => r.executable == runtime.executable,
                    );
                    runtimes.add(runtime);
                    java.text = runtime.executable;
                  });
                }),
                child: const Text('选择文件'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                scanningJava
                    ? '正在扫描已安装的 Java…'
                    : '已找到 ${runtimes.length} 个 Java',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              TextButton.icon(
                onPressed: scanningJava ? null : scanJava,
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('刷新扫描'),
              ),
              TextButton(
                onPressed: () => action(context, () async {
                  final result = automaticJava(java.text)
                      ? selectJava(await s.installedJava())
                      : await inspectJava(java.text);
                  if (context.mounted) {
                    await showLog(context, 'Java 检测', [
                      'Java ${result.version}',
                      result.executable,
                    ]);
                  }
                }),
                child: const Text('检测 Java'),
              ),
            ],
          ),
          if (javaScanError != null) Text(javaScanError!),
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
        if (!s.settings.usesBundledCurseForgeKey)
          section('CurseForge', '查询资源和下载文件都需要先填写并保存自己的 API Key。Modrinth 无需 Key。', [
            KeyedSubtree(
              key: curseForgeSection,
              child: TextField(
                key: const ValueKey('curseforge-api-key'),
                enabled: !checkingKey,
                controller: keyField,
                obscureText: !keyVisible,
                onChanged: (_) => setState(() => keyResult = null),
                decoration: InputDecoration(
                  labelText: 'API Key',
                  helperText:
                      '保存在 .mcdownload/settings.json，仅发送至 CurseForge 官方 API 和文件 CDN。',
                  helperMaxLines: 3,
                  suffixIcon: IconButton(
                    tooltip: keyVisible ? '隐藏 Key' : '显示 Key',
                    onPressed: () => setState(() => keyVisible = !keyVisible),
                    icon: Icon(
                      keyVisible
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton(
                  onPressed: checkingKey ? null : () => saveCurseForgeKey(),
                  child: const Text('保存 Key'),
                ),
                FilledButton(
                  onPressed: checkingKey
                      ? null
                      : () => saveCurseForgeKey(verify: true),
                  child: Text(checkingKey ? '请稍候…' : '保存并验证 Key'),
                ),
              ],
            ),
            if (keyResult != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: InfoStrip(keyResult!),
              ),
            const SizedBox(height: 8),
            const Text(
              '验证使用已保存的代理设置。若更改了代理，请先点击页面顶部“保存设置”。',
              style: TextStyle(fontSize: 11),
            ),
            const SizedBox(height: 16),
            const Text(
              '如何申请 API Key',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            const Text(
              '1. 打开下方“官方申请说明”，进入 How to Apply for an API Key，按页面链接填写第三方开发者申请表。\n2. 准备联系邮箱、项目名称和说明、项目 / GitHub 地址，以及预计如何使用 API；按官方要求确认开发者条款并提交审核。\n3. 审核通过后，按通知或开发者控制台指引获取完整 API Key。Key 不是账号密码，也不是 Mod / 文件 ID；提交申请不会立即获得 Key。\n4. 将 Key 粘贴到上方，点击“保存并验证 Key”；验证通过后返回下载页重新查询。',
              style: TextStyle(fontSize: 12, height: 1.8),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                TextButton(
                  onPressed: () => action(
                    context,
                    () => openWeb(
                      'https://support.curseforge.com/support/solutions/articles/9000208346-about-the-curseforge-api-and-how-to-apply-for-a-key',
                    ),
                  ),
                  child: const Text('官方申请说明'),
                ),
                TextButton(
                  onPressed: () => action(
                    context,
                    () => openWeb('https://console.curseforge.com/'),
                  ),
                  child: const Text('开发者控制台'),
                ),
              ],
            ),
            const InfoStrip(
              '未获批或没有 Key 时可使用 Modrinth。Key 无效或权限不足会明确报错；作者禁止第三方下载的文件仍需在官网手动下载后导入。',
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
          TextButton.icon(
            onPressed: widget.onManageRoots ?? () => addRoot(context, s),
            icon: const Icon(Icons.folder_copy_outlined, size: 18),
            label: const Text('管理游戏目录'),
          ),
        ]),
        const SizedBox(height: 18),
        section(
          '关于 MC Download',
          '由第三方独立制作的 Flutter 下载与文件管理工具，与 PCL / HMCL 官方无关联。',
          [
            if (s.settings.usesBundledCurseForgeKey)
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text(
                  'CurseForge：使用发行版内置授权',
                  style: TextStyle(fontSize: 12),
                ),
              ),
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
                applicationVersion: appVersion,
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
