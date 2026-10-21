import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'app_version.dart';

class SystemProxyResult {
  final String route;
  final bool perUrl;
  const SystemProxyResult(this.route, {this.perUrl = false});
}

Future<SystemProxyResult> resolveSystemProxy(Uri uri) async {
  if (Platform.isWindows) {
    // PAC/WPAD may block. Resolve off the UI isolate, without a shell process.
    final target = uri.toString();
    return Isolate.run(() => _WinHttp().resolve(Uri.parse(target)));
  }
  final value =
      Platform.environment['HTTPS_PROXY'] ??
      Platform.environment['https_proxy'];
  final proxy = value == null ? null : Uri.tryParse(value);
  return SystemProxyResult(
    proxy?.scheme == 'http' ? 'PROXY ${proxy!.host}:${proxy.port}' : 'DIRECT',
  );
}

/// Interpret Windows' protocol-specific proxies and bypass list. PAC results
/// can also contain an ordered "PROXY ...; DIRECT" fallback list.
String systemProxyRoute(Uri uri, String proxy, String bypass) {
  final host = uri.host.toLowerCase();
  for (var rule in bypass.toLowerCase().split(RegExp(r'[;\s]+'))) {
    if (rule.isEmpty) continue;
    if (rule == '<local>') {
      if (!host.contains('.') && !host.contains(':')) return 'DIRECT';
      continue;
    }
    final schemeEnd = rule.indexOf('://');
    if (schemeEnd >= 0) {
      if (rule.substring(0, schemeEnd) != uri.scheme) continue;
      rule = rule.substring(schemeEnd + 3);
    }
    final pattern = RegExp.escape(
      rule,
    ).replaceAll(r'\*', '.*').replaceAll(r'\?', '.');
    final matcher = RegExp('^$pattern\$');
    if (matcher.hasMatch(host) || matcher.hasMatch('$host:${uri.port}')) {
      return 'DIRECT';
    }
  }
  if (proxy.trim().isEmpty) return 'DIRECT';
  final routes = <String>[];
  if (RegExp(
    r'(^|[;\s])(SOCKS[45]?|HTTPS)\s',
    caseSensitive: false,
  ).hasMatch(proxy)) {
    throw const HttpException('系统代理协议不受支持，请在设置中指定 HTTP 代理');
  }
  final entries = proxy
      .replaceAll(RegExp(r'\bPROXY\s+', caseSensitive: false), '')
      .split(RegExp(r'[;\s]+'));
  var selected = false;
  for (var entry in entries) {
    entry = entry.trim();
    if (entry.isEmpty) continue;
    final equals = entry.indexOf('=');
    if (equals >= 0) {
      if (entry.substring(0, equals).trim().toLowerCase() != uri.scheme) {
        continue;
      }
      entry = entry.substring(equals + 1).trim();
    }
    selected = true;
    if (entry.toUpperCase() == 'DIRECT') {
      routes.add('DIRECT');
      continue;
    }
    final server = Uri.tryParse(
      entry.contains('://') ? entry : 'http://$entry',
    );
    if (server == null ||
        server.scheme != 'http' ||
        server.host.isEmpty ||
        server.userInfo.isNotEmpty ||
        (server.path.isNotEmpty && server.path != '/') ||
        server.hasQuery ||
        server.hasFragment ||
        server.port < 1 ||
        server.port > 65535) {
      throw const HttpException('系统代理地址不受支持，请在设置中指定 HTTP 代理');
    }
    final address = server.host.contains(':') && !server.host.startsWith('[')
        ? '[${server.host}]'
        : server.host;
    routes.add('PROXY $address:${server.port}');
  }
  if (!selected) return 'DIRECT'; // No proxy configured for this URL scheme.
  if (routes.isEmpty) throw const HttpException('系统代理没有返回可用地址');
  return routes.join('; ');
}

final class _IeConfig extends Struct {
  @Int32()
  external int autoDetect;
  external Pointer<Uint16> autoConfigUrl;
  external Pointer<Uint16> proxy;
  external Pointer<Uint16> bypass;
}

final class _AutoOptions extends Struct {
  @Uint32()
  external int flags;
  @Uint32()
  external int detectFlags;
  external Pointer<Uint16> configUrl;
  external Pointer<Void> reserved;
  @Uint32()
  external int reservedFlags;
  @Int32()
  external int autoLogon;
}

final class _ProxyInfo extends Struct {
  @Uint32()
  external int accessType;
  external Pointer<Uint16> proxy;
  external Pointer<Uint16> bypass;
}

/// Windows owns strings returned by WinHTTP (GlobalFree); our zeroed structs
/// and input strings use the process heap (HeapFree). Keep ownership explicit.
class _WinHttp {
  final _kernel = DynamicLibrary.open('kernel32.dll');
  late final _library = _bridge();
  DynamicLibrary _bridge() {
    final executable = DynamicLibrary.process();
    if (executable.providesSymbol('McdProxyResolve')) return executable;
    // Standalone library is built only for flutter_tester / native API tests.
    return DynamicLibrary.open('mc_download_proxy.dll');
  }

  late final _heap = _kernel
      .lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>(
        'GetProcessHeap',
      )();
  late final _allocate = _kernel
      .lookupFunction<
        Pointer<Void> Function(Pointer<Void>, Uint32, UintPtr),
        Pointer<Void> Function(Pointer<Void>, int, int)
      >('HeapAlloc');
  late final _free = _kernel
      .lookupFunction<
        Int32 Function(Pointer<Void>, Uint32, Pointer<Void>),
        int Function(Pointer<Void>, int, Pointer<Void>)
      >('HeapFree');
  late final _globalFree = _kernel
      .lookupFunction<
        Pointer<Void> Function(Pointer<Void>),
        Pointer<Void> Function(Pointer<Void>)
      >('GlobalFree');
  late final _getConfig = _library
      .lookupFunction<
        Uint32 Function(Pointer<_IeConfig>),
        int Function(Pointer<_IeConfig>)
      >('McdProxyConfig');
  late final _open = _library
      .lookupFunction<
        Uint32 Function(Pointer<Uint16>, Pointer<Pointer<Void>>),
        int Function(Pointer<Uint16>, Pointer<Pointer<Void>>)
      >('McdProxyOpen');
  late final _getProxy = _library
      .lookupFunction<
        Uint32 Function(
          Pointer<Void>,
          Pointer<Uint16>,
          Pointer<_AutoOptions>,
          Pointer<_ProxyInfo>,
        ),
        int Function(
          Pointer<Void>,
          Pointer<Uint16>,
          Pointer<_AutoOptions>,
          Pointer<_ProxyInfo>,
        )
      >('McdProxyResolve');
  late final _close = _library
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('McdProxyClose');
  final _owned = <Pointer<Void>>[];

  Pointer<T> _memory<T extends NativeType>(int bytes) {
    final pointer = _allocate(_heap, 8 /* HEAP_ZERO_MEMORY */, bytes);
    if (pointer == nullptr) throw const HttpException('系统代理内存分配失败');
    _owned.add(pointer);
    return pointer.cast<T>();
  }

  Pointer<Uint16> _wide(String value) {
    final units = value.codeUnits;
    final pointer = _memory<Uint16>((units.length + 1) * 2);
    pointer.asTypedList(units.length).setAll(0, units);
    return pointer;
  }

  String _string(Pointer<Uint16> pointer) {
    if (pointer == nullptr) return '';
    for (var length = 0; length < 65536; length++) {
      if (pointer[length] == 0) {
        return String.fromCharCodes(pointer.asTypedList(length));
      }
    }
    throw const HttpException('Windows 系统代理配置过长');
  }

  void _release(Pointer<Uint16> pointer) {
    if (pointer != nullptr) _globalFree(pointer.cast<Void>());
  }

  SystemProxyResult resolve(Uri uri) {
    Pointer<_IeConfig> config = nullptr;
    Pointer<_ProxyInfo> result = nullptr;
    Pointer<Void> session = nullptr;
    try {
      config = _memory<_IeConfig>(sizeOf<_IeConfig>());
      final configurationError = _getConfig(config);
      if (configurationError != 0) {
        // No Internet Options profile is valid on a clean Windows account.
        if (configurationError == 2) return const SystemProxyResult('DIRECT');
        throw HttpException('读取 Windows 系统代理失败（$configurationError）');
      }
      final fixedProxy = _string(config.ref.proxy);
      final fixedBypass = _string(config.ref.bypass);
      final autoUrl = _string(config.ref.autoConfigUrl);
      final automatic = autoUrl.isNotEmpty || config.ref.autoDetect != 0;
      if (!automatic) {
        return SystemProxyResult(
          systemProxyRoute(uri, fixedProxy, fixedBypass),
        );
      }
      final handle = _memory<Pointer<Void>>(sizeOf<Pointer<Void>>());
      final openError = _open(_wide('MC-Download/$appVersion'), handle);
      session = handle.value;
      if (openError != 0) {
        throw HttpException('初始化 Windows 自动代理失败（$openError）');
      }
      final options = _memory<_AutoOptions>(sizeOf<_AutoOptions>());
      // Explicit PAC takes precedence over WPAD discovery.
      options.ref.flags = autoUrl.isNotEmpty ? 2 : 1;
      options.ref.detectFlags = autoUrl.isEmpty ? 3 : 0;
      options.ref.configUrl = autoUrl.isNotEmpty
          ? config.ref.autoConfigUrl
          : nullptr;
      result = _memory<_ProxyInfo>(sizeOf<_ProxyInfo>());
      final error = _getProxy(session, _wide(uri.toString()), options, result);
      if (error == 0) {
        return SystemProxyResult(
          result.ref.accessType == 1
              ? 'DIRECT'
              : systemProxyRoute(
                  uri,
                  _string(result.ref.proxy),
                  _string(result.ref.bypass),
                ),
          perUrl: true,
        );
      }
      if (fixedProxy.isNotEmpty) {
        return SystemProxyResult(
          systemProxyRoute(uri, fixedProxy, fixedBypass),
        );
      }
      // WPAD enabled but no PAC discovered: normal on networks without WPAD.
      if (autoUrl.isEmpty && error == 12180) {
        return const SystemProxyResult('DIRECT');
      }
      throw HttpException('解析 Windows 自动代理失败（$error），请检查 PAC 或选择手动代理');
    } finally {
      if (result != nullptr) {
        _release(result.ref.proxy);
        _release(result.ref.bypass);
      }
      if (config != nullptr) {
        _release(config.ref.autoConfigUrl);
        _release(config.ref.proxy);
        _release(config.ref.bypass);
      }
      if (session != nullptr) _close(session);
      for (final pointer in _owned.reversed) {
        _free(_heap, 0, pointer);
      }
    }
  }
}
