import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import '../app_state.dart';
import '../core/modpacks.dart';
import '../core/network.dart';
import '../core/repository.dart';
import 'common.dart';

enum ModpackImportAction { tasks, settings }

class ModpackImportPage extends StatefulWidget {
  final AppState state;
  final String file;
  final bool canConfigureKey;
  const ModpackImportPage({
    super.key,
    required this.state,
    required this.file,
    this.canConfigureKey = false,
  });
  @override
  State<ModpackImportPage> createState() => _ModpackImportPageState();
}

class _ModpackImportPageState extends State<ModpackImportPage> {
  final form = GlobalKey<FormState>();
  final name = TextEditingController();
  PackInfo? info;
  final Set<String> optionalFiles = {};
  bool preparing = true, starting = false, needsKey = false;
  String? error;
  AppState get s => widget.state;
  @override
  void initState() {
    super.initState();
    prepare();
  }

  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  Future<void> prepare() async {
    setState(() {
      preparing = true;
      error = null;
      needsKey = false;
    });
    try {
      if (![
        '.zip',
        '.mrpack',
      ].contains(p.extension(widget.file).toLowerCase())) {
        throw const FormatException('请选择 .zip 或 .mrpack 整合包');
      }
      final pack = await s.packs.prepareImport(widget.file);
      if (!mounted) return;
      info = pack;
      var suggested = pack.name.replaceAll(RegExp(r'[<>:"/\\|?*]'), '-').trim();
      try {
        validateId(suggested);
      } catch (_) {
        suggested = 'Minecraft-${pack.game}';
      }
      name.text = suggested;
      s.packs.checkAccess(pack);
    } catch (e) {
      if (mounted) {
        error = '$e';
        needsKey = e is CurseForgeAccessException;
      }
    } finally {
      if (mounted) setState(() => preparing = false);
    }
  }

  Future<void> start() async {
    if (preparing ||
        starting ||
        info == null ||
        !form.currentState!.validate()) {
      return;
    }
    setState(() {
      starting = true;
      error = null;
    });
    try {
      final pack = info!;
      s.packs.checkAccess(pack, optionalFiles: optionalFiles);
      s.packs.validateManifest(pack, optionalFiles: optionalFiles);
      final root = s.requireRoot();
      final id = name.text.trim();
      final target = safeChild(root, 'versions/$id');
      if (await FileSystemEntity.type(target, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw StateError('版本 $id 已存在，请使用其他安装名称');
      }
      if (!mounted) return;
      s.enqueue('安装整合包 $id', 'pack', {
        'file': pack.file,
        'root': root,
        'id': id,
        'optionalFiles': optionalFiles.toList(),
      });
      Navigator.pop(context, ModpackImportAction.tasks);
    } catch (e) {
      if (mounted) {
        setState(() {
          starting = false;
          error = '$e';
          needsKey = e is CurseForgeAccessException;
        });
      }
    }
  }

  Widget detail(String title, String text) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 96,
          child: Text(title, style: Theme.of(context).textTheme.bodySmall),
        ),
        Expanded(child: Text(text)),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: s,
    builder: (context, _) => PopScope(
      canPop: !starting,
      child: Scaffold(
        appBar: AppBar(
          leading: BackButton(
            onPressed: starting ? null : () => Navigator.pop(context),
          ),
          title: const Text('安装整合包'),
          backgroundColor: Theme.of(context).cardTheme.color,
          scrolledUnderElevation: 0,
        ),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 860),
            child: Column(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const SectionHeading(
                          '安装本地整合包',
                          '确认整合包信息和安装位置，随后自动下载游戏、加载器及所需资源。',
                          compact: true,
                        ),
                        Text(
                          p.windows.basename(widget.file),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const SizedBox(height: 16),
                        if (preparing)
                          const Card(
                            child: Padding(
                              padding: EdgeInsets.all(24),
                              child: Column(
                                children: [
                                  LinearProgressIndicator(),
                                  SizedBox(height: 16),
                                  Text('正在读取并检查整合包…'),
                                ],
                              ),
                            ),
                          ),
                        if (!preparing && info != null) ...[
                          Card(
                            child: Padding(
                              padding: const EdgeInsets.all(18),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    info!.name,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.titleLarge,
                                  ),
                                  const SizedBox(height: 12),
                                  detail('整合包格式', info!.format),
                                  detail('Minecraft', info!.game),
                                  detail(
                                    '加载器',
                                    info!.loader.isEmpty
                                        ? '原版'
                                        : '${info!.loader} ${info!.loaderVersion}',
                                  ),
                                ],
                              ),
                            ),
                          ),
                          if (info!.optionalFiles.isNotEmpty)
                            ExpansionTile(
                              tilePadding: EdgeInsets.zero,
                              title: Text(
                                '可选文件（已选 ${optionalFiles.length} / ${info!.optionalFiles.length}）',
                              ),
                              subtitle: const Text(
                                '按需安装，不选择也可继续',
                                style: TextStyle(fontSize: 12),
                              ),
                              children: [
                                for (final file in info!.optionalFiles)
                                  CheckboxListTile(
                                    dense: true,
                                    title: Text(file.name),
                                    value: optionalFiles.contains(file.id),
                                    onChanged: starting
                                        ? null
                                        : (selected) => setState(() {
                                            if (selected == true) {
                                              optionalFiles.add(file.id);
                                            } else {
                                              optionalFiles.remove(file.id);
                                            }
                                            error = null;
                                            needsKey = false;
                                            try {
                                              s.packs.checkAccess(
                                                info!,
                                                optionalFiles: optionalFiles,
                                              );
                                            } catch (e) {
                                              error = '$e';
                                              needsKey =
                                                  e is CurseForgeAccessException;
                                            }
                                          }),
                                  ),
                              ],
                            ),
                          const SizedBox(height: 20),
                          Form(
                            key: form,
                            child: TextFormField(
                              controller: name,
                              enabled: !starting,
                              autovalidateMode:
                                  AutovalidateMode.onUserInteraction,
                              decoration: const InputDecoration(
                                labelText: '安装名称',
                                helperText: '作为版本文件夹名称，不覆盖已有版本',
                              ),
                              validator: (value) {
                                try {
                                  validateId((value ?? '').trim());
                                  return null;
                                } on FormatException catch (e) {
                                  return e.message;
                                }
                              },
                            ),
                          ),
                          const SizedBox(height: 20),
                          Row(
                            children: [
                              Expanded(
                                child: DropdownButtonFormField<String>(
                                  key: ValueKey(s.settings.selectedRoot),
                                  initialValue: s.settings.selectedRoot,
                                  isExpanded: true,
                                  decoration: const InputDecoration(
                                    labelText: '游戏目录',
                                    hintText: '请选择或新建游戏目录',
                                  ),
                                  items: s.settings.roots
                                      .map(
                                        (root) => DropdownMenuItem(
                                          value: root,
                                          child: Text(
                                            root,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      )
                                      .toList(),
                                  onChanged: starting
                                      ? null
                                      : (root) {
                                          if (root != null) {
                                            action(
                                              context,
                                              () => s.selectRoot(root),
                                            );
                                          }
                                        },
                                ),
                              ),
                              const SizedBox(width: 8),
                              TextButton.icon(
                                onPressed: starting
                                    ? null
                                    : () => addRoot(context, s),
                                icon: const Icon(Icons.add, size: 18),
                                label: const Text('添加目录'),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          const InfoStrip(
                            '整合包使用版本隔离，模组、配置和存档保存在 versions/<安装名称>/ 中。资源按整合包清单的原始来源下载。',
                          ),
                        ],
                        if (error != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 16),
                            child: InfoStrip(
                              error!,
                              warning: true,
                              action:
                                  needsKey &&
                                      widget.canConfigureKey &&
                                      !s.settings.usesBundledCurseForgeKey
                                  ? TextButton(
                                      onPressed: () => Navigator.pop(
                                        context,
                                        ModpackImportAction.settings,
                                      ),
                                      child: const Text('配置 CurseForge Key'),
                                    )
                                  : null,
                            ),
                          ),
                        if (!preparing && info == null)
                          TextButton(
                            onPressed: prepare,
                            child: const Text('重新读取'),
                          ),
                        if (starting)
                          const Padding(
                            padding: EdgeInsets.only(top: 16),
                            child: LinearProgressIndicator(),
                          ),
                      ],
                    ),
                  ),
                ),
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 16,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: starting
                            ? null
                            : () => Navigator.pop(context),
                        child: const Text('取消'),
                      ),
                      const SizedBox(width: 12),
                      FilledButton.icon(
                        onPressed:
                            preparing || starting || info == null || needsKey
                            ? null
                            : s.settings.selectedRoot == null
                            ? () => addRoot(context, s)
                            : start,
                        icon: const Icon(Icons.download_outlined, size: 18),
                        label: Text(
                          s.settings.selectedRoot == null ? '选择游戏目录' : '开始安装',
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
