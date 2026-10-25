/// 歌词源专用 HTTP 客户端：dio 封装，GET/POST + 统一 UA +
/// 非 2xx 抛 [LyricsTransportException]（带状态码与 Retry-After）。
///
/// 移植自 fn-music（GPL-3.0-only）core/lyrics 的 LyricsHttpClient.kt。
library;

import 'package:dio/dio.dart';

import 'models.dart';

/// 客户端标识。LRCLIB 要求 UA 标明客户端，其余源也无害。
const String kLyricsUserAgent =
    'FeiNiuMusic/1.0 (https://github.com/kuilei0926/FeiNiuMusic)';

class LyricsHttpClient {
  LyricsHttpClient({Dio? dio })
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 6),
              receiveTimeout: const Duration(seconds: 12),
              // 部分 QQ/酷狗接口对非 2xx 也返回 JSON，交由上层解析。
              validateStatus: (code) => code != null && code < 500,
              responseType: ResponseType.plain,
              // 歌词接口不跟随重定向到登录页之类的地方。
              followRedirects: true,
              maxRedirects: 3,
            ));

  final Dio _dio;

  Future<String> get(
    String url, {
    Map<String, String>? query,
    Map<String, String>? headers,
  }) async {
    try {
      final response = await _dio.get<String>(
        url,
        queryParameters: query,
        options: Options(
          responseType: ResponseType.plain,
          headers: {
            'Accept': 'application/json, text/plain, */*',
            'User-Agent': kLyricsUserAgent,
            ...?headers,
          },
        ),
      );
      _ensureSuccess(response);
      return response.data ?? '';
    } on LyricsTransportException {
      rethrow;
    } catch (e) {
      throw LyricsTransportException('Lyrics request failed: $e');
    }
  }

  Future<String> post(
    String url,
    String body, {
    Map<String, String>? headers,
  }) async {
    try {
      final response = await _dio.post<String>(
        url,
        data: body,
        options: Options(
          responseType: ResponseType.plain,
          headers: {
            'Accept': 'application/json, text/plain, */*',
            'Content-Type': 'application/json',
            'User-Agent': kLyricsUserAgent,
            ...?headers,
          },
        ),
      );
      _ensureSuccess(response);
      return response.data ?? '';
    } on LyricsTransportException {
      rethrow;
    } catch (e) {
      throw LyricsTransportException('Lyrics request failed: $e');
    }
  }

  void _ensureSuccess(Response<String> response) {
    final code = response.statusCode ?? 0;
    if (code < 200 || code >= 300) {
      throw LyricsTransportException(
        'Lyrics HTTP $code',
        status: code,
        retryAfterMs: _retryAfterMs(response),
      );
    }
  }

  /// `Retry-After` 的秒数形式（HTTP 日期形式不解析，按缺失处理 ——
  /// 调用方会用默认冷却兜底）。
  static int? _retryAfterMs(Response<String> response) {
    final value = response.headers.value('Retry-After')?.trim();
    final seconds = value == null ? null : int.tryParse(value);
    if (seconds == null || seconds < 0) return null;
    return seconds * 1000;
  }
}
