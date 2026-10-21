import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../app_state.dart';
import 'common.dart';
import 'modpack_import_page.dart';

final _importing = Expando<bool>();

/// File picker, window drops and drops onto the portable EXE share this flow.
Future<void> importModpack(
  BuildContext context,
  AppState state, {
  String? file,
  required VoidCallback onTask,
  VoidCallback? onSettings,
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
      final result = await Navigator.of(context).push<ModpackImportAction>(
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (_) => ModpackImportPage(
            state: state,
            file: file!,
            canConfigureKey: onSettings != null,
          ),
        ),
      );
      if (!context.mounted) return;
      if (result == ModpackImportAction.tasks) onTask();
      if (result == ModpackImportAction.settings) onSettings?.call();
    });
  } finally {
    _importing[state] = false;
  }
}
