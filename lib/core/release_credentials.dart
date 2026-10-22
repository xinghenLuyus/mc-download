import 'dart:convert';
import 'app_version.dart';

// A fresh random XOR mask is generated for each release. Both parts ship in
// the binary: this avoids plaintext literals, not deliberate key extraction.
const _payload = String.fromEnvironment('MC_DOWNLOAD_CF_PAYLOAD');
const _mask = String.fromEnvironment('MC_DOWNLOAD_CF_MASK');
const hasBundledCurseForgeKey =
    appVersion != 'dev' && _payload != '' && _mask != '';
final _decodedKey = hasBundledCurseForgeKey
    ? decodeReleaseCredential(_payload, _mask)
    : '';
String get bundledCurseForgeKey => _decodedKey;

String decodeReleaseCredential(String payload, String mask) {
  try {
    final encrypted = base64Decode(payload), pad = base64Decode(mask);
    if (encrypted.isEmpty || encrypted.length != pad.length) {
      throw const FormatException();
    }
    return utf8.decode(
      List<int>.generate(encrypted.length, (i) => encrypted[i] ^ pad[i]),
    );
  } on FormatException {
    throw const FormatException('内置 CurseForge 授权数据无效，请重新下载发行版');
  }
}
