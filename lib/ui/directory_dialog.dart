import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../app_state.dart';
import '../core/discovery.dart';
import '../core/repository.dart';

class DirectoryImportDialog extends StatefulWidget {
  final AppState state;
  const DirectoryImportDialog({super.key, required this.state});
  @override
  State<DirectoryImportDialog> createState() => _DirectoryImportDialogState();
}

class _DirectoryImportDialogState extends State<DirectoryImportDialog> {
  List<GameDirectoryCandidate> candidates = [];
  final Set<String> selected = {};
  bool loading = false, limited = false;
  String? selectedFolder, error;
  List<String> warnings = [];
  int generation = 0;
  AppState get state => widget.state;
  @override
  void initState() {
    super.initState();
    defaults();
  }

  @override
  void dispose() {
    generation++;
    super.dispose();
  }

  Future<void> run(Future<DirectorySearchResult> Function(int) work) async {
    final token = ++generation;
    setState(() {
      loading = true;
      error = null;
      warnings = [];
    });
    try {
      final result = await work(token);
      if (!mounted || token != generation) return;
      setState(() {
        candidates = result.directories;
        limited = result.limited;
        warnings = result.warnings;
        selected
          ..clear()
          ..addAll(candidates.map((c) => c.path));
      });
    } catch (e) {
      if (mounted && token == generation) setState(() => error = '$e');
    } finally {
      if (mounted && token == generation) setState(() => loading = false);
    }
  }

  Future<void> defaults() => run(
    (_) async => DirectorySearchResult(
      await state.discovery.defaults(
        executableDirectory: p.dirname(state.dataPath),
      ),
    ),
  );

  Future<void> chooseLauncher({bool file = false}) async {
    String? path;
    try {
      if (file) {
        final result = await FilePicker.platform.pickFiles(
          dialogTitle: '选择启动器（只查找目录，不运行）',
          type: FileType.custom,
          allowedExtensions: ['exe', 'jar'],
        );
        path = result?.files.single.path;
      } else {
        path = await FilePicker.platform.getDirectoryPath(
          dialogTitle: '选择启动器所在目录，也可以直接选择 .minecraft',
        );
      }
      if (path == null || !mounted) return;
      selectedFolder = file ? p.dirname(path) : path;
      final chosen = path;
      await run(
        (token) => state.discovery.fromLauncher(
          chosen,
          cancelled: () => !mounted || token != generation,
        ),
      );
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  Future<void> import(Iterable<String> paths) async {
    setState(() => loading = true);
    try {
      await state.addRoots(paths);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() {
          loading = false;
          error = '$e';
        });
      }
    }
  }

  Future<void> direct() async {
    try {
      final path = await FilePicker.platform.getDirectoryPath(
        dialogTitle: '选择已有游戏目录（也可选择空文件夹）',
      );
      if (path != null && mounted) await import([path]);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  Future<void> create() async {
    final root = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => NewGameDirectoryDialog(
        state: state,
        initialParent: selectedFolder ?? p.dirname(state.dataPath),
      ),
    );
    if (root != null && mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('查找并导入游戏目录'),
    content: SizedBox(
      width: 720,
      height: 460,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '自动检测官方目录，或选择 PCL / HMCL 所在文件夹查找 .minecraft。只读取目录和游戏路径配置，不复制游戏文件。',
            style: TextStyle(fontSize: 12, height: 1.7),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: loading ? null : defaults,
                icon: const Icon(Icons.travel_explore, size: 18),
                label: const Text('检测官方目录'),
              ),
              OutlinedButton.icon(
                onPressed: loading ? null : () => chooseLauncher(),
                icon: const Icon(Icons.folder_open, size: 18),
                label: const Text('选择启动器目录'),
              ),
              TextButton(
                onPressed: loading ? null : () => chooseLauncher(file: true),
                child: const Text('选择启动器文件'),
              ),
            ],
          ),
          if (selectedFolder != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                '查找位置：$selectedFolder',
                style: Theme.of(context).textTheme.bodySmall,
                maxLines: 2,
              ),
            ),
          const SizedBox(height: 12),
          if (loading) const LinearProgressIndicator(),
          if (error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (limited)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text(
                '已达到搜索范围或时间上限，可选择更接近游戏的子目录继续查找。',
                style: TextStyle(fontSize: 12),
              ),
            ),
          if (warnings.isNotEmpty)
            Text(
              warnings.take(3).join('\n'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          Expanded(
            child: candidates.isEmpty
                ? Center(
                    child: Text(
                      loading
                          ? '正在查找…'
                          : '没有找到已有游戏目录。可选择其他启动器目录，\n或直接选择游戏目录来新建安装。',
                      textAlign: TextAlign.center,
                    ),
                  )
                : ListView.builder(
                    itemCount: candidates.length,
                    itemBuilder: (_, index) {
                      final candidate = candidates[index];
                      final existing = state.settings.roots.any(
                        (r) =>
                            state.discovery.identity(r) ==
                            state.discovery.identity(candidate.path),
                      );
                      return CheckboxListTile(
                        value: selected.contains(candidate.path),
                        dense: true,
                        controlAffinity: ListTileControlAffinity.leading,
                        onChanged: loading
                            ? null
                            : (value) => setState(() {
                                if (value == true) {
                                  selected.add(candidate.path);
                                } else {
                                  selected.remove(candidate.path);
                                }
                              }),
                        title: Text(
                          candidate.path,
                          style: const TextStyle(fontSize: 12),
                        ),
                        subtitle: Text(
                          '${candidate.source}${existing ? ' · 已添加' : ''}${candidate.hasVersions ? ' · 含版本目录' : ' · 尚未安装版本'}',
                          style: const TextStyle(fontSize: 11),
                        ),
                      );
                    },
                  ),
          ),
          Wrap(
            spacing: 8,
            children: [
              TextButton.icon(
                onPressed: loading ? null : direct,
                icon: const Icon(Icons.folder_open, size: 18),
                label: const Text('直接选择游戏目录'),
              ),
              TextButton.icon(
                onPressed: loading ? null : create,
                icon: const Icon(Icons.create_new_folder_outlined, size: 18),
                label: const Text('新建空目录'),
              ),
            ],
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      if (selectedFolder != null && candidates.isEmpty)
        TextButton(
          onPressed: loading
              ? null
              : () => import([p.join(selectedFolder!, '.minecraft')]),
          child: const Text('使用此位置的 .minecraft'),
        ),
      FilledButton(
        onPressed: loading || selected.isEmpty
            ? null
            : () => import(selected.toList()),
        child: Text('导入选中（${selected.length}）'),
      ),
    ],
  );
}

class NewGameDirectoryDialog extends StatefulWidget {
  final AppState state;
  final String initialParent;
  const NewGameDirectoryDialog({
    super.key,
    required this.state,
    required this.initialParent,
  });
  @override
  State<NewGameDirectoryDialog> createState() => _NewGameDirectoryDialogState();
}

class _NewGameDirectoryDialogState extends State<NewGameDirectoryDialog> {
  final form = GlobalKey<FormState>();
  late final parent = TextEditingController(text: widget.initialParent);
  final name = TextEditingController(text: '.minecraft');
  bool busy = false;
  String? error;
  @override
  void dispose() {
    parent.dispose();
    name.dispose();
    super.dispose();
  }

  Future<void> chooseParent() async {
    try {
      final selected = await FilePicker.platform.getDirectoryPath(
        dialogTitle: '选择新游戏目录的父文件夹',
      );
      if (selected != null && mounted) setState(() => parent.text = selected);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  Future<void> submit() async {
    if (busy || !form.currentState!.validate()) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final root = await widget.state.createRoot(parent.text.trim(), name.text);
      if (mounted) Navigator.pop(context, root);
    } catch (e) {
      if (mounted) {
        setState(() {
          busy = false;
          error = '无法创建目录：$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: AlertDialog(
      title: const Text('新建空目录'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Form(
            key: form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextFormField(
                  controller: parent,
                  enabled: !busy,
                  onChanged: (_) => setState(() {}),
                  validator: (value) =>
                      value == null || !p.isAbsolute(value.trim())
                      ? '请输入绝对路径，或选择父文件夹'
                      : null,
                  decoration: InputDecoration(
                    labelText: '父目录',
                    suffixIcon: IconButton(
                      tooltip: '选择父目录',
                      onPressed: busy ? null : chooseParent,
                      icon: const Icon(Icons.folder_open),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: name,
                  enabled: !busy,
                  autofocus: true,
                  onChanged: (_) => setState(() {}),
                  onFieldSubmitted: (_) => submit(),
                  validator: (value) {
                    try {
                      validateId(value ?? '', label: '文件夹名称');
                      return null;
                    } on FormatException catch (e) {
                      return e.message;
                    }
                  },
                  decoration: const InputDecoration(labelText: '文件夹名称'),
                ),
                const SizedBox(height: 14),
                SelectableText(
                  '创建位置：${p.join(parent.text.trim(), name.text)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                const Text(
                  '创建后自动选为游戏目录，游戏文件将在安装时下载到这里。',
                  style: TextStyle(fontSize: 12),
                ),
                if (busy)
                  const Padding(
                    padding: EdgeInsets.only(top: 12),
                    child: LinearProgressIndicator(),
                  ),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: busy ? null : submit,
          child: const Text('创建并使用'),
        ),
      ],
    ),
  );
}
