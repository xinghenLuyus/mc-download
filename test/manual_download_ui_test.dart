import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mc_download/app_state.dart';
import 'package:mc_download/core/discovery.dart';
import 'package:mc_download/core/models.dart';
import 'package:mc_download/main.dart';

class RecoveryDiscovery extends GameDirectoryDiscovery {
  @override
  Future<List<GameDirectoryCandidate>> defaults({
    String? executableDirectory,
  }) async => [];
}

class RecoveryState extends AppState {
  RecoveryState(super.path)
    : super(discovery: RecoveryDiscovery(), javaDiscovery: () async => []);
  int resumed = 0;
  @override
  void retry(DownloadJob job) {
    resumed++;
  }
}

class RecoveryPicker extends FilePicker {
  final String file;
  RecoveryPicker(this.file);
  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = false,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async =>
      FilePickerResult([PlatformFile(name: 'manual.jar', path: file, size: 4)]);
}

void main() {
  testWidgets(
    'paused task exposes missing files, verifies selected files and resumes through the same task',
    (tester) async {
      tester.view.physicalSize = const Size(1120, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      late Directory temp;
      late RecoveryState state;
      late DownloadJob task;
      await tester.runAsync(() async {
        temp = await Directory.systemTemp.createTemp('mcd-recovery-ui-');
        state = RecoveryState('${temp.path}/.mcdownload');
        await state.initialize(remote: false);
        final source = File('${temp.path}/manual.jar');
        await source.writeAsString('data');
        FilePicker.platform = RecoveryPicker(source.path);
        task = DownloadJob(
          id: 'stable',
          title: '安装整合包',
          kind: 'pack',
          request: {
            'root': '${temp.path}/game',
            'missingFiles': [
              {
                'path': '.mcd-staging/stable/mods/manual.jar',
                'filename': 'manual.jar',
                'hash': sha1.convert([100, 97, 116, 97]).toString(),
                'algorithm': 'sha1',
                'size': 4,
                'website': 'https://www.curseforge.com/projects/8/files/9',
              },
            ],
          },
          status: JobStatus.paused,
        );
        state.jobs.add(task);
      });
      await tester.pumpWidget(DownloadApp(state: state));
      await tester.pumpAndSettle();
      await tester.tap(find.text('任务'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('补齐文件'));
      await tester.pumpAndSettle();
      expect(find.text('打开下载页面'), findsOneWidget);
      expect(find.text('补齐下载文件 · 剩余 1 个'), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.text('选择已下载文件'));
        for (
          var i = 0;
          i < 100 && asList(task.request['missingFiles']).isNotEmpty;
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        await state.save();
      });
      await tester.pumpAndSettle();
      expect(find.text('补齐下载文件 · 剩余 0 个'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('继续安装'));
      await tester.pumpAndSettle();
      expect(state.resumed, 1);
      expect(state.jobs.single, same(task));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        await state.save();
        state.dispose();
        await temp.delete(recursive: true);
      });
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
