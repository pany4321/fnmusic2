/// 内置在线歌词网关：把应用的歌词偏好映射到 online_lyrics 包并渲染为
/// 应用解析器可读的 LRC 文本。
///
/// 独立于服务端增强（FnMusicEnhance）——应用内直连网易云/QQ/酷狗/LRCLIB，
/// 播放自动搜索与手动匹配歌词都可走这条通道。
library;

import 'package:flutter/foundation.dart';

import 'package:online_lyrics/online_lyrics.dart';

import '../../state/settings_lyric_auto_search.dart';
import '../../state/settings_match.dart';

class OnlineLyricsGateway {
  OnlineLyricsGateway._();

  static final OnlineLyricsGateway instance = OnlineLyricsGateway._();

  /// 内置在线源是否启用。
  bool get available => LyricAutoSearchSettings.useBuiltinOnline.value;

  /// 多源搜索并渲染为 LRC 文本；未命中/未启用返回 null。
  ///
  /// [artists] 支持多歌手（内部按名单评分，不需要拼接成单一字符串）。
  Future<String?> fetchLyricsText({
    required String title,
    required String artist,
    String album = '',
    int durationMs = 0,
  }) async {
    if (!available) return null;
    final trimmedTitle = title.trim();
    if (trimmedTitle.isEmpty) return null;
    try {
      final match = await OnlineLyricsClient.instance.fetchBestLyrics(
        title: trimmedTitle,
        artists: artist
            .split(RegExp(r'[/、,，&]'))
            .map((a) => a.trim())
            .where((a) => a.isNotEmpty)
            .toList(),
        album: album.trim().isEmpty ? null : album.trim(),
        durationMs: durationMs > 0 ? durationMs : null,
      );
      if (match == null) return null;
      _syncRenderPreference();
      return OnlineLyricsClient.instance.renderToLrcText(match);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[OnlineLyrics] $title 在线取词失败: $e');
      }
      return null;
    }
  }

  /// 把「匹配设置」的歌词模式与翻译/注音开关同步到渲染偏好。
  void _syncRenderPreference() {
    final mode = MatchSettings.lyricMode.value;
    OnlineLyricsClient.instance.renderPreference = OnlineLyricsRenderPreference(
      // 逐字/增强逐字/TTML 模式都优先带逐词时间轴；逐行模式输出普通 LRC。
      preferWordTiming: mode != LyricMode.plain,
      includeTranslation: MatchSettings.translation.value,
      includePhonetic: MatchSettings.romanization.value,
      onlyTranslation: MatchSettings.onlyTranslation.value,
    );
  }
}
