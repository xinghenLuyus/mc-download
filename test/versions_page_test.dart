import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mc_download/app_state.dart';
import 'package:mc_download/core/discovery.dart';
import 'package:mc_download/core/models.dart';
import 'package:mc_download/main.dart';

class NoGameDiscovery extends GameDirectoryDiscovery {
  @override
  Future<List<GameDirectoryCandidate>> defaults({
    String? executableDirectory,
  }) async => [];
}

class VersionFixtureState extends AppState {
  VersionFixtureState(super.dataPath)
    : super(discovery: NoGameDiscovery(), javaDiscovery: () async => []);
  final pending = <String, Completer<List<Json>>>{};
  final content = <String, List<Json>>{
    'mods': List.generate(
      353,
      (i) => {
        'name':
            'Mod-${i.toString().padLeft(3, '0')}.jar${i % 5 == 0 ? '.disabled' : ''}',
        'path': 'mods/Mod-$i.jar',
        'directory': false,
        'size': 1024 + i,
        'disabled': i % 5 == 0,
      },
    ),
    'config': [
      {
        'name': 'forge-client.toml',
        'path': 'config/forge-client.toml',
        'directory': false,
        'size': 100,
        'disabled': false,
      },
    ],
  };
  String? lastToggle;
  @override
  Future<List<Json>> contentFiles(LocalVersion version, String category) =>
      pending[category]?.future ?? Future.value(content[category] ?? []);
  @override
  Future<void> toggleFile(LocalVersion version, String file) async {
    lastToggle = file;
    final row = content['mods']!.firstWhere((r) => r['path'] == file);
    row['disabled'] = !row['disabled'];
    row['name'] = row['disabled']
        ? '${row['name']}.disabled'
        : (row['name'] as String).replaceFirst('.disabled', '');
  }
}

void main() {
  late Directory temporary;
  late VersionFixtureState state;
  Future<void> setup(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1120, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      temporary = await Directory.systemTemp.createTemp('mcd-version-ui-');
      state = VersionFixtureState('${temporary.path}/.mcdownload');
      await state.initialize(remote: false);
      if (Platform.environment['MCD_PREVIEW'] == '1') {
        final icons = FontLoader('MaterialIcons')
          ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
        await icons.load();
        final font = File('/System/Library/Fonts/STHeiti Light.ttc');
        if (font.existsSync()) {
          final loader = FontLoader('Microsoft YaHei UI')
            ..addFont(
              Future.value(ByteData.sublistView(await font.readAsBytes())),
            );
          await loader.load();
        }
      }
    });
    state.settings.roots = ['${temporary.path}/game'];
    state.settings.selectedRoot = state.settings.roots.single;
    state.localVersions = [
      for (final (id, loader, version) in [
        ('Create-Delight-Remake', 'Forge', '47.3.33'),
        ('Fabric-test', 'Fabric', '0.16.9'),
      ])
        LocalVersion(
          root: state.settings.selectedRoot!,
          id: id,
          game: '1.20.1',
          loader: loader,
          loaderVersion: version,
          components: {loader: version},
          contentPath: '${state.settings.selectedRoot}/versions/$id',
          manifest: {'id': id},
        ),
    ];
  }

  Future<void> cleanup(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() async {
      await state.save();
      state.dispose();
      await temporary.delete(recursive: true);
    });
  }

  testWidgets(
    'version manager prioritizes file list and supports filename, status and version search',
    (tester) async {
      await setup(tester);
      final preview = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: preview,
          child: DownloadApp(state: state),
        ),
      );
      await tester.tap(find.text('版本管理'));
      await tester.pumpAndSettle();
      final list = find.byKey(const ValueKey('version-content-list'));
      expect(tester.getSize(list).height, greaterThan(400));
      expect(find.textContaining('Forge 47.3.33'), findsWidgets);
      expect(find.text('Mod-007.jar').hitTestable(), findsOneWidget);
      expect(find.text('打开 Mod 文件夹'), findsOneWidget);
      expect(find.byTooltip('导入Mod'), findsOneWidget);
      final query = find.byKey(const ValueKey('content-search'));
      await tester.enterText(query, 'mod-042');
      await tester.pumpAndSettle();
      expect(find.text('1 / 353'), findsOneWidget);
      expect(find.text('Mod-042.jar'), findsOneWidget);
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(state.lastToggle, 'mods/Mod-42.jar');
      expect(find.text('Mod-042.jar.disabled'), findsOneWidget);
      final status = find.byType(DropdownButtonFormField<String>);
      await tester.tap(status);
      await tester.pumpAndSettle();
      await tester.tap(find.text('已启用').last);
      await tester.pumpAndSettle();
      expect(find.text('没有匹配文件'), findsOneWidget);
      await tester.tap(status);
      await tester.pumpAndSettle();
      await tester.tap(find.text('全部状态').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('清空搜索'));
      await tester.pumpAndSettle();
      final oldWidth = tester.getSize(list).width;
      await tester.tap(find.byTooltip('收起版本列表'));
      await tester.pumpAndSettle();
      expect(tester.getSize(list).width, greaterThan(oldWidth + 150));
      await tester.tap(find.byTooltip('展开版本列表'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('配置'));
      await tester.pumpAndSettle();
      expect(find.text('forge-client.toml'), findsOneWidget);
      expect(find.text('打开 配置 文件夹'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('version-search')),
        'Fabric',
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Fabric 0.16.9'), findsWidgets);
      expect(find.text('Forge 47.3.33'), findsNothing);
      await tester.enterText(find.byKey(const ValueKey('version-search')), '');
      await tester.pumpAndSettle();
      tester.view.physicalSize = const Size(960, 640);
      await tester.pumpAndSettle();
      expect(tester.getSize(list).height, greaterThan(300));
      expect(find.byTooltip('打开 Mod 文件夹'), findsOneWidget);
      expect(tester.takeException(), isNull);
      if (Platform.environment['MCD_PREVIEW'] == '1') {
        tester.view.physicalSize = const Size(1280, 800);
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          final boundary =
              preview.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final picture = await boundary.toImage();
          final bytes = await picture.toByteData(
            format: ui.ImageByteFormat.png,
          );
          await Directory('orther/previews').create(recursive: true);
          await File(
            'orther/previews/versions-preview.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
        });
      }
      await cleanup(tester);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets('late Mod results cannot replace the active config list', (
    tester,
  ) async {
    await setup(tester);
    final slow = Completer<List<Json>>();
    state.pending['mods'] = slow;
    await tester.pumpWidget(DownloadApp(state: state));
    await tester.tap(find.text('版本管理'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.text('配置'));
    await tester.pumpAndSettle();
    expect(find.text('forge-client.toml'), findsOneWidget);
    slow.complete(state.content['mods']);
    await tester.pumpAndSettle();
    expect(find.text('forge-client.toml'), findsOneWidget);
    expect(find.text('Mod-001.jar'), findsNothing);
    expect(tester.takeException(), isNull);
    await cleanup(tester);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}
