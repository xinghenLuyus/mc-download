import 'package:flutter/services.dart';

class ArchiveDropBridge {
  static const channel = MethodChannel('mc_download/archive_drop');
  final Future<void> Function(List<String>) onDrop;
  ArchiveDropBridge(this.onDrop);
  Future<void> start() async {
    channel.setMethodCallHandler((call) async {
      if (call.method == 'dropFiles' && call.arguments is List) {
        await onDrop((call.arguments as List).whereType<String>().toList());
      }
    });
    try {
      await channel.invokeMethod<void>('ready');
    } on MissingPluginException {
      // Manual imports remain available on development hosts without this runner.
    }
  }

  void dispose() => channel.setMethodCallHandler(null);
}
