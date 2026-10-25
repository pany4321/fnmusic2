/// 内置在线歌词门面：组装默认源与两轮编排，提供一次性取词入口。
///
/// 对应 fn-music（GPL-3.0-only）DefaultLyricsSources + 调用侧：
/// - 第一轮快源：网易云 / QQ 桌面搜索 / 酷狗 / LRCLIB；
/// - 第二轮深挖：QQ 老接口（召回最好但慢），仅在快源全军覆没时跑。
library;

import 'package:dio/dio.dart';

import 'coordinator.dart';
import 'http_client.dart';
import 'lyrics_parsers.dart';
import 'models.dart';
import 'sources.dart';

class OnlineLyricsClient {
  OnlineLyricsClient._();

  static final OnlineLyricsClient instance = OnlineLyricsClient._();

  LyricsHttpClient _http = LyricsHttpClient();
  LyricsMatchCoordinator? _coordinator;

  /// 渲染偏好快照（由宿主应用按用户设置刷新）。
  OnlineLyricsRenderPreference renderPreference =
      const OnlineLyricsRenderPreference();

  LyricsMatchCoordinator _ensureCoordinator() {
    if (_coordinator != null) return _coordinator!;
    return _coordinator = LyricsMatchCoordinator(
      sources: [
        NeteaseLyricsSource(_http),
        QqMusicLyricsSource(_http),
        KugouLyricsSource(_http),
        LrclibLyricsSource(_http),
      ],
      deepSources: [
        QqMusicLyricsSource(_http, deepSearch: true),
      ],
    );
  }

  /// 多源搜索并取词。返回 null 表示未命中（[onFailure] 回传失败类别供
  /// 调用方决定是否提示/重试）。
  Future<OnlineLyricsMatch?> fetchBestLyrics({
    required String title,
    required List<String> artists,
    String? album,
    int? durationMs,
    void Function(LyricsFailureKind? failure)? onFailure,
  }) async {
    final request = OnlineLyricsRequest(
      title: title,
      artists: artists,
      album: album,
      durationMs: durationMs,
    );
    final result = await _ensureCoordinator().match(request);
    if (result.found != null) return result.found;
    onFailure?.call(result.failure);
    return null;
  }

  /// 把命中的歌词渲染为应用解析器可读的 LRC 文本（含翻译/注音偏好）。
  String renderToLrcText(OnlineLyricsMatch match) {
    final pref = renderPreference;
    return renderDocumentToLrcText(
      match.document,
      preferWordTiming: pref.preferWordTiming,
      includeTranslation: pref.includeTranslation,
      includePhonetic: pref.includePhonetic,
      onlyTranslation: pref.onlyTranslation,
    );
  }
}

/// 渲染偏好（对齐应用「匹配设置」里的歌词模式与翻译/注音开关）。
class OnlineLyricsRenderPreference {
  /// 逐字时间轴可用时输出交错逐字 LRC。
  final bool preferWordTiming;

  /// 追加翻译行。
  final bool includeTranslation;

  /// 追加注音（罗马音）行。
  final bool includePhonetic;

  /// 仅输出翻译。
  final bool onlyTranslation;

  const OnlineLyricsRenderPreference({
    this.preferWordTiming = true,
    this.includeTranslation = true,
    this.includePhonetic = false,
    this.onlyTranslation = false,
  });
}

/// 供宿主应用注入自定义 Dio（代理、证书等场景）。
void configureLyricsHttpClient(Dio dio) {
  // 重建协调器，让下一次调用用新客户端。
  OnlineLyricsClient.instance._http = LyricsHttpClient(dio: dio);
  OnlineLyricsClient.instance._coordinator = null;
}
