import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mc_download/app_state.dart';
import 'package:mc_download/core/archive_drop.dart';
import 'package:mc_download/core/discovery.dart';
import 'package:mc_download/core/modpacks.dart';
import 'package:mc_download/core/models.dart';
import 'package:mc_download/main.dart';

class EmptyDiscovery extends GameDirectoryDiscovery {
  @override
  Future<List<GameDirectoryCandidate>> defaults({
    String? executableDirectory,
  }) async => [];
}

class ImportFixturePacks extends ModpackService {
  final String cachedFile;
  String? source;
  Completer<void>? gate;
  ImportFixturePacks(super.installer, super.resources, this.cachedFile);
  @override
  Future<PackInfo> prepareImport(String file) async {
    source = file;
    await gate?.future;
    return PackInfo(
      file: cachedFile,
      prefix: '',
      format: 'Modrinth',
      name: 'Dropped pack',
      game: '1.20.1',
      loader: 'Fabric',
      loaderVersion: '0.16.9',
      manifest: {'files': []},
    );
  }
}

class ImportFixtureState extends AppState {
  ImportFixtureState(super.dataPath)
    : super(discovery: EmptyDiscovery(), javaDiscovery: () async => []);
  final queued = Completer<DownloadJob>();
  @override
  DownloadJob enqueue(String title, String kind, Json request) {
    final job = DownloadJob(
      id: 'fixture',
      title: title,
      kind: kind,
      request: request,
      status: JobStatus.paused,
    );
    jobs.add(job);
    queued.complete(job);
    return job;
  }
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'native drop channel passes archive paths and becomes ready before receiving events',
    () async {
      final received = <List<String>>[];
      var ready = false;
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        ArchiveDropBridge.channel,
        (call) async {
          ready = call.method == 'ready';
          return null;
        },
      );
      final bridge = ArchiveDropBridge((files) async {
        received.add(files);
      });
      await bridge.start();
      expect(ready, isTrue);
      const codec = StandardMethodCodec();
      final reply = Completer<ByteData?>();
      binding.channelBuffers.push(
        ArchiveDropBridge.channel.name,
        codec.encodeMethodCall(
          const MethodCall('dropFiles', [r'C:\整合包\pack.mrpack']),
        ),
        reply.complete,
      );
      await reply.future;
      expect(received.single, [r'C:\整合包\pack.mrpack']);
      bridge.dispose();
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        ArchiveDropBridge.channel,
        null,
      );
    },
  );

  for (final confirm in [true, false]) {
    testWidgets(
      'dropping onto EXE ${confirm ? 'queues cached pack after confirmation' : 'does not install after cancellation'}',
      (tester) async {
        tester.view.physicalSize = const Size(1120, 720);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        late Directory directory;
        late ImportFixtureState state;
        late ImportFixturePacks packs;
        await tester.runAsync(() async {
          directory = await Directory.systemTemp.createTemp('mcd-import-ui-');
          state = ImportFixtureState('${directory.path}/.mcdownload');
          await state.initialize(remote: false);
          state.settings.roots = ['${directory.path}/game'];
          state.settings.selectedRoot = state.settings.roots.single;
          packs = ImportFixturePacks(
            state.installer,
            state.resources,
            '${directory.path}/.mcdownload/cache/snapshot.mrpack',
          );
          state.packs = packs;
        });
        await tester.pumpWidget(
          DownloadApp(
            state: state,
            initialArchives: const [r'C:\Downloads\pack.zip'],
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('安装本地整合包'), findsOneWidget);
        expect(find.textContaining('Fabric 0.16.9'), findsOneWidget);
        expect(find.text('安装名称'), findsOneWidget);
        expect(find.text('游戏目录'), findsOneWidget);
        expect(state.jobs, isEmpty);
        if (confirm) {
          await tester.enterText(
            find.widgetWithText(TextFormField, '安装名称'),
            'CON',
          );
          await tester.tap(find.text('开始安装'));
          await tester.pumpAndSettle();
          expect(state.jobs, isEmpty);
          expect(find.textContaining('不符合 Windows'), findsOneWidget);
          await tester.enterText(
            find.widgetWithText(TextFormField, '安装名称'),
            'Dropped pack',
          );
          await tester.runAsync(() async {
            await tester.tap(find.text('开始安装'));
            await state.queued.future;
          });
          await tester.pumpAndSettle();
          final job = state.jobs.single;
          expect(job.kind, 'pack');
          expect(job.request['file'], packs.cachedFile);
          expect(job.request['root'], state.settings.selectedRoot);
        } else {
          await tester.tap(find.text('取消'));
          await tester.pumpAndSettle();
          expect(state.jobs, isEmpty);
        }
        expect(packs.source, r'C:\Downloads\pack.zip');
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
  }
  testWidgets(
    'import page opens while parsing and cancellation ignores late results',
    (tester) async {
      tester.view.physicalSize = const Size(1120, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      late Directory directory;
      late ImportFixtureState state;
      late ImportFixturePacks packs;
      await tester.runAsync(() async {
        directory = await Directory.systemTemp.createTemp(
          'mcd-import-pending-',
        );
        state = ImportFixtureState('${directory.path}/.mcdownload');
        await state.initialize(remote: false);
        packs = ImportFixturePacks(
          state.installer,
          state.resources,
          'cached.zip',
        )..gate = Completer<void>();
        state.packs = packs;
      });
      await tester.pumpWidget(
        DownloadApp(state: state, initialArchives: const ['pack.zip']),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('正在读取并检查整合包…'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      packs.gate!.complete();
      await tester.pumpAndSettle();
      expect(find.text('安装本地整合包'), findsNothing);
      expect(state.jobs, isEmpty);
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
}
