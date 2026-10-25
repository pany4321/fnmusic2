/// 歌词载荷解析：LRC / QQ QRC / 网易 YRC / 酷狗 KRC → 结构化文档，
/// 以及文档 → 应用可解析 LRC 文本的渲染。
///
/// 移植自 fn-music（GPL-3.0-only）core/lyrics 的 LyricsSdk.kt：
/// - QRC 的 XML 包装（`<Lyric_1 LyricContent="…"/>`）先剥壳再解析；
/// - 逐词标记三种形态：QRC `文字(s,d)`（绝对时间，标记在文字后）、
///   YRC `(s,d,0)文字`（绝对时间，标记在文字前）、KRC `文字<o,d,0>`（相对
///   行首的偏移，标记在文字后）；
/// - 同一时间戳的 LRC 行按惯例视为「原文 + 翻译」，首行为原文；
/// - 日文假名注音 `（よ）` 从正文剔除（普通括号内容保留）；
/// - 翻译/注音侧轨按最近行起始对齐（±1500ms，每行只用一次）。
library;

import 'crypto_codec.dart';
import 'models.dart';

const int kMaxSidecarDeltaMs = 1500;

/// 解析原文（可选翻译/注音侧轨文本）为结构化歌词文档。
OnlineLyricsDocument parseLyricsDocument(
  String original, {
  String? translation,
  String? phonetic,
}) {
  final track = _parseTrack(original);
  var translationLines = track.embeddedTranslations;
  final explicitTranslation = _parseSidecarTrack(translation);
  if (explicitTranslation.isNotEmpty) translationLines = explicitTranslation;
  final phoneticLines = _parseSidecarTrack(phonetic);
  return OnlineLyricsDocument(
    lines: track.lines,
    translationLines: translationLines,
    phoneticLines: phoneticLines,
  );
}

// ---------------------------------------------------------------------------
// 时间戳与标记
// ---------------------------------------------------------------------------

final RegExp _lrcTimeTag = RegExp(
  r'^\[(ti|ar|al|by|offset|total|hash|sign|qq|kugou|kuwo):',
  caseSensitive: false,
);
final RegExp _lrcTimestamp = RegExp(r'\[(\d{1,2}):(\d{2})(?:[.:](\d{1,3}))?\]');
final RegExp _karaokeLineHeader = RegExp(r'^\[(\d+),(\d+)\](.*)$');
final RegExp _yrcWordMarker = RegExp(r'\((\d+),(\d+),\d+\)');
final RegExp _qrcWordMarker = RegExp(r'\((\d+),(\d+)\)');
final RegExp _krcWordMarker = RegExp(r'<(\d+),(\d+),\d+>');
final RegExp _qrcXmlWrapper = RegExp(
  r'<Lyric_1\b[^>]*\bLyricContent="(.*?)"\s*/>',
  dotAll: true,
  caseSensitive: false,
);
final RegExp _japaneseAnnotation =
    RegExp(r'[（(][\u3040-\u30ff\u31f0-\u31ff\uff66-\uff9fー・･\s]+[）)]');

// ---------------------------------------------------------------------------
// 轨道解析
// ---------------------------------------------------------------------------

class _ParsedTrack {
  final List<OnlineLyricsLine> lines;
  final List<OnlineLyricsLine> embeddedTranslations;

  const _ParsedTrack(this.lines, this.embeddedTranslations);
}

_ParsedTrack _parseTrack(String content) {
  var text = content.replaceFirst('\uFEFF', '');
  final xmlMatch = _qrcXmlWrapper.firstMatch(text);
  if (xmlMatch != null) {
    text = decodeXmlEntities(xmlMatch.group(1)!);
  }

  final lines = <OnlineLyricsLine>[];
  for (final raw in text.split(RegExp(r'\r?\n'))) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    if (_lrcTimeTag.hasMatch(line)) continue;

    final karaoke = _karaokeLineHeader.firstMatch(line);
    if (karaoke != null) {
      lines.addAll(_parseKaraokeLine(karaoke));
      continue;
    }
    lines.addAll(_parseLrcLine(line));
  }

  lines.sort((a, b) {
    final byStart = a.startMs.compareTo(b.startMs);
    return byStart != 0 ? byStart : a.endMs.compareTo(b.endMs);
  });
  return _splitSameTimeTranslations(lines);
}

List<OnlineLyricsLine> _parseSidecarTrack(String? content) {
  if (content == null || content.trim().isEmpty) return const [];
  return _parseTrack(content).lines;
}

/// 解析 QRC/YRC/KRC 家族的一行：`[start,dur]` 行头 + 逐词标记。
///
/// 三种标记形态：
/// - YRC：`(start,dur,flag)文字`（绝对时间，标记在文字前）；
/// - KRC：`<offset,dur,flag>文字`（相对行首偏移，标记在文字前）；
/// - QRC：`文字(start,dur)`（绝对时间，标记在文字后）。
List<OnlineLyricsLine> _parseKaraokeLine(RegExpMatch header) {
  final lineStart = int.tryParse(header.group(1)!);
  final lineDuration = int.tryParse(header.group(2)!);
  if (lineStart == null || lineDuration == null) return const [];
  final content = header.group(3) ?? '';

  final words = <OnlineLyricsWord>[];
  final yrcMarkers = _yrcWordMarker.allMatches(content).toList();
  final krcMarkers = _krcWordMarker.allMatches(content).toList();
  final qrcMarkers = _qrcWordMarker.allMatches(content).toList();

  if (yrcMarkers.isNotEmpty || krcMarkers.isNotEmpty) {
    // 标记在文字前（YRC 绝对时间 / KRC 相对行首偏移）。
    final markers = yrcMarkers.isNotEmpty ? yrcMarkers : krcMarkers;
    final relative = yrcMarkers.isEmpty;
    for (var i = 0; i < markers.length; i++) {
      final marker = markers[i];
      final textEnd = i + 1 < markers.length
          ? markers[i + 1].start
          : content.length;
      final wordText = content.substring(marker.end, textEnd).trimRight();
      final markerStart = int.tryParse(marker.group(1)!) ?? 0;
      final duration = int.tryParse(marker.group(2)!) ?? 0;
      // 零时长词保留文本（时长钳到 1ms），避免吞字。
      if (wordText.isEmpty) continue;
      final start = relative ? lineStart + markerStart : markerStart;
      words.add(OnlineLyricsWord(
        text: wordText,
        startMs: start,
        endMs: start + (duration > 0 ? duration : 1),
      ));
    }
  } else {
    // QRC：标记在文字后。
    var textStart = 0;
    for (final marker in qrcMarkers) {
      final wordText = content.substring(textStart, marker.start).trimRight();
      final start = int.tryParse(marker.group(1)!) ?? 0;
      final duration = int.tryParse(marker.group(2)!) ?? 0;
      textStart = marker.end;
      // 零时长词保留文本（时长钳到 1ms），避免吞字。
      if (wordText.isEmpty) continue;
      words.add(OnlineLyricsWord(
        text: wordText,
        startMs: start,
        endMs: start + (duration > 0 ? duration : 1),
      ));
    }
  }

  if (words.isNotEmpty) {
    // 注音剔除先于文本拼接，否则剔除掉的假名会残留在行文本里。
    final stripped = _stripWordAnnotations(words);
    if (stripped.isNotEmpty) {
      final headerEnd = lineStart + lineDuration;
      final lastEnd = stripped.last.endMs;
      final lineEnd = lastEnd > headerEnd ? lastEnd : headerEnd;
      return [
        OnlineLyricsLine(
          startMs: lineStart,
          endMs: lineEnd,
          text: stripped.map((w) => w.text).join(),
          words: stripped,
        ),
      ];
    }
  }

  final plain = _stripLineAnnotations(content.trim());
  if (plain.isEmpty) return const [];
  return [
    OnlineLyricsLine(
      startMs: lineStart,
      endMs: lineStart + lineDuration,
      text: plain,
    ),
  ];
}

/// 解析标准 LRC 行：一个或多个 `[mm:ss.xx]` 时间戳 + 文本。
List<OnlineLyricsLine> _parseLrcLine(String line) {
  final matches = _lrcTimestamp.allMatches(line).toList();
  if (matches.isEmpty) return const [];
  final text = _stripLineAnnotations(line.replaceAll(_lrcTimestamp, '').trim());
  if (text.isEmpty) return const [];
  return [
    for (final match in matches)
      OnlineLyricsLine(
        startMs: _lrcTimestampToMs(match),
        endMs: _lrcTimestampToMs(match),
        text: text,
      ),
  ];
}

int _lrcTimestampToMs(RegExpMatch match) {
  final minutes = int.tryParse(match.group(1) ?? '0') ?? 0;
  final seconds = int.tryParse(match.group(2) ?? '0') ?? 0;
  final fracRaw = match.group(3) ?? '';
  var ms = 0;
  if (fracRaw.isNotEmpty) {
    ms = int.tryParse(fracRaw.padRight(3, '0')) ?? 0;
  }
  return (minutes * 60 + seconds) * 1000 + ms;
}

/// 同一时间戳的多行按 LRC 惯例视为「原文 + 翻译」：首行为原文，
/// 后续行并入翻译轨道（内容不丢弃）。
_ParsedTrack _splitSameTimeTranslations(List<OnlineLyricsLine> sorted) {
  final original = <OnlineLyricsLine>[];
  final translations = <OnlineLyricsLine>[];
  final seenTexts = <String>{};
  var previousSameStart = -1;

  for (final line in sorted) {
    if (!seenTexts.add('${line.startMs}|${line.text}')) continue;
    if (previousSameStart == line.startMs) {
      translations.add(OnlineLyricsLine(
        startMs: line.startMs,
        endMs: line.endMs,
        text: line.text,
      ));
      continue;
    }
    original.add(line);
    previousSameStart = line.startMs;
  }
  return _ParsedTrack(original, translations);
}

// ---------------------------------------------------------------------------
// 日文注音剔除
// ---------------------------------------------------------------------------

String _stripLineAnnotations(String value) =>
    value.replaceAll(_japaneseAnnotation, '').trim();

/// 逐词轨道上的注音剔除：先拼接整行文本定位注音片段，再按字符区间
/// 映射回每个词（注音常被拆成多个独立词 `（` `よ` `）`）。
List<OnlineLyricsWord> _stripWordAnnotations(List<OnlineLyricsWord> words) {
  final combined = words.map((w) => w.text).join();
  final removed = <int>{};
  for (final match in _japaneseAnnotation.allMatches(combined)) {
    for (var i = match.start; i < match.end; i++) {
      removed.add(i);
    }
  }
  if (removed.isEmpty) return words;

  final result = <OnlineLyricsWord>[];
  var absoluteIndex = 0;
  for (final word in words) {
    final buffer = StringBuffer();
    for (var i = 0; i < word.text.length; i++) {
      if (!removed.contains(absoluteIndex)) {
        buffer.write(word.text[i]);
      }
      absoluteIndex++;
    }
    if (buffer.isNotEmpty) {
      result.add(OnlineLyricsWord(
        text: buffer.toString(),
        startMs: word.startMs,
        endMs: word.endMs,
      ));
    }
  }
  return result;
}

// ---------------------------------------------------------------------------
// 侧轨对齐与渲染
// ---------------------------------------------------------------------------

/// 把侧轨行按最近行起始对齐到原文行（±[kMaxSidecarDeltaMs]，每行只用一次）。
/// 返回「原文行下标 → 侧轨文本」。
Map<int, String> alignSidecar(
  List<OnlineLyricsLine> lines,
  List<OnlineLyricsLine> sidecar,
) {
  if (sidecar.isEmpty) return const {};
  final available = List<int>.generate(sidecar.length, (i) => i);
  final result = <int, String>{};
  for (var i = 0; i < lines.length; i++) {
    int? bestIndex;
    var bestDelta = kMaxSidecarDeltaMs + 1;
    for (final j in available) {
      final delta = (sidecar[j].startMs - lines[i].startMs).abs();
      if (delta < bestDelta) {
        bestDelta = delta;
        bestIndex = j;
      }
    }
    if (bestIndex == null) continue;
    available.remove(bestIndex);
    final text = sidecar[bestIndex].text.trim();
    if (text.isNotEmpty) result[i] = text;
  }
  return result;
}

/// 把文档渲染为应用歌词解析器可读的 LRC 文本。
///
/// - 逐词行渲染为交错逐字格式 `[t1]词1[t2]词2[end]`（应用解析器会还原逐词
///   时间轴）；无逐词信息时渲染为普通 `[mm:ss.xxx]文本`。
/// - 翻译/注音行以与原文行相同的时间戳紧随其后输出（应用按 LRC 惯例合并
///   为译文）。
String renderDocumentToLrcText(
  OnlineLyricsDocument document, {
  bool preferWordTiming = true,
  bool includeTranslation = true,
  bool includePhonetic = false,
  bool onlyTranslation = false,
}) {
  final translations = alignSidecar(document.lines, document.translationLines);
  final phonetics = alignSidecar(document.lines, document.phoneticLines);
  final buffer = StringBuffer();

  for (var i = 0; i < document.lines.length; i++) {
    final line = document.lines[i];
    if (line.text.trim().isEmpty) continue;
    final ts = _formatTimestamp(line.startMs);

    if (onlyTranslation) {
      final translation = translations[i];
      if (translation != null && translation.isNotEmpty) {
        buffer.writeln('[$ts]$translation');
      }
      continue;
    }

    final words = line.words;
    if (preferWordTiming && words.length >= 2) {
      for (final word in words) {
        if (word.text.isEmpty) continue;
        buffer.write('[${_formatTimestamp(word.startMs)}]${word.text}');
      }
      final lineEnd = words.last.endMs > line.endMs
          ? words.last.endMs
          : (line.endMs > line.startMs ? line.endMs : words.last.endMs);
      buffer.writeln('[${_formatTimestamp(lineEnd)}]');
    } else {
      buffer.writeln('[$ts]${line.text}');
    }

    if (includeTranslation) {
      final translation = translations[i];
      if (translation != null && translation.isNotEmpty) {
        buffer.writeln('[$ts]$translation');
      }
    }
    if (includePhonetic) {
      final phonetic = phonetics[i];
      if (phonetic != null && phonetic.isNotEmpty) {
        buffer.writeln('[$ts]$phonetic');
      }
    }
  }
  return buffer.toString();
}

String _formatTimestamp(int ms) {
  if (ms < 0) ms = 0;
  final minutes = (ms ~/ 60000).toString().padLeft(2, '0');
  final seconds = ((ms % 60000) ~/ 1000).toString().padLeft(2, '0');
  final millis = (ms % 1000).toString().padLeft(3, '0');
  return '$minutes:$seconds.$millis';
}
