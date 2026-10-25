/// 歌词载荷编解码：QQ QRC 3DES 解密、酷狗 KRC 异或解密、zlib 解压、
/// base64 与 HTML/XML 实体解码。
///
/// 算法与密钥移植自 fn-music（GPL-3.0-only）core/lyrics 的
/// OnlineLyricsSources.kt（其上游为 LDDC）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'lddc_tripledes.dart';
import 'models.dart';

/// QQ QRC 载荷的 3DES 密钥。
///
/// 注意：QRC 的加解密与标准 3DES 库（pointycastle 等）不兼容——上游
/// 实现按小端 uint 字内反序寻址位（见 lddc_tripledes.dart），必须用
/// [tripleDesDecryptBlocks] 这一 LDDC 语义的实现。
final Uint8List _qrcKey = Uint8List.fromList(
  '!@#)(*\$%123ZXC!@!@#)(NHL'.codeUnits,
);

/// 酷狗 KRC 载荷的文件头标识（"krc1"）。
const List<int> _krcHeader = [0x6b, 0x72, 0x63, 0x31]; // k r c 1

/// 酷狗 KRC 载荷的异或密钥。
const List<int> _krcKey = [
  0x40, 0x47, 0x61, 0x77, 0x5e, 0x32, 0x74, 0x47,
  0x51, 0x36, 0x31, 0x2d, 0xce, 0xd2, 0x6e, 0x69,
];

/// QQ 原生接口（GetPlayLyricInfo）的歌词字段：
/// 纯十六进制串 → 3DES 解密再 zlib 解压；否则按老接口字段处理（base64）。
String decodeQqNativeField(String? value) {
  final raw = value ?? '';
  if (raw.isEmpty) return '';
  if (raw.length.isEven && _isHexString(raw)) return _decryptQrc(raw);
  return decodeLyricField(raw);
}

/// QQ 老接口（fcg_query_lyric_new）的歌词字段：无时间戳则尝试 base64。
String decodeLyricField(String? value) {
  final raw = value ?? '';
  if (raw.isEmpty || raw.contains('[')) return raw;
  try {
    return decodeBase64(raw);
  } on LyricsPayloadException {
    return raw;
  }
}

/// 十六进制 QRC 载荷 → 明文 XML/QRC 文本。
String _decryptQrc(String hexValue) {
  try {
    final encrypted = Uint8List(hexValue.length ~/ 2);
    for (var i = 0; i < encrypted.length; i++) {
      encrypted[i] = int.parse(hexValue.substring(i * 2, i * 2 + 2), radix: 16);
    }
    final decrypted = tripleDesDecryptBlocks(encrypted, _qrcKey);
    return inflate(decrypted);
  } catch (_) {
    throw LyricsPayloadException('Invalid QQ QRC payload');
  }
}

/// 酷狗 KRC 载荷：base64 → 校验 "krc1" 头 → 异或 → zlib 解压。
String decryptKrc(String base64Value) {
  try {
    final encoded = decodeBase64Bytes(base64Value);
    if (encoded.length < _krcHeader.length ||
        !_startsWith(encoded, _krcHeader)) {
      throw LyricsPayloadException('Invalid Kugou KRC header');
    }
    final decrypted = Uint8List(encoded.length - _krcHeader.length);
    for (var i = _krcHeader.length; i < encoded.length; i++) {
      final keyIndex = (i - _krcHeader.length) % _krcKey.length;
      decrypted[i - _krcHeader.length] =
          encoded[i] ^ _krcKey[keyIndex];
    }
    return inflate(decrypted);
  } on LyricsPayloadException {
    rethrow;
  } catch (_) {
    throw LyricsPayloadException('Invalid Kugou KRC payload');
  }
}

/// zlib 解压为 UTF-8 文本。
String inflate(List<int> bytes) {
  try {
    return utf8.decode(ZLibDecoder().convert(bytes), allowMalformed: true);
  } catch (_) {
    throw LyricsPayloadException('Invalid compressed lyrics payload');
  }
}

String encodeBase64(String value) => base64Encode(utf8.encode(value));

String decodeBase64(String value) =>
    utf8.decode(decodeBase64Bytes(value), allowMalformed: true);

Uint8List decodeBase64Bytes(String value) {
  try {
    return base64Decode(value);
  } catch (_) {
    throw LyricsPayloadException('Invalid base64 lyric payload');
  }
}

/// HTML 实体解码（各家接口的标题/歌词里普遍存在）。
String decodeHtmlEntities(String value) => value
    .replaceAll('&amp;', '&')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAllMapped(RegExp(r'&#(\d+);'), (match) {
      final codePoint = int.tryParse(match.group(1)!);
      if (codePoint == null) return '';
      return String.fromCharCodes(_toChars(codePoint));
    });

/// XML 实体解码（QRC 的 `LyricContent="…"` 属性里存在）。
String decodeXmlEntities(String value) => decodeHtmlEntities(value)
    .replaceAll('&#10;', '\n')
    .replaceAll('&#13;', '\r')
    .replaceAll('&apos;', "'");

List<int> _toChars(int codePoint) {
  // BMP 之外的码点需要代理对。
  if (codePoint < 0x10000) return [codePoint];
  final v = codePoint - 0x10000;
  return [0xd800 + (v >> 10), 0xdc00 + (v & 0x3ff)];
}

bool _isHexString(String value) {
  for (final code in value.codeUnits) {
    final isHex = (code >= 0x30 && code <= 0x39) || // 0-9
        (code >= 0x61 && code <= 0x66) || // a-f
        (code >= 0x41 && code <= 0x46); // A-F
    if (!isHex) return false;
  }
  return true;
}

bool _startsWith(List<int> bytes, List<int> prefix) {
  for (var i = 0; i < prefix.length; i++) {
    if (bytes[i] != prefix[i]) return false;
  }
  return true;
}
