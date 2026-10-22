import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mc_download/app_state.dart';
import 'package:mc_download/core/app_version.dart';
import 'package:mc_download/core/discovery.dart';
import 'package:mc_download/core/models.dart';
import 'package:mc_download/core/network.dart';
import 'package:mc_download/core/release_credentials.dart';
import 'package:mc_download/ui/settings_page.dart';
import 'support/http_fixture.dart';

class CredentialDiscovery extends GameDirectoryDiscovery {
  @override
  Future<List<GameDirectoryCandidate>> defaults({
    String? executableDirectory,
  }) async => [];
}

void main() {
  const suppliedKey = 'ci-fixture-key';
  const payload = String.fromEnvironment('MC_DOWNLOAD_CF_PAYLOAD');
  const mask = String.fromEnvironment('MC_DOWNLOAD_CF_MASK');
  const bundled = appVersion != 'dev' && payload != '' && mask != '';

  test(
    'release payload decodes UTF-8 and rejects malformed or mismatched parts',
    () {
      final bytes = utf8.encode(r'测试-$key-with-symbols');
      final pad = List<int>.generate(bytes.length, (i) => (i * 17 + 29) % 256);
      final encoded = List<int>.generate(
        bytes.length,
        (i) => bytes[i] ^ pad[i],
      );
      expect(
        decodeReleaseCredential(base64Encode(encoded), base64Encode(pad)),
        r'测试-$key-with-symbols',
      );
      for (final parts in [
        ('!', 'AA=='),
        ('AA==', ''),
        ('', ''),
        ('AAE=', 'AA=='),
      ]) {
        expect(
          () => decodeReleaseCredential(parts.$1, parts.$2),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'bundled authorization is release-only and never persisted as settings',
    () {
      final settings = AppSettings()..curseKey = 'manual-key';
      expect(settings.usesBundledCurseForgeKey, bundled);
      expect(settings.effectiveCurseKey, bundled ? suppliedKey : 'manual-key');
      final saved = settings.toJson();
      expect(saved['curseKey'], bundled ? '' : 'manual-key');
      if (suppliedKey.isNotEmpty) {
        expect(jsonEncode(saved), isNot(contains(suppliedKey)));
      }
      final restored = AppSettings.fromJson({'curseKey': 'old-personal-key'});
      expect(restored.curseKey, bundled ? '' : 'old-personal-key');
      expect(
        restored.effectiveCurseKey,
        bundled ? suppliedKey : 'old-personal-key',
      );
      expect(
        AppSettings().defaultResourceProvider,
        bundled ? 'CurseForge' : 'Modrinth',
      );
    },
  );

  test(
    'requests use effective authorization without exposing it in audit or settings',
    () async {
      final settings = AppSettings()
        ..proxyMode = ProxyMode.direct
        ..curseKey = 'manual-key';
      final client = TestClient((_) => TestResponse(200, text: '{}'));
      final network = NetworkService(settings, clientFactory: () => client);
      try {
        await network.json(['https://api.curseforge.com/v1/games/432']);
        expect(
          client.requests.single.headers.value('x-api-key'),
          bundled ? suppliedKey : 'manual-key',
        );
        expect(
          network.audit.join(),
          isNot(contains(settings.effectiveCurseKey)),
        );
        try {
          network.checkCurseForgeStatus(
            Uri.parse('https://api.curseforge.com'),
            401,
          );
          fail('401 should throw');
        } on CurseForgeAccessException catch (e) {
          expect(e.message.contains('设置中'), !bundled);
        }
      } finally {
        network.close();
      }
    },
  );

  testWidgets(
    'only builds with bundled authorization hide the complete API key settings section',
    (tester) async {
      tester.view.physicalSize = const Size(1120, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      late Directory temp;
      late AppState state;
      await tester.runAsync(() async {
        temp = await Directory.systemTemp.createTemp('mcd-credential-ui-');
        state = AppState(
          temp.path,
          discovery: CredentialDiscovery(),
          javaDiscovery: () async => [],
        );
        await state.initialize(remote: false);
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SettingsPage(state: state, focusCurseForge: true),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('curseforge-api-key')),
        bundled ? findsNothing : findsOneWidget,
      );
      expect(find.text('保存并验证 Key'), bundled ? findsNothing : findsOneWidget);
      expect(
        find.text('如何申请 API Key'),
        bundled ? findsNothing : findsOneWidget,
      );
      expect(
        find.text('CurseForge：使用发行版内置授权'),
        bundled ? findsOneWidget : findsNothing,
      );
      expect(tester.takeException(), isNull);
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
