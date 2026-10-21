import 'dart:io';
import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mc_download/app_state.dart';
import 'package:mc_download/core/models.dart';
import 'package:mc_download/main.dart';
import 'package:mc_download/core/discovery.dart';
import 'package:mc_download/ui/directory_dialog.dart';
import 'package:mc_download/ui/settings_page.dart';

class ControlledDiscovery extends GameDirectoryDiscovery {
  Future<List<GameDirectoryCandidate>>? result;
  @override
  Future<List<GameDirectoryCandidate>> defaults({
    String? executableDirectory,
  }) => result ?? Future.value([]);
}

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
      if (Platform.environment['MCD_PREVIEW'] == '1' && font.existsSync()) {
        final loader = FontLoader('Microsoft YaHei UI')
          ..addFont(Future.value(ByteData.sublistView(font.readAsBytesSync())));
        await loader.load();
      }
      dir = await Directory.systemTemp.createTemp('mcd-shell-');
      state = AppState(dir.path, discovery: ControlledDiscovery());
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
    await tester.runAsync(() async {
      await state.save();
      state.dispose();
      await dir.delete(recursive: true);
    });
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets(
    'directory discovery can be cancelled while its result is pending',
    (tester) async {
      tester.view.physicalSize = const Size(1120, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final discovery = ControlledDiscovery();
      late Directory directory;
      late AppState state;
      await tester.runAsync(() async {
        directory = await Directory.systemTemp.createTemp('mcd-pending-scan-');
        state = AppState(directory.path, discovery: discovery);
        await state.initialize(remote: false);
      });
      final pending = Completer<List<GameDirectoryCandidate>>();
      discovery.result = pending.future;
      await tester.pumpWidget(DownloadApp(state: state));
      await tester.pumpAndSettle();
      await tester.tap(find.text('添加目录'));
      // A pending scan intentionally animates forever. Do not wait for animation
      // settlement before completing or cancelling the controlled operation.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(DirectoryImportDialog), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      pending.complete([]);
      await tester.pumpAndSettle();
      expect(find.byType(DirectoryImportDialog), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        await state.save();
        state.dispose();
        await directory.delete(recursive: true);
      });
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'CurseForge settings explains application and saves a personal key',
    (tester) async {
      tester.view.physicalSize = const Size(1120, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      late Directory directory;
      late AppState state;
      await tester.runAsync(() async {
        directory = await Directory.systemTemp.createTemp('mcd-key-settings-');
        state = AppState(directory.path, discovery: ControlledDiscovery());
        await state.initialize(remote: false);
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: SettingsPage(state: state)),
        ),
      );
      final keyField = find.byKey(const ValueKey('curseforge-api-key'));
      await tester.scrollUntilVisible(
        keyField,
        400,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(keyField, ' personal-fixture-key ');
      await tester.ensureVisible(find.text('保存 Key'));
      await tester.runAsync(() async {
        await tester.tap(find.text('保存 Key'));
        await state.save();
      });
      await tester.pumpAndSettle();
      expect(state.settings.curseKey, 'personal-fixture-key');
      expect(find.text('如何申请 API Key'), findsOneWidget);
      expect(find.text('官方申请说明'), findsOneWidget);
      expect(find.text('开发者控制台'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        await state.save();
        state.dispose();
        await directory.delete(recursive: true);
      });
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
  testWidgets('missing CurseForge key opens its settings field directly', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1120, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    late Directory directory;
    late AppState state;
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('mcd-key-navigation-');
      state = AppState(directory.path, discovery: ControlledDiscovery());
      await state.initialize(remote: false);
    });
    await tester.pumpWidget(DownloadApp(state: state));
    await tester.pumpAndSettle();
    await tester.tap(find.text('世界'));
    await tester.pumpAndSettle();
    expect(find.text('配置 CurseForge Key'), findsOneWidget);
    expect(state.network.audit, isEmpty);
    await tester.ensureVisible(find.text('配置 CurseForge Key'));
    await tester.tap(find.text('配置 CurseForge Key'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('curseforge-api-key')).hitTestable(),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() async {
      await state.save();
      state.dispose();
      await directory.delete(recursive: true);
    });
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}
