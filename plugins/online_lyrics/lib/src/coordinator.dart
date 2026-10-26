/// 歌词匹配编排：两轮取词。
///
/// 移植自 fn-music（GPL-3.0-only）core/lyrics 的 LyricsMatchCoordinator.kt
/// （其上游为 LDDC）。
///
/// 第一轮只跑快源（各家搜索都在预算内），命中直接返回；只有一首都没命中
/// 才进入第二轮「深挖」——用更宽的预算跑召回好但慢的通道（QQ 的
/// `client_search_cp`）。既不为慢源牺牲普遍延迟，又不放弃它们的召回。
///
/// 单源超时各自独立计时（搜索最多两次 + 取词最多 3 个候选），另有轮级
/// 整体预算兜底，避免最坏情况把歌词上屏拖到几十秒。
library;

import 'async_race.dart';
import 'match_policy.dart';
import 'models.dart';
import 'traditional_to_simplified.dart';

Duration _deadline(int ms) => Duration(milliseconds: ms);

enum LyricsFailureKind { networkFailure, invalidResponse }

/// 协调结果：[found] 非空即命中；否则 [failure] 为 null 表示「确实没有」，
/// 非 null 表示失败原因（可重试/可提示）。
class CoordinatorResult {
  final OnlineLyricsMatch? found;
  final LyricsFailureKind? failure;

  const CoordinatorResult.found(OnlineLyricsMatch match)
      : found = match,
        failure = null;

  const CoordinatorResult.miss(this.failure) : found = null;
}

class LyricsMatchCoordinator {
  LyricsMatchCoordinator({
    required List<OnlineLyricsSource> sources,
    this.policy = const LyricsMatchPolicy(),
    this.sourceTimeoutMs = 1800,
    List<OnlineLyricsSource> deepSources = const [],
    this.deepSourceTimeoutMs = 4500,
    LyricsCandidateScorer? scorer,
  })  : sources = _distinctById(sources),
        deepSources = _distinctById(deepSources),
        scorer = scorer ?? LyricsCandidateScorer(policy);

  final List<OnlineLyricsSource> sources;
  final List<OnlineLyricsSource> deepSources;
  final LyricsMatchPolicy policy;
  final int sourceTimeoutMs;
  final int deepSourceTimeoutMs;
  final LyricsCandidateScorer scorer;

  static const int _maxFetchAttemptsPerSource = 3;
  static const int _fastRoundDeadlineMs = 8000;
  static const int _deepRoundDeadlineMs = 14000;

  static List<OnlineLyricsSource> _distinctById(List<OnlineLyricsSource> list) {
    final seen = <OnlineSourceId>{};
    return list.where((s) => seen.add(s.id)).toList();
  }

  Future<CoordinatorResult> match(OnlineLyricsRequest request) async {
    if (request.title.trim().isEmpty ||
        (sources.isEmpty && deepSources.isEmpty)) {
      return const CoordinatorResult.miss(null);
    }
    return _matchAllSources(request);
  }

  Future<CoordinatorResult> _matchAllSources(OnlineLyricsRequest request) async {
    final fast = await withDeadline(
      _runRound(sources, sourceTimeoutMs, request),
      _deadline(_fastRoundDeadlineMs),
      () => _RoundOutcome(failure: LyricsFailureKind.networkFailure),
    );
    if (fast.found != null) {
      return CoordinatorResult.found(fast.found!);
    }

    // 离线短路：快源全体网络失败（不是「没搜到」）时，深挖轮只会同样失败。
    final offline = fast.searchOutcomes.isNotEmpty &&
        fast.searchOutcomes
            .every((o) => o.failure == LyricsFailureKind.networkFailure);
    _RoundOutcome deep;
    if (deepSources.isEmpty || offline) {
      deep = _RoundOutcome();
    } else {
      deep = await withDeadline(
        _runRound(deepSources, deepSourceTimeoutMs, request),
        _deadline(_deepRoundDeadlineMs),
        () => _RoundOutcome(failure: LyricsFailureKind.networkFailure),
      );
    }
    if (deep.found != null) {
      return CoordinatorResult.found(deep.found!);
    }
    return CoordinatorResult.miss(_classifyFailure([fast, deep]));
  }

  Future<_RoundOutcome> _runRound(
    List<OnlineLyricsSource> roundSources,
    int timeoutMs,
    OnlineLyricsRequest request,
  ) async {
    final primaryKeyword = _primaryKeyword(request);
    final searchOutcomes = await Future.wait(
      roundSources.map((s) => _searchSource(s, primaryKeyword, request, timeoutMs)),
    );
    final ranked = scorer.score(
      request,
      searchOutcomes.expand((o) => o.candidates).toList(),
    );

    final fetchOutcomes = await Future.wait(
      roundSources.map((source) {
        final sourceCandidates = ranked
            .where((s) => s.candidate.source == source.id)
            .toList()
          ..sort((a, b) {
            final byMetadata =
                b.metadataScore.compareTo(a.metadataScore);
            if (byMetadata != 0) return byMetadata;
            final byConsensus =
                b.consensusCount.compareTo(a.consensusCount);
            if (byConsensus != 0) return byConsensus;
            return a.candidate.remoteId.compareTo(b.candidate.remoteId);
          });
        return _fetchSource(
          source,
          sourceCandidates.take(_maxFetchAttemptsPerSource).toList(),
          request,
          timeoutMs,
        );
      }),
    );

    final matches = fetchOutcomes.expand((o) => o.matches).toList();
    OnlineLyricsMatch? found;
    if (matches.isNotEmpty) {
      matches.sort(_compareByContent);
      final selected = matches.first;
      found = OnlineLyricsMatch(
        source: selected.scored.candidate.source,
        candidate: selected.scored.candidate,
        score: selected.scored.score,
        document: selected.document,
      );
    }
    return _RoundOutcome(
      searchOutcomes: searchOutcomes,
      fetchOutcomes: fetchOutcomes,
      found: found,
    );
  }

  String _primaryKeyword(OnlineLyricsRequest request) {
    final artists = request.artists
        .map((a) => a.trim())
        .where((a) => a.isNotEmpty)
        .join(' / ');
    return artists.isEmpty ? request.title : '$artists - ${request.title}';
  }

  /// 主关键词搜索 + （需要时）纯标题重试。
  ///
  /// 重试与主搜索分开捕获异常：重试失败只记录失败、保留主候选 —— 共用
  /// try 块时「主搜索成功但重试超时」会把整个源标成网络故障且候选清零。
  Future<_SearchOutcome> _searchSource(
    OnlineLyricsSource source,
    String primaryKeyword,
    OnlineLyricsRequest request,
    int timeoutMs,
  ) async {
    final collected = <OnlineLyricsCandidate>[];
    final seen = <String>{};
    void merge(List<OnlineLyricsCandidate> rows) {
      for (final row in rows) {
        if (seen.add('${row.source}:${row.remoteId}')) collected.add(row);
      }
    }

    // ① 主关键词「歌手 - 标题」。
    try {
      merge(await _search(source, primaryKeyword, request, timeoutMs));
    } on LyricsTransportException {
      return _SearchOutcome(source, const [],
          LyricsFailureKind.networkFailure);
    } on LyricsPayloadException {
      return _SearchOutcome(source, const [],
          LyricsFailureKind.invalidResponse);
    } catch (e) {
      return _SearchOutcome(
          source, const [], LyricsFailureKind.invalidResponse);
    }

    // ② 纯标题重试：部分源（QQ 桌面搜索）带歌手会把结果带偏。
    LyricsFailureKind? failure;
    if (primaryKeyword != request.title &&
        source.supportsKeywordVariants &&
        scorer.score(request, collected).isEmpty) {
      try {
        merge(await _search(source, request.title, request, timeoutMs));
      } on LyricsTransportException {
        failure = _combineFailure(failure, LyricsFailureKind.networkFailure);
      } on LyricsPayloadException {
        failure = _combineFailure(failure, LyricsFailureKind.invalidResponse);
      } catch (e) {
        failure = _combineFailure(failure, LyricsFailureKind.invalidResponse);
      }
    }

    // ③ 繁→简重试（召回兜底）。
    //
    // 港台发行/老专辑的标签常是繁体（春風秋雨、葉蒨文），中文平台的搜索
    // 对繁体输入召回很差 —— 实测这类曲目四个源全部落空，换成简体后能命中。
    // 只在前两轮都没产生合格候选、且文本确实含繁体字时才发这一次请求；
    // 转换同时作用于关键词与 request（QQ 桌面搜索只吃标题，必须转 title）。
    if (scorer.score(request, collected).isEmpty) {
      final simplifiedRequest = _simplifiedRequest(request);
      final simplifiedKeyword = toSimplified(primaryKeyword);
      final keywordChanged = simplifiedKeyword != primaryKeyword;
      final requestChanged = !identical(simplifiedRequest, request);
      if (keywordChanged || requestChanged) {
        try {
          merge(await _search(
            source,
            keywordChanged ? simplifiedKeyword : simplifiedRequest.title,
            simplifiedRequest,
            timeoutMs,
          ));
        } on LyricsTransportException {
          failure =
              _combineFailure(failure, LyricsFailureKind.networkFailure);
        } on LyricsPayloadException {
          failure =
              _combineFailure(failure, LyricsFailureKind.invalidResponse);
        } catch (e) {
          failure =
              _combineFailure(failure, LyricsFailureKind.invalidResponse);
        }
      }
    }
    return _SearchOutcome(source, collected, failure);
  }

  /// 繁→简后的请求副本；无需转换时原样返回同一实例（调用方用
  /// `identical` 判断是否需要重试）。
  OnlineLyricsRequest _simplifiedRequest(OnlineLyricsRequest request) {
    final title = toSimplified(request.title);
    final artists = request.artists.map(toSimplified).toList();
    final album = request.album == null ? null : toSimplified(request.album!);
    final unchanged = title == request.title &&
        album == request.album &&
        _listEquals(artists, request.artists);
    if (unchanged) return request;
    return OnlineLyricsRequest(
      title: title,
      artists: artists,
      album: album,
      durationMs: request.durationMs,
    );
  }

  bool _listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Future<List<OnlineLyricsCandidate>> _search(
    OnlineLyricsSource source,
    String keyword,
    OnlineLyricsRequest request,
    int timeoutMs,
  ) {
    return source
        .search(LyricsSearchQuery(keyword, request))
        .timeout(
          Duration(milliseconds: timeoutMs),
          onTimeout: () => throw LyricsTransportException(
            '${source.id} search timed out',
          ),
        );
  }

  Future<_FetchOutcome> _fetchSource(
    OnlineLyricsSource source,
    List<ScoredLyricsCandidate> candidates,
    OnlineLyricsRequest request,
    int timeoutMs,
  ) async {
    if (candidates.isEmpty) return _FetchOutcome();

    LyricsFailureKind? failure;
    final matches = <_ProviderMatch>[];
    for (final scored in candidates) {
      try {
        final document = await source.fetch(scored.candidate).timeout(
              Duration(milliseconds: timeoutMs),
              onTimeout: () => throw LyricsTransportException(
                '${source.id} lyrics timed out',
              ),
            );
        if (!document.hasUsableLines) {
          failure = failure ?? LyricsFailureKind.invalidResponse;
          continue;
        }
        final durationDeltaMs = _knownDurationDelta(
          request.durationMs,
          scored.candidate.durationMs,
        );
        final wordEligible = durationDeltaMs != null &&
            durationDeltaMs <= policy.maximumWordTimingDeltaMs &&
            document.wordTimedCoverage > 0;
        final eligible =
            wordEligible ? document : document.withoutWordTiming();
        matches.add(_ProviderMatch(
          scored: scored,
          document: eligible,
          durationDeltaMs: durationDeltaMs,
          wordEligible: wordEligible,
        ));
      } on LyricsTransportException {
        failure = _combineFailure(failure, LyricsFailureKind.networkFailure);
      } on LyricsPayloadException {
        failure = _combineFailure(failure, LyricsFailureKind.invalidResponse);
      } catch (e) {
        failure = _combineFailure(failure, LyricsFailureKind.invalidResponse);
      }
    }
    return _FetchOutcome(
      matches: matches,
      failure: failure ??
          (matches.isEmpty ? LyricsFailureKind.invalidResponse : null),
    );
  }

  /// 内容择优：有翻译 > 翻译覆盖高 > 逐字可用 > 时长接近 > 源优先序。
  int _compareByContent(_ProviderMatch a, _ProviderMatch b) {
    final aCoverage = _translationCoverage(a);
    final bCoverage = _translationCoverage(b);
    final byHasTranslation =
        (bCoverage > 0 ? 1 : 0).compareTo(aCoverage > 0 ? 1 : 0);
    if (byHasTranslation != 0) return byHasTranslation;
    final byCoverage = bCoverage.compareTo(aCoverage);
    if (byCoverage != 0) return byCoverage;
    final byWord = (b.wordEligible ? 1 : 0).compareTo(a.wordEligible ? 1 : 0);
    if (byWord != 0) return byWord;
    final aDelta = a.durationDeltaMs ?? 0x7fffffffffffffff;
    final bDelta = b.durationDeltaMs ?? 0x7fffffffffffffff;
    final byDelta = aDelta.compareTo(bDelta);
    if (byDelta != 0) return byDelta;
    final bySource = _sourceOrderIndex(a.scored.candidate.source)
        .compareTo(_sourceOrderIndex(b.scored.candidate.source));
    if (bySource != 0) return bySource;
    return a.scored.candidate.remoteId.compareTo(b.scored.candidate.remoteId);
  }

  double _translationCoverage(_ProviderMatch match) {
    final usable = match.document.lines
        .where((l) => l.text.trim().isNotEmpty)
        .length;
    if (usable == 0) return 0;
    return match.document.translatedLineCount / usable;
  }

  int _sourceOrderIndex(OnlineSourceId source) {
    final index = policy.sourceOrder.indexOf(source);
    return index >= 0 ? index : 1 << 30;
  }

  int? _knownDurationDelta(int? left, int? right) {
    if (left != null && left > 0 && right != null && right > 0) {
      return (left - right).abs();
    }
    return null;
  }

  LyricsFailureKind? _classifyFailure(List<_RoundOutcome> rounds) {
    final failures = <LyricsFailureKind>[];
    for (final round in rounds) {
      for (final search in round.searchOutcomes) {
        if (search.failure != null) failures.add(search.failure!);
      }
      for (final fetch in round.fetchOutcomes) {
        if (fetch.failure != null) failures.add(fetch.failure!);
      }
      if (round.failure != null) failures.add(round.failure!);
    }
    if (failures.contains(LyricsFailureKind.invalidResponse)) {
      return LyricsFailureKind.invalidResponse;
    }
    if (failures.contains(LyricsFailureKind.networkFailure)) {
      return LyricsFailureKind.networkFailure;
    }
    return null;
  }

  LyricsFailureKind _combineFailure(
    LyricsFailureKind? current,
    LyricsFailureKind incoming,
  ) =>
      current == LyricsFailureKind.invalidResponse || 
              incoming == LyricsFailureKind.invalidResponse
          ? LyricsFailureKind.invalidResponse
          : incoming;
}

class _RoundOutcome {
  final List<_SearchOutcome> searchOutcomes;
  final List<_FetchOutcome> fetchOutcomes;
  final OnlineLyricsMatch? found;

  /// 轮级整体预算超时时的失败标记（此时 searchOutcomes 已不可得）。
  final LyricsFailureKind? failure;

  const _RoundOutcome({
    this.searchOutcomes = const [],
    this.fetchOutcomes = const [],
    this.found,
    this.failure,
  });
}

class _SearchOutcome {
  final OnlineLyricsSource source;
  final List<OnlineLyricsCandidate> candidates;
  final LyricsFailureKind? failure;

  const _SearchOutcome(this.source, this.candidates, [this.failure]);
}

class _FetchOutcome {
  final List<_ProviderMatch> matches;
  final LyricsFailureKind? failure;

  const _FetchOutcome({this.matches = const [], this.failure});
}

class _ProviderMatch {
  final ScoredLyricsCandidate scored;
  final OnlineLyricsDocument document;
  final int? durationDeltaMs;
  final bool wordEligible;

  const _ProviderMatch({
    required this.scored,
    required this.document,
    required this.durationDeltaMs,
    required this.wordEligible,
  });
}
