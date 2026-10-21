import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/platform_support.dart';
import '../app_state.dart';
import 'directory_dialog.dart';

void message(BuildContext context, Object text, {bool error = false}) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text('$text'),
      backgroundColor: error ? Theme.of(context).colorScheme.error : null,
    ),
  );
}

Future<void> action(
  BuildContext context,
  Future<void> Function() callback,
) async {
  try {
    await callback();
  } catch (e) {
    if (context.mounted) message(context, e, error: true);
  }
}

Future<void> openFolder(String path) async {
  await Directory(path).create(recursive: true);
  await shellOpen(path);
}

Future<void> openWeb(String url) async {
  final uri = Uri.parse(url);
  if (!['https', 'http'].contains(uri.scheme)) {
    throw const FormatException('无效网页地址');
  }
  await shellOpen(uri.toString());
}

Future<String?> input(
  BuildContext context,
  String title, {
  String value = '',
  String? hint,
  String? note,
}) async {
  final controller = TextEditingController(text: value);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (note != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 18),
                child: Text(note),
              ),
            TextField(
              controller: controller,
              autofocus: true,
              decoration: InputDecoration(hintText: hint),
              onSubmitted: (v) {
                if (v.trim().isNotEmpty) {
                  Navigator.pop(ctx, v.trim());
                }
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            if (controller.text.trim().isNotEmpty) {
              Navigator.pop(ctx, controller.text.trim());
            }
          },
          child: const Text('确定'),
        ),
      ],
    ),
  );
}

Future<bool> confirm(BuildContext context, String title, String body) async =>
    await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SizedBox(width: 440, child: Text(body)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确定'),
          ),
        ],
      ),
    ) ??
    false;
Future<void> addRoot(BuildContext context, AppState state) async {
  await showDialog<void>(
    context: context,
    builder: (_) => DirectoryImportDialog(state: state),
  );
}

class SectionHeading extends StatelessWidget {
  final String title, subtitle;
  final Widget? trailing;
  final bool compact;
  const SectionHeading(
    this.title,
    this.subtitle, {
    super.key,
    this.trailing,
    this.compact = false,
  });
  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(bottom: compact ? 10 : 24),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: compact ? 20 : 25,
                  fontWeight: FontWeight.w700,
                ),
              ),
              SizedBox(height: compact ? 2 : 7),
              Text(
                subtitle,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        ?trailing,
      ],
    ),
  );
}

class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title, subtitle;
  final Widget? button;
  const EmptyState(
    this.title,
    this.subtitle, {
    super.key,
    this.icon = Icons.inbox_outlined,
    this.button,
  });
  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 48,
            color: Theme.of(context).colorScheme.primary.withValues(alpha: .65),
          ),
          const SizedBox(height: 20),
          Text(
            title,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 10),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          if (button != null)
            Padding(padding: const EdgeInsets.only(top: 20), child: button),
        ],
      ),
    ),
  );
}

class InfoStrip extends StatelessWidget {
  final String text;
  final bool warning;
  final Widget? action;
  const InfoStrip(this.text, {super.key, this.warning = false, this.action});
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    decoration: BoxDecoration(
      color: warning
          ? Theme.of(context).colorScheme.errorContainer.withValues(alpha: .45)
          : Theme.of(
              context,
            ).colorScheme.primaryContainer.withValues(alpha: .35),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Row(
      children: [
        Icon(
          warning ? Icons.info_outline : Icons.tips_and_updates_outlined,
          size: 18,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(text, style: const TextStyle(fontSize: 12, height: 1.6)),
        ),
        ?action,
      ],
    ),
  );
}

Widget smallChip(BuildContext context, String text) => Container(
  padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
  decoration: BoxDecoration(
    color: Theme.of(context).colorScheme.primary.withValues(alpha: .08),
    borderRadius: BorderRadius.circular(5),
  ),
  child: Text(
    text,
    style: TextStyle(
      color: Theme.of(context).colorScheme.primary,
      fontSize: 11,
    ),
  ),
);
Future<void> showLog(
  BuildContext context,
  String title,
  List<String> lines,
) async {
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 800,
        height: 460,
        child: SingleChildScrollView(
          child: SelectableText(
            lines.join('\n'),
            style: const TextStyle(
              fontFamily: 'Consolas',
              fontSize: 12,
              height: 1.6,
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () =>
              Clipboard.setData(ClipboardData(text: lines.join('\n'))),
          child: const Text('复制全部'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
}
