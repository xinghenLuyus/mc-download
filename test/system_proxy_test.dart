import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:mc_download/core/models.dart';
import 'package:mc_download/core/network.dart';
import 'package:mc_download/core/system_proxy.dart';

void main() {
  test('Windows proxy lists select the URL protocol and retain failover', () {
    final https = Uri.parse('https://example.com/a');
    expect(
      systemProxyRoute(https, 'http=one:80;https=two:8080', ''),
      'PROXY two:8080',
    );
    expect(
      systemProxyRoute(https, 'http=one:80 https=two:8080', ''),
      'PROXY two:8080',
    );
    expect(
      systemProxyRoute(https, 'PROXY first:80; PROXY second:81; DIRECT', ''),
      'PROXY first:80; PROXY second:81; DIRECT',
    );
    expect(
      systemProxyRoute(https, 'one:80 two:81', ''),
      'PROXY one:80; PROXY two:81',
    );
    expect(systemProxyRoute(https, 'http=one:80', ''), 'DIRECT');
    expect(systemProxyRoute(https, '[::1]:7890', ''), 'PROXY [::1]:7890');
    expect(systemProxyRoute(https, 'localhost', ''), 'PROXY localhost:80');
    for (final invalid in [
      'socks://host:1080',
      'SOCKS5 host:1080',
      'https://host:443',
      'http://user:pass@host:80',
      'http://host:0',
      'http://host:70000',
      'http://host:80/path',
    ]) {
      expect(
        () => systemProxyRoute(https, invalid, ''),
        throwsA(isA<HttpException>()),
      );
    }
  });

  test('Windows bypass rules match hosts, local names, schemes and ports', () {
    for (final (url, bypass) in [
      ('https://files.example.com/a', '*.example.com'),
      ('https://EXAMPLE.com/a', 'example.com:443'),
      ('https://intranet/a', '<local>'),
      ('https://example.com/a', 'https://example.com'),
      ('https://127.0.0.1/a', '127.*'),
    ]) {
      expect(systemProxyRoute(Uri.parse(url), 'proxy:80', bypass), 'DIRECT');
    }
    expect(
      systemProxyRoute(
        Uri.parse('https://example.com'),
        'proxy:80',
        'http://example.com;example.com:80;<local>',
      ),
      'PROXY proxy:80',
    );
  });

  test(
    'PAC cache varies by full URL and static proxy cache reuses origins',
    () async {
      var calls = 0;
      final settings = AppSettings()..proxyMode = ProxyMode.system;
      final network = NetworkService(
        settings,
        systemProxyResolver: (uri) async {
          calls++;
          return SystemProxyResult(
            uri.path == '/direct' ? 'DIRECT' : 'PROXY local:80',
            perUrl: true,
          );
        },
      );
      expect(
        await network.proxyFor(Uri.parse('https://example.com/direct')),
        'DIRECT',
      );
      expect(
        await network.proxyFor(Uri.parse('https://example.com/proxy')),
        'PROXY local:80',
      );
      await network.proxyFor(Uri.parse('https://example.com/direct#fragment'));
      expect(calls, 2);
      network.close();
      calls = 0;
      final fixed = NetworkService(
        settings,
        systemProxyResolver: (_) async {
          calls++;
          return const SystemProxyResult('PROXY local:80');
        },
      );
      await fixed.proxyFor(Uri.parse('https://example.com/a'));
      await fixed.proxyFor(Uri.parse('https://example.com/b'));
      expect(calls, 1);
      fixed.clearProxyCache();
      await fixed.proxyFor(Uri.parse('https://example.com/b'));
      expect(calls, 2);
      fixed.close();
    },
  );

  test(
    'concurrent lookups share work and direct/manual modes skip the OS',
    () async {
      final pending = Completer<SystemProxyResult>();
      var calls = 0;
      final settings = AppSettings()..proxyMode = ProxyMode.system;
      final network = NetworkService(
        settings,
        systemProxyResolver: (_) {
          calls++;
          return pending.future;
        },
      );
      final url = Uri.parse('https://example.com/a');
      final first = network.proxyFor(url), second = network.proxyFor(url);
      pending.complete(const SystemProxyResult('DIRECT'));
      expect(await Future.wait([first, second]), ['DIRECT', 'DIRECT']);
      expect(calls, 1);
      settings.proxyMode = ProxyMode.direct;
      expect(await network.proxyFor(url), 'DIRECT');
      settings.proxyMode = ProxyMode.manual;
      settings.proxyUrl = 'http://localhost:7890';
      expect(await network.proxyFor(url), 'PROXY localhost:7890');
      expect(calls, 1);
      network.close();
    },
  );

  test(
    'native Windows system proxy can be read without a shell process',
    () async {
      final result = await resolveSystemProxy(
        Uri.parse('https://example.com/'),
      );
      expect(
        result.route,
        matches(r'^(DIRECT|PROXY [^\s]+:\d+)(; (DIRECT|PROXY [^\s]+:\d+))*$'),
      );
    },
    skip: !Platform.isWindows,
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
