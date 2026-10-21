import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:mc_download/app_state.dart';
import 'package:mc_download/core/discovery.dart';
import 'package:mc_download/core/models.dart';
import 'package:mc_download/main.dart';
import 'package:mc_download/ui/directory_dialog.dart';
import 'package:mc_download/ui/download_page.dart';

class NoDiscovery extends GameDirectoryDiscovery {
  @override
  Future<List<GameDirectoryCandidate>> defaults({
    String? executableDirectory,
  }) async => [];
}

void main() {
  late Directory temp;
  late AppState state;
  bool closed = false;
  Future<AppState> open() async {
    final result = AppState(
      p.join(temp.path, '.mcdownload'),
      discovery: NoDiscovery(),
      javaDiscovery: () async => [],
    );
    await result.initialize(remote: false);
    return result;
  }

  setUp(() async {
    closed = false;
    temp = await Directory.systemTemp.createTemp('mcd-directory-');
    state = await open();
  });
  tearDown(() async {
    if (closed) return;
    await state.save();
    state.dispose();
    await temp.delete(recursive: true);
  });

  test(
    'empty roots are created, registered, persisted and selected without game metadata',
    () async {
      final root = await state.createRoot(temp.path, '.minecraft');
      expect(await Directory(root).exists(), isTrue);
      expect(await Directory(root).list().toList(), isEmpty);
      expect(state.settings.selectedRoot, root);
      expect(state.localVersions, isEmpty);
      expect(state.scanError, isNull);
      final nested = p.join(temp.path, 'another', '.minecraft');
      await state.addRoot(nested);
      expect(await Directory(nested).exists(), isTrue);
      await state.addRoot(p.join(root, '.'));
      expect(state.settings.roots.length, 2);
      expect(state.settings.selectedRoot, root);
      final restored = await open();
      try {
        expect(restored.settings.roots, state.settings.roots);
        expect(restored.settings.selectedRoot, root);
        expect(restored.localVersions, isEmpty);
      } finally {
        restored.dispose();
      }
    },
  );

  test(
    'invalid names and collisions preserve files and root selection',
    () async {
      final root = await state.createRoot(temp.path, 'valid');
      final userFile = File(p.join(root, 'options.txt'));
      await userFile.writeAsString('keep');
      for (final name in ['', '..', 'CON', 'bad/name', 'bad.', 'bad ']) {
        await expectLater(
          state.createRoot(temp.path, name),
          throwsFormatException,
        );
      }
      await expectLater(
        state.createRoot(temp.path, 'valid'),
        throwsA(isA<FileSystemException>()),
      );
      await expectLater(
        state.createRoot(p.join(temp.path, 'missing'), 'new'),
        throwsA(isA<FileSystemException>()),
      );
      await expectLater(
        state.addRoot(userFile.path),
        throwsA(isA<FileSystemException>()),
      );
      expect(await userFile.readAsString(), 'keep');
      expect(state.settings.roots, [root]);
      expect(state.settings.selectedRoot, root);
    },
  );

  test(
    'per-root installation defaults persist, fall back to global and never rewrite versions',
    () async {
      final first = await state.createRoot(temp.path, 'one');
      final second = await state.createRoot(temp.path, 'two');
      final manifest = File(
        p.join(first, 'versions', 'existing', 'existing.json'),
      );
      await manifest.parent.create(recursive: true);
      await manifest.writeAsString('{"id":"existing","type":"release"}');
      await state.setRootIsolation(first, false);
      expect(state.settings.isolationFor(first), isFalse);
      expect(state.settings.isolationFor(second), isTrue);
      final restored = await open();
      try {
        expect(restored.settings.isolationFor(first), isFalse);
      } finally {
        restored.dispose();
      }
      await state.setRootIsolation(first, null);
      expect(state.settings.isolationFor(first), isTrue);
      state.settings.isolate = false;
      expect(state.settings.isolationFor(first), isFalse);
      await state.setRootIsolation(second, true);
      expect(state.settings.isolationFor(second), isTrue);
      await state.removeRoot(first);
      expect(
        await manifest.readAsString(),
        '{"id":"existing","type":"release"}',
      );
      expect(await Directory(first).exists(), isTrue);
      expect(state.settings.selectedRoot, second);
      expect(state.settings.rootIsolation.containsKey(first), isFalse);
    },
  );

  testWidgets(
    'empty directory onboarding coordinates creation, management, browsing and install defaults',
    (tester) async {
      tester.view.physicalSize = const Size(1120, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      state.remoteVersions = [
        GameVersion.fromJson({
          'id': '1.20.1',
          'url': 'https://example.invalid',
        }),
      ];
      await tester.pumpWidget(DownloadApp(state: state));
      await tester.pumpAndSettle();
      await tester.tap(find.text('添加目录'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('新建空目录'));
      await tester.pumpAndSettle();
      expect(find.byType(NewGameDirectoryDialog), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextFormField, '父目录'),
        temp.path,
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, '文件夹名称'),
        'Games',
      );
      await tester.runAsync(() async {
        await tester.tap(find.text('创建并使用'));
        // Wait for the filesystem operation and registration, outside the fake clock.
        for (var i = 0; i < 100 && state.settings.selectedRoot == null; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        await state.save();
        await state.scan();
      });
      await tester.pumpAndSettle();
      expect(find.byType(DirectoryImportDialog), findsNothing);
      expect(find.byType(NewGameDirectoryDialog), findsNothing);
      expect(
        state.settings.selectedRoot,
        p.join(temp.resolveSymbolicLinksSync(), 'Games'),
      );
      await tester.tap(find.text('版本管理'));
      await tester.pumpAndSettle();
      expect(find.text('当前目录尚未安装游戏'), findsOneWidget);
      await tester.tap(find.text('管理游戏目录'));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      expect(find.text('此目录的安装默认值'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        tester
            .widget<DropdownButtonFormField<String>>(
              find.byType(DropdownButtonFormField<String>),
            )
            .onChanged!('shared');
        await state.save();
      });
      await tester.pumpAndSettle();
      expect(state.settings.isolationFor(state.requireRoot()), isFalse);
      await tester.tap(find.text('版本管理'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('安装第一个版本'));
      await tester.pumpAndSettle();
      expect(find.text('下载 Minecraft'), findsOneWidget);
      await tester.tap(find.text('安装').first);
      await tester.pumpAndSettle();
      expect(find.byType(InstallDialog), findsOneWidget);
      expect(
        tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
        isFalse,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        await state.save();
        state.dispose();
        await temp.delete(recursive: true);
        closed = true;
      });
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
