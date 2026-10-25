/// 候选评分与入选闸门。
///
/// 移植自 fn-music（GPL-3-0-only）core/lyrics 的 LyricsMatchPolicy.kt
/// （其上游为 LDDC）：
/// - 标题/歌手/专辑相似度（difflib 风格的最长匹配块）加权；
/// - 歌手分以较短一方为分母（在线库常只列主唱，长名单钉死分数是漏配主因）；
/// - 版本标记冲突（live/remix/伴奏/剪辑版…）一票否决；
/// - 时长差 >5s 拒绝；标题几乎一致 + 时长差 ≤2s 的兜底闸门（合辑/古典
///   曲库的歌手标签常对不上）；
/// - 多源共识加分（不同源命中同一录音最多 +3 分）。
library;

import 'models.dart';

class LyricsMatchPolicy {
  /// 常规入选门槛：综合分。
  final double minimumScore;

  /// 常规入选门槛：标题分下限。
  final double minimumTitleScore;

  /// 本地与候选的时长容差：固定 ±5 秒。
  ///
  /// 绝对差才是判别力所在：同一录音的容器/编码差异最多一两秒，长曲上
  /// 几秒到几十秒的差几乎一定意味着不同版本（不同演出、剪辑、淡出）。
  final int maximumDurationDeltaMs;

  /// 逐字时间轴可信的时长差上限（超过则降级为逐行歌词）。
  final int maximumWordTimingDeltaMs;

  /// 兜底闸门：标题几乎一致时所需的标题分。
  final double highTitleScore;

  /// 兜底闸门允许的时长差：比 [maximumDurationDeltaMs] 更严。
  final int strictDurationDeltaMs;

  /// 同分结果的来源优先序。LRCLIB 排最后：多为繁体、无翻译与逐字。
  final List<OnlineSourceId> sourceOrder;

  const LyricsMatchPolicy({
    this.minimumScore = 80.0,
    this.minimumTitleScore = 50.0,
    this.maximumDurationDeltaMs = 5000,
    this.maximumWordTimingDeltaMs = 2000,
    this.highTitleScore = 95.0,
    this.strictDurationDeltaMs = 2000,
    this.sourceOrder = const [
      OnlineSourceId.netease,
      OnlineSourceId.qqMusic,
      OnlineSourceId.kugou,
      OnlineSourceId.lrclib,
    ],
  });
}

class ScoredLyricsCandidate {
  final OnlineLyricsCandidate candidate;
  final double score;
  final double titleScore;
  final int consensusCount;
  final double metadataScore;
  final int? durationDeltaMs;

  const ScoredLyricsCandidate({
    required this.candidate,
    required this.score,
    required this.titleScore,
    required this.consensusCount,
    this.metadataScore = 0,
    this.durationDeltaMs,
  });

  ScoredLyricsCandidate copyWith({
    double? score,
    int? consensusCount,
    double? metadataScore,
  }) =>
      ScoredLyricsCandidate(
        candidate: candidate,
        score: score ?? this.score,
        titleScore: titleScore,
        consensusCount: consensusCount ?? this.consensusCount,
        metadataScore: metadataScore ?? this.metadataScore,
        durationDeltaMs: durationDeltaMs,
      );
}

class LyricsCandidateScorer {
  final LyricsMatchPolicy policy;

  LyricsCandidateScorer([this.policy = const LyricsMatchPolicy()]);

  List<ScoredLyricsCandidate> score(
    OnlineLyricsRequest request,
    List<OnlineLyricsCandidate> candidates,
  ) {
    final eligible = <ScoredLyricsCandidate>[];
    for (final candidate in candidates) {
      final scored = _scoreOne(request, candidate);
      if (scored != null) eligible.add(scored);
    }
    if (eligible.isEmpty) return const [];

    final result = <ScoredLyricsCandidate>[];
    for (final scored in eligible) {
      var consensus = 1;
      final seenSources = <OnlineSourceId>{};
      for (final other in eligible) {
        if (other.candidate.source == scored.candidate.source) continue;
        if (!seenSources.add(other.candidate.source)) continue;
        if (_sameRecording(scored.candidate, other.candidate)) consensus++;
      }
      final bonus = (consensus - 1).clamp(0, 2) * 1.5;
      result.add(scored.copyWith(
        score: (scored.score + bonus).clamp(0, 100),
        consensusCount: consensus,
        metadataScore: scored.score,
      ));
    }
    result.removeWhere((s) => !_passesGate(s));
    result.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      if (byScore != 0) return byScore;
      return _sourceOrderIndex(a.candidate.source)
          .compareTo(_sourceOrderIndex(b.candidate.source));
    });
    return result;
  }

  int _sourceOrderIndex(OnlineSourceId source) {
    final index = policy.sourceOrder.indexOf(source);
    return index >= 0 ? index : 1 << 30;
  }

  /// 入选闸门：常规路径要求「标题 + 歌手」加权分够高；合辑、古典、民族
  /// 器乐曲库的本地歌手标签常与在线库对不上，故增加一条更严格时长的兜底：
  /// 标题几乎完全一致且时长差很小时放行。
  bool _passesGate(ScoredLyricsCandidate scored) {
    if (scored.score >= policy.minimumScore &&
        scored.titleScore >= policy.minimumTitleScore) {
      return true;
    }
    final delta = scored.durationDeltaMs;
    if (delta == null) return false;
    return scored.titleScore >= policy.highTitleScore &&
        delta <= policy.strictDurationDeltaMs;
  }

  ScoredLyricsCandidate? _scoreOne(
    OnlineLyricsRequest request,
    OnlineLyricsCandidate candidate,
  ) {
    if (candidate.title.trim().isEmpty || request.title.trim().isEmpty) {
      return null;
    }
    final durationDelta = _knownDurationDelta(
      request.durationMs,
      candidate.durationMs,
    );
    if (durationDelta != null &&
        durationDelta > policy.maximumDurationDeltaMs) {
      return null;
    }
    if (_hasHardVersionConflict(
      request.title,
      candidate.title,
      candidate.instrumental,
    )) {
      return null;
    }

    final titleScore = _titleScore(request.title, candidate.title);
    final localArtists = _splitArtists(request.artists);
    final remoteArtists = _splitArtists(candidate.artists);
    final artistScore = _artistScore(localArtists, remoteArtists);
    final albumScore = _albumScore(request.album, candidate.album);
    final score = _weightedScore(
      titleScore,
      artistScore,
      albumScore,
      hasBothArtists: localArtists.isNotEmpty && remoteArtists.isNotEmpty,
    );
    return ScoredLyricsCandidate(
      candidate: candidate,
      score: score,
      titleScore: titleScore,
      consensusCount: 1,
      metadataScore: score,
      durationDeltaMs: durationDelta,
    );
  }

  double _weightedScore(
    double titleScore,
    double artistScore,
    double? albumScore, {
    required bool hasBothArtists,
  }) {
    if (hasBothArtists && albumScore != null) {
      final a = titleScore * 0.5 + artistScore * 0.5;
      final b = titleScore * 0.5 + artistScore * 0.35 + albumScore * 0.15;
      return a > b ? a : b;
    }
    if (hasBothArtists) return titleScore * 0.5 + artistScore * 0.5;
    if (albumScore != null) {
      final a = titleScore * 0.7 + albumScore * 0.3;
      final b = titleScore * 0.8;
      return a > b ? a : b;
    }
    return titleScore;
  }

  bool _sameRecording(OnlineLyricsCandidate left, OnlineLyricsCandidate right) {
    if (_titleScore(left.title, right.title) < 92) return false;
    if (_artistScore(
          _splitArtists(left.artists),
          _splitArtists(right.artists),
        ) <
        85) {
      return false;
    }
    final delta = _knownDurationDelta(left.durationMs, right.durationMs);
    return delta == null || delta <= policy.maximumDurationDeltaMs;
  }

  double _titleScore(String left, String right) {
    final normalizedLeft = normalizeForMatch(left);
    final normalizedRight = normalizeForMatch(right);
    if (normalizedLeft == normalizedRight) return 100.0;
    final full = sequenceRatio(normalizedLeft, normalizedRight) * 100.0;
    final baseLeft = _stripVersionTags(normalizedLeft);
    final baseRight = _stripVersionTags(normalizedRight);
    final base = sequenceRatio(baseLeft, baseRight) * 95.0;
    return full > base ? full : base;
  }

  /// 歌手分：以较短一方为分母。在线库常只列主唱而本地标签是「A / B / C」，
  /// 若按较长名单计分，主唱完全一致也会被钉死在低分。
  /// 入参为已拆分归一化的名单（见 [_splitArtists]）。
  double _artistScore(List<String> local, List<String> remote) {
    if (local.isEmpty || remote.isEmpty) return 0.0;
    final shorter = local.length <= remote.length ? local : remote;
    final longer = local.length <= remote.length ? remote : local;
    final used = <int>{};
    var total = 0.0;
    for (final artist in shorter) {
      int? bestIndex;
      var bestRatio = -1.0;
      for (var i = 0; i < longer.length; i++) {
        if (used.contains(i)) continue;
        final ratio = sequenceRatio(artist, longer[i]);
        if (ratio > bestRatio) {
          bestRatio = ratio;
          bestIndex = i;
        }
      }
      if (bestIndex != null) {
        used.add(bestIndex);
        total += bestRatio;
      }
    }
    return total / shorter.length * 100.0;
  }

  double? _albumScore(String? local, String? remote) {
    final l = local?.trim();
    final r = remote?.trim();
    if (l == null || l.isEmpty || r == null || r.isEmpty) return null;
    return sequenceRatio(normalizeForMatch(l), normalizeForMatch(r)) * 100.0;
  }

  List<String> _splitArtists(List<String> values) => values
      .expand((value) => value
          .split(_artistSeparator)
          .map((v) => v.replaceAll(_featPrefix, '').trim()))
      .map(normalizeForMatch)
      .where((v) => v.isNotEmpty)
      .toSet()
      .toList();

  bool _hasHardVersionConflict(
    String local,
    String remote,
    bool remoteInstrumental,
  ) {
    final localFlags = _versionFlags(local);
    final remoteFlags = {..._versionFlags(remote)};
    if (remoteInstrumental) remoteFlags.add(_VersionFlag.instrumental);
    if (!localFlags.contains(_VersionFlag.instrumental) &&
        remoteFlags.contains(_VersionFlag.instrumental)) {
      return true;
    }
    final conflictFlags = [
      _VersionFlag.live,
      _VersionFlag.remix,
      _VersionFlag.acoustic,
      _VersionFlag.cover,
      _VersionFlag.edit,
      _VersionFlag.solo,
      _VersionFlag.short,
    ];
    return conflictFlags
        .any((flag) => localFlags.contains(flag) != remoteFlags.contains(flag));
  }

  Set<_VersionFlag> _versionFlags(String value) {
    final normalized = normalizeForMatch(value);
    return {
      for (final flag in _VersionFlag.values)
        if (flag.pattern.hasMatch(normalized)) flag,
    };
  }

  String _stripVersionTags(String value) {
    var text = value;
    for (final flag in _VersionFlag.values) {
      text = text.replaceAll(flag.pattern, ' ');
    }
    text = text.replaceAll(_versionDecoration, ' ');
    text = text.replaceAll(_whitespace, ' ');
    return text.trim();
  }

  int? _knownDurationDelta(int? left, int? right) {
    if (left != null && left > 0 && right != null && right > 0) {
      return (left - right).abs();
    }
    return null;
  }

  static final RegExp _artistSeparator = RegExp(
    r'\s*(?:/|、|,|，|&|＆|;|；|·|・|\bfeat\.?\b|\bft\.?\b)\s*',
    caseSensitive: false,
  );
  static final RegExp _featPrefix =
      RegExp(r'^(?:feat\.?|ft\.?)\s*', caseSensitive: false);
  static final RegExp _versionDecoration = RegExp(r'[()\[\]{}<>_-]+');
  static final RegExp _whitespace = RegExp(r'\s+');
}

/// 版本标记。枚举的 const 构造无法持有运行期 RegExp，改用静态实例。
class _VersionFlag {
  final RegExp pattern;

  const _VersionFlag._(this.pattern);

  static final _VersionFlag instrumental = _VersionFlag._(
    RegExp(r'(?:^|\W)(?:inst(?:rumental)?|off\s*vocal|伴奏|纯音乐)(?:$|\W)'),
  );
  static final _VersionFlag live = _VersionFlag._(
    RegExp(r'(?:^|\W)(?:live|现场|演唱会)(?:$|\W)'),
  );
  // mix(?:ed)? 覆盖 "mixed"/"mixed ver"。
  static final _VersionFlag remix = _VersionFlag._(
    RegExp(r'(?:^|\W)(?:remix|mix(?:ed)?|混音)(?:$|\W)'),
  );
  static final _VersionFlag acoustic = _VersionFlag._(
    RegExp(r'(?:^|\W)(?:acoustic|unplugged|不插电)(?:$|\W)'),
  );
  static final _VersionFlag cover = _VersionFlag._(
    RegExp(r'(?:^|\W)(?:cover|翻唱)(?:$|\W)'),
  );
  // 必须用完整词「剪辑版/编辑版」，否则「专辑版」的子串会被误命中。
  static final _VersionFlag edit = _VersionFlag._(
    RegExp(r'(?:^|\W)(?:edit(?:ed)?|剪辑版|编辑版)(?:$|\W)'),
  );
  static final _VersionFlag solo = _VersionFlag._(
    RegExp(r'(?:^|\W)(?:solo|独唱版)(?:$|\W)'),
  );
  // サイズ必须带 tv/アニメ 前缀，裸サイズ会误报任何含该词的日文歌名。
  static final _VersionFlag short = _VersionFlag._(
    RegExp(
      r'(?:^|\W)(?:tv\s*size|anime\s*size|radio\s*edit|short\s*ver|(?:tv|アニメ)\s*サイズ)(?:$|\W)',
    ),
  );

  static final List<_VersionFlag> values = [
    instrumental,
    live,
    remix,
    acoustic,
    cover,
    edit,
    solo,
    short,
  ];
}

/// 匹配用归一化：全角→半角、小写、连续空白折叠。
///
/// Java 版用 NFKC；Dart 无内建 NFKC，这里覆盖标题/歌手比对里唯一实际
/// 相关的部分（全角 ASCII 区 U+FF01–FF5E 与全角空格）。
String normalizeForMatch(String value) {
  final buffer = StringBuffer();
  for (final code in value.runes) {
    if (code >= 0xFF01 && code <= 0xFF5E) {
      buffer.writeCharCode(code - 0xFEE0);
    } else if (code == 0x3000) {
      buffer.write(' ');
    } else {
      buffer.writeCharCode(code);
    }
  }
  return buffer
      .toString()
      .toLowerCase()
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

/// difflib 风格的相似度：最长匹配块递归（Python `SequenceMatcher.ratio`）。
double sequenceRatio(String left, String right) {
  if (left == right) return 1.0;
  if (left.isEmpty || right.isEmpty) return 0.0;
  final leftPoints = left.runes.toList();
  final rightPoints = right.runes.toList();
  var matches = 0;
  for (final block in _matchingBlocks(
    leftPoints,
    0,
    leftPoints.length,
    rightPoints,
    0,
    rightPoints.length,
  )) {
    matches += block.size;
  }
  return 2.0 * matches / (leftPoints.length + rightPoints.length);
}

class _MatchBlock {
  final int left;
  final int right;
  final int size;

  const _MatchBlock(this.left, this.right, this.size);
}

List<_MatchBlock> _matchingBlocks(
  List<int> left,
  int leftStart,
  int leftEnd,
  List<int> right,
  int rightStart,
  int rightEnd,
) {
  final longest = _longestMatch(
    left,
    leftStart,
    leftEnd,
    right,
    rightStart,
    rightEnd,
  );
  if (longest.size == 0) return const [];
  final before = _matchingBlocks(
    left,
    leftStart,
    longest.left,
    right,
    rightStart,
    longest.right,
  );
  final after = _matchingBlocks(
    left,
    longest.left + longest.size,
    leftEnd,
    right,
    longest.right + longest.size,
    rightEnd,
  );
  return [...before, longest, ...after];
}

_MatchBlock _longestMatch(
  List<int> left,
  int leftStart,
  int leftEnd,
  List<int> right,
  int rightStart,
  int rightEnd,
) {
  var bestLeft = leftStart;
  var bestRight = rightStart;
  var bestSize = 0;
  var previous = <int, int>{};
  for (var leftIndex = leftStart; leftIndex < leftEnd; leftIndex++) {
    final current = <int, int>{};
    for (var rightIndex = rightStart; rightIndex < rightEnd; rightIndex++) {
      if (left[leftIndex] != right[rightIndex]) continue;
      final size = (previous[rightIndex - 1] ?? 0) + 1;
      current[rightIndex] = size;
      if (size > bestSize) {
        bestLeft = leftIndex - size + 1;
        bestRight = rightIndex - size + 1;
        bestSize = size;
      }
    }
    previous = current;
  }
  return _MatchBlock(bestLeft, bestRight, bestSize);
}
