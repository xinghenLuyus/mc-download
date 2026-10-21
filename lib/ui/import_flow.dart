import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import '../app_state.dart';
import '../core/repository.dart';
import 'common.dart';

final _importing = Expando<bool>();

/// File picker, window drops and drops onto the portable EXE share this flow.
/// Detection never installs anything until the user confirms its target/name.
Future<void> importModpack(
  BuildContext context,
  AppState state, {
  String? file,
  required VoidCallback onTask,
}) async {
  if (_importing[state] == true) {
    message(context, '请先完成当前整合包导入');
    return;
  }
  _importing[state] = true;
  try {
    await action(context, () async {
      if (file == null) {
        final result = await FilePicker.platform.pickFiles(
          type: FileType.custom,
          allowedExtensions: ['zip', 'mrpack'],
        );
        file = result?.files.single.path;
      }
      if (file == null || !context.mounted) return;
      if (!['.zip', '.mrpack'].contains(p.extension(file!).toLowerCase())) {
        throw const FormatException('请拖入 .zip 或 .mrpack 整合包，普通游戏目录请手动添加');
      }
      final info = await state.packs.prepareImport(file!);
      state.packs.checkAccess(info);
      if (!context.mounted) return;
      if (state.settings.selectedRoot == null) {
        await addRoot(context, state);
        if (state.settings.selectedRoot == null || !context.mounted) return;
      }
      final root = state.requireRoot();
      var suggested = info.name.replaceAll(RegExp(r'[<>:"/\\|?*]'), '-').trim();
      try {
        validateId(suggested);
      } catch (_) {
        suggested = 'Minecraft-${info.game}';
      }
      final id = await input(
        context,
        '安装本地整合包',
        value: suggested,
        note:
            '${info.format} · Minecraft ${info.game} · ${info.loader.isEmpty ? '原版' : '${info.loader} ${info.loaderVersion}'}\n安装目录：$root\n确认后自动下载所需游戏、加载器和资源，使用版本隔离。',
      );
      if (id == null || !context.mounted) return;
      validateId(id);
      // The installer authoritatively checks the filesystem before downloading
      // and committing. Use the current scan here for immediate feedback.
      if (state.localVersions.any(
        (version) =>
            version.root == root &&
            version.id.toLowerCase() == id.toLowerCase(),
      )) {
        throw StateError('版本 $id 已存在，请使用其他安装名称');
      }
      state.enqueue('安装整合包 $id', 'pack', {
        'file': info.file,
        'root': root,
        'id': id,
      });
      if (context.mounted) onTask();
    });
  } finally {
    _importing[state] = false;
  }
}
