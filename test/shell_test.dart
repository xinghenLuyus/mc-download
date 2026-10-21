import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mc_download/app_state.dart';
import 'package:mc_download/core/models.dart';
import 'package:mc_download/main.dart';

void main() {
  testWidgets('desktop shell and settings render without layout errors', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    late Directory dir;
    late AppState state;
    await tester.runAsync(() async {
      final icons = FontLoader('MaterialIcons')
        ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await icons.load();
      final font = File('/System/Library/Fonts/STHeiti Light.ttc');
      if (font.existsSync()) {
        final loader = FontLoader('Microsoft YaHei UI')
          ..addFont(Future.value(ByteData.sublistView(font.readAsBytesSync())));
        await loader.load();
      }
      dir = await Directory.systemTemp.createTemp('mcd-shell-');
      state = AppState(dir.path);
      await state.initialize(remote: false);
    });
    state.remoteVersions =
        [
              '1.21.11',
              '1.21.10',
              '1.21.9',
              '1.21.8',
              '1.21.7',
              '1.21.6',
              '1.21.5',
              '1.21.4',
            ]
            .map(
              (id) => GameVersion.fromJson({
                'id': id,
                'url': 'https://example.invalid',
                'type': 'release',
                'releaseTime': '2026-10-01',
              }),
            )
            .toList();
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: DownloadApp(state: state),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('下载 Minecraft'), findsOneWidget);
    expect(tester.takeException(), isNull);
    if (Platform.environment['MCD_PREVIEW'] == '1') {
      await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final picture = await boundary.toImage();
        final bytes = await picture.toByteData(format: ui.ImageByteFormat.png);
        await Directory('orther/previews').create(recursive: true);
        await File(
          'orther/previews/preview.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
      });
    }
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    expect(find.text('保存设置'), findsOneWidget);
    expect(tester.takeException(), isNull);
    tester.view.physicalSize = const Size(1120, 720);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('添加目录'));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(find.text('选择启动器目录'), findsOneWidget);
    expect(find.text('检测官方目录'), findsOneWidget);
    expect(tester.takeException(), isNull);
    if (Platform.environment['MCD_PREVIEW'] == '1') {
      await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final picture = await boundary.toImage();
        final bytes = await picture.toByteData(format: ui.ImageByteFormat.png);
        await File(
          'orther/previews/directory-preview.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
      });
    }
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
    await tester.pump(const Duration(seconds: 2));
    await tester.runAsync(() => dir.delete(recursive: true));
  });
}
