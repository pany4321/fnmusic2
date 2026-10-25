/// 在线歌词数据模型：请求、候选、结构化歌词文档与源接口。
///
/// 移植自 fn-music（GPL-3.0-only）core/lyrics 的 LyricsModels.kt，
/// 关键设计一并保留：
/// - 候选必须带足元数据（标题/歌手/专辑/时长），评分器据此过滤；
/// - 传输失败（可重试）与载荷失败（数据无效）分开建模；
/// - LRCLIB 要求读取并遵守 429 的 Retry-After，故传输异常带上状态码与重试等待。
library;

/// 一次歌词匹配请求（本地歌曲的已知元数据）。
class OnlineLyricsRequest {
  final String title;
  final List<String> artists;
  final String? album;
  final int? durationMs;

  const OnlineLyricsRequest({
    required this.title,
    required this.artists,
    this.album,
    this.durationMs,
  });
}

/// 在线歌词源标识。顺序即同分时的优先序：LRCLIB 多为繁体且无翻译/逐字，
/// 仅在中文平台都给不出结果时兜底。
enum OnlineSourceId { netease, qqMusic, kugou, lrclib }

/// 歌词内容质量档位。
enum LyricsContentQuality { basic, translated, wordTimed }

/// 搜索阶段的一个远端候选。
class OnlineLyricsCandidate {
  final OnlineSourceId source;
  final String remoteId;

  /// QQ 的 songmid（LRC 兜底接口用）。
  final String? mediaId;

  /// 酷狗的 FileHash（歌词定位用）。
  final String? fileHash;
  final String title;
  final List<String> artists;
  final String? album;
  final int? durationMs;
  final bool instrumental;

  const OnlineLyricsCandidate({
    required this.source,
    required this.remoteId,
    required this.title,
    required this.artists,
    this.mediaId,
    this.fileHash,
    this.album,
    this.durationMs,
    this.instrumental = false,
  });
}

/// 一个词（逐字时间戳）。
class OnlineLyricsWord {
  final int startMs;
  final int endMs;
  final String text;

  const OnlineLyricsWord({
    required this.startMs,
    required this.endMs,
    required this.text,
  });
}

/// 歌词文档中的一行（可能带逐词时间戳）。
class OnlineLyricsLine {
  final int startMs;
  final int endMs;
  final String text;
  final List<OnlineLyricsWord> words;

  const OnlineLyricsLine({
    required this.startMs,
    required this.endMs,
    required this.text,
    this.words = const [],
  });

  bool get hasWordTiming => words.length >= 2;
}

/// 结构化在线歌词：原文 +（按行对齐的）翻译与注音轨道。
class OnlineLyricsDocument {
  final List<OnlineLyricsLine> lines;
  final List<OnlineLyricsLine> translationLines;
  final List<OnlineLyricsLine> phoneticLines;

  const OnlineLyricsDocument({
    required this.lines,
    this.translationLines = const [],
    this.phoneticLines = const [],
  });

  bool get hasUsableLines =>
      lines.any((line) => line.text.trim().isNotEmpty);

  /// 逐行歌词里带有效逐词时间戳的行占比。
  double get wordTimedCoverage {
    final usable = lines.where((l) => l.text.trim().isNotEmpty).toList();
    if (usable.isEmpty) return 0;
    return usable.where((l) => l.hasWordTiming).length / usable.length;
  }

  /// 翻译轨道覆盖到原文行的行数。
  int get translatedLineCount {
    final byStart = {
      for (final l in translationLines) l.startMs: l.text.trim(),
    };
    return lines
        .where((l) => (byStart[l.startMs] ?? '').isNotEmpty)
        .length;
  }

  LyricsContentQuality get quality {
    if (lines.any((l) => l.hasWordTiming)) {
      return LyricsContentQuality.wordTimed;
    }
    if (translatedLineCount > 0) return LyricsContentQuality.translated;
    return LyricsContentQuality.basic;
  }

  /// 去掉逐词时间戳（时长对不上时降级为逐行，避免逐字进度漂移）。
  OnlineLyricsDocument withoutWordTiming() => OnlineLyricsDocument(
        lines: lines
            .map((l) => OnlineLyricsLine(
                  startMs: l.startMs,
                  endMs: l.endMs,
                  text: l.text,
                ))
            .toList(),
        translationLines: translationLines,
        phoneticLines: phoneticLines,
      );
}

/// 匹配命中的最终结果。
class OnlineLyricsMatch {
  final OnlineSourceId source;
  final OnlineLyricsCandidate candidate;
  final double score;
  final OnlineLyricsDocument document;

  const OnlineLyricsMatch({
    required this.source,
    required this.candidate,
    required this.score,
    required this.document,
  });
}

/// 搜索查询：keyword 为「歌手 - 标题」或纯标题（由编排层决定）。
class LyricsSearchQuery {
  final String keyword;
  final OnlineLyricsRequest request;

  const LyricsSearchQuery(this.keyword, this.request);
}

/// 一个在线歌词源。
abstract class OnlineLyricsSource {
  OnlineSourceId get id;

  /// 本源搜索是否利用「歌手 - 标题」形态的关键词。
  ///
  /// 不利用的源（例如 QQ 桌面搜索只认标题，带歌手反而带偏）应返回 false：
  /// 编排层在主关键词没有合格候选时，只用纯标题对支持的源重试一次。
  bool get supportsKeywordVariants => true;

  Future<List<OnlineLyricsCandidate>> search(LyricsSearchQuery query);

  Future<OnlineLyricsDocument> fetch(OnlineLyricsCandidate candidate);
}

/// 传输层失败（网络/超时/HTTP 错误）。
///
/// [status] 是 HTTP 状态码，[retryAfterMs] 来自 `Retry-After` 响应头 ——
/// LRCLIB 要求客户端在 429 时读取并遵守它，否则可能被临时封禁。
class LyricsTransportException implements Exception {
  final String message;
  final int? status;
  final int? retryAfterMs;

  LyricsTransportException(this.message, {this.status, this.retryAfterMs});

  @override
  String toString() => 'LyricsTransportException: $message'
      '${status != null ? ' (HTTP $status)' : ''}';
}

/// 载荷失败（返回了数据但无效）。
class LyricsPayloadException implements Exception {
  final String message;

  LyricsPayloadException(this.message);

  @override
  String toString() => 'LyricsPayloadException: $message';
}
