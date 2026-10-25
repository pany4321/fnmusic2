/// 四个内置在线歌词源：网易云、QQ 音乐、酷狗、LRCLIB。
///
/// 移植自 fn-music（GPL-3.0-only）core/lyrics 的 OnlineLyricsSources.kt
/// （其上游为 LDDC；LRCLIB 按 https://lrclib.net/docs 公开文档实现）。
/// 各源的搜索词形态、接口选择与失败降级路径都有实测依据，见各源注释。
library;

import 'dart:convert';

import 'crypto_codec.dart';
import 'http_client.dart';
import 'lyrics_parsers.dart';
import 'models.dart';

// ---------------------------------------------------------------------------
// JSON 取值辅助（对齐 Kotlin 的 objectAt/stringAt/longAt…）
// ---------------------------------------------------------------------------

Map<String, dynamic>? _objectAt(Map<String, dynamic>? json, String key) =>
    json?[key] is Map<String, dynamic> ? json![key] as Map<String, dynamic> : null;

List<dynamic>? _arrayAt(Map<String, dynamic>? json, String key) =>
    json?[key] is List ? json![key] as List<dynamic> : null;

String? _stringAt(Map<String, dynamic>? json, String key) {
  final value = json?[key];
  if (value == null || value is bool) return null;
  if (value is String) return value.isEmpty ? null : value;
  return value.toString();
}

int? _intAt(Map<String, dynamic>? json, String key) {
  final value = json?[key];
  if (value is int) return value;
  if (value is num) return value.round();
  if (value is String) return int.tryParse(value);
  return null;
}

double? _doubleAt(Map<String, dynamic>? json, String key) =>
    json?[key] is num ? (json![key] as num).toDouble() : null;

bool? _boolAt(Map<String, dynamic>? json, String key) =>
    json?[key] is bool ? json![key] as bool : null;

Map<String, dynamic> _parseObject(String text) {
  try {
    final decoded = jsonDecode(text);
    if (decoded is Map<String, dynamic>) return decoded;
    throw LyricsPayloadException('Provider JSON is not an object');
  } on LyricsPayloadException {
    rethrow;
  } catch (e) {
    throw LyricsPayloadException('Invalid provider JSON: $e');
  }
}

List<dynamic> _parseArray(String text) {
  try {
    final decoded = jsonDecode(text);
    if (decoded is List) return decoded;
    throw LyricsPayloadException('Provider JSON is not an array');
  } on LyricsPayloadException {
    rethrow;
  } catch (e) {
    throw LyricsPayloadException('Invalid provider JSON: $e');
  }
}

OnlineLyricsDocument _requireUsable(OnlineLyricsDocument document) {
  if (!document.hasUsableLines) {
    throw LyricsPayloadException('Lyrics are empty');
  }
  return document;
}

String _stripMarkup(String value) =>
    decodeHtmlEntities(value.replaceAll(RegExp(r'<[^>]+>'), '')).trim();

// ---------------------------------------------------------------------------
// 网易云
// ---------------------------------------------------------------------------

class NeteaseLyricsSource extends OnlineLyricsSource {
  NeteaseLyricsSource(this._http);

  final LyricsHttpClient _http;

  @override
  OnlineSourceId get id => OnlineSourceId.netease;

  static const _headers = {'Referer': 'https://music.163.com/'};

  @override
  Future<List<OnlineLyricsCandidate>> search(LyricsSearchQuery query) async {
    final root = _parseObject(await _http.get(
      'https://music.163.com/api/search/get/web',
      query: {
        's': query.keyword,
        'type': '1',
        'limit': '20',
        'offset': '0',
      },
      headers: _headers,
    ));
    final songs = _arrayAt(_objectAt(root, 'result'), 'songs') ?? const [];
    final candidates = <OnlineLyricsCandidate>[];
    for (final item in songs) {
      if (item is! Map<String, dynamic>) continue;
      final remoteId = _stringAt(item, 'id');
      final title = _stringAt(item, 'name');
      if (remoteId == null || title == null || title.trim().isEmpty) continue;
      final artistEntries = _arrayAt(item, 'artists') ?? _arrayAt(item, 'ar');
      final artists = <String>[];
      for (final artist in artistEntries ?? const []) {
        if (artist is Map<String, dynamic>) {
          final name = _stringAt(artist, 'name');
          if (name != null && name.trim().isNotEmpty) artists.add(name);
        }
      }
      final album =
          _objectAt(item, 'album') ?? _objectAt(item, 'al');
      candidates.add(OnlineLyricsCandidate(
        source: id,
        remoteId: remoteId,
        title: title,
        artists: artists,
        album: _stringAt(album, 'name'),
        durationMs: _intAt(item, 'duration') ?? _intAt(item, 'dt'),
      ));
    }
    return candidates;
  }

  @override
  Future<OnlineLyricsDocument> fetch(OnlineLyricsCandidate candidate) async {
    final root = _parseObject(await _http.get(
      'https://music.163.com/api/song/lyric',
      query: {
        'id': candidate.remoteId,
        'lv': '1',
        'kv': '1',
        'tv': '1',
        'yv': '1',
        'rv': '1',
      },
      headers: _headers,
    ));
    // yrc（逐字）优先，lrc 兜底；tlyric 翻译、romalrc 注音。
    final yrc = _stringAt(_objectAt(root, 'yrc'), 'lyric') ?? '';
    final lrc = _stringAt(_objectAt(root, 'lrc'), 'lyric') ?? '';
    final original = yrc.isNotEmpty ? yrc : lrc;
    return _requireUsable(parseLyricsDocument(
      original,
      translation: _stringAt(_objectAt(root, 'tlyric'), 'lyric'),
      phonetic: _stringAt(_objectAt(root, 'romalrc'), 'lyric'),
    ));
  }
}

// ---------------------------------------------------------------------------
// QQ 音乐
// ---------------------------------------------------------------------------

/// QQ 音乐：逐字（QRC）覆盖最好的一家。
///
/// 搜索走桌面客户端接口 `DoSearchForQQMusicDesktop`（快，一次 15 条，字段
/// 齐全）。老接口 `client_search_cp` 召回更好但实测中位 3 秒，只应放在
/// 第二轮深挖（[deepSearch]）。
///
/// 桌面搜索**只认标题**（带歌手会把合辑标签带偏），故 [supportsKeywordVariants]
/// 仅深挖模式为 true；歌手对不对交给评分器判断。
class QqMusicLyricsSource extends OnlineLyricsSource {
  QqMusicLyricsSource(this._http, {this.deepSearch = false});

  final LyricsHttpClient _http;

  /// true = 用老搜索接口 `client_search_cp`（召回最好但慢，关键词用
  /// 「歌手 - 标题」）；false = 用桌面搜索接口（快，只认标题）。
  final bool deepSearch;

  @override
  OnlineSourceId get id => OnlineSourceId.qqMusic;

  @override
  bool get supportsKeywordVariants => deepSearch;

  static const _musicuUrl = 'https://u.y.qq.com/cgi-bin/musicu.fcg';
  static const _clientSearchUrl =
      'https://c.y.qq.com/soso/fcgi-bin/client_search_cp';
  static const _lrcUrl =
      'https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg';
  static const _webHeaders = {'Referer': 'https://y.qq.com/'};
  static const _nativeHeaders = {
    'Cookie': 'tmeLoginType=-1;',
    'User-Agent': 'okhttp/3.14.9',
  };

  static const _maxCandidates = 20;
  static const _maxDeepCandidates = 30;

  @override
  Future<List<OnlineLyricsCandidate>> search(LyricsSearchQuery query) =>
      deepSearch ? _deepSearchCandidates(query) : _liteSearchCandidates(query);

  Future<List<OnlineLyricsCandidate>> _deepSearchCandidates(
    LyricsSearchQuery query,
  ) async {
    final keyword = query.keyword.trim().isNotEmpty
        ? query.keyword.trim()
        : query.request.title.trim();
    if (keyword.isEmpty) return const [];
    final root = _parseObject(await _http.get(
      _clientSearchUrl,
      query: {
        'w': keyword,
        'format': 'json',
        'p': '1',
        'n': '30',
        'cr': '1',
        'g_tk': '5381',
      },
      headers: _webHeaders,
    ));
    final list = _arrayAt(
          _objectAt(_objectAt(root, 'data'), 'song'),
          'list',
        ) ??
        const [];
    final candidates = <OnlineLyricsCandidate>[];
    for (final item in list.take(_maxDeepCandidates)) {
      if (item is! Map<String, dynamic>) continue;
      final candidate = _deepCandidate(item);
      if (candidate != null) candidates.add(candidate);
    }
    return candidates;
  }

  OnlineLyricsCandidate? _deepCandidate(Map<String, dynamic> song) {
    final remoteId = _stringAt(song, 'songid');
    if (remoteId == null) return null;
    final title = decodeHtmlEntities(_stringAt(song, 'songname') ?? '').trim();
    if (title.isEmpty) return null;
    return OnlineLyricsCandidate(
      source: id,
      remoteId: remoteId,
      mediaId: _stringAt(song, 'songmid'),
      title: title,
      artists: _readSingers(song),
      album: _stringAt(song, 'albumname'),
      durationMs: _positiveDuration(_intAt(song, 'interval'), 1000),
      instrumental: _intAt(song, 'pure') == 1,
    );
  }

  Future<List<OnlineLyricsCandidate>> _liteSearchCandidates(
    LyricsSearchQuery query,
  ) async {
    final title = query.request.title.trim();
    if (title.isEmpty) return const [];
    final body = jsonEncode({
      'comm': {'ct': '19', 'cv': '1859', 'uin': '0'},
      'req': {
        'method': 'DoSearchForQQMusicDesktop',
        'module': 'music.search.SearchCgiService',
        'param': {
          'num_per_page': '$_maxCandidates',
          'page_num': '1',
          'query': title,
          'search_type': 0,
        },
      },
    });
    final root = _parseObject(
      await _http.post(_musicuUrl, body, headers: _nativeHeaders),
    );
    final song = _objectAt(
      _objectAt(_objectAt(_objectAt(root, 'req'), 'data'), 'body'),
      'song',
    );
    final list = _arrayAt(song, 'list') ?? const [];
    final candidates = <OnlineLyricsCandidate>[];
    for (final item in list.take(_maxCandidates)) {
      if (item is! Map<String, dynamic>) continue;
      final candidate = _liteCandidate(item);
      if (candidate != null) candidates.add(candidate);
    }
    return candidates;
  }

  OnlineLyricsCandidate? _liteCandidate(Map<String, dynamic> song) {
    final remoteId = _intAt(song, 'id')?.toString() ?? _stringAt(song, 'id');
    if (remoteId == null || remoteId.isEmpty) return null;
    final title = decodeHtmlEntities(_stringAt(song, 'title') ?? '').trim();
    if (title.isEmpty) return null;
    return OnlineLyricsCandidate(
      source: id,
      remoteId: remoteId,
      mediaId: _stringAt(song, 'mid'),
      title: title,
      artists: _readSingers(song),
      album: _stringAt(_objectAt(song, 'album'), 'name'),
      durationMs: _positiveDuration(_intAt(song, 'interval'), 1000),
    );
  }

  List<String> _readSingers(Map<String, dynamic> song) {
    final singers = <String>[];
    for (final item in _arrayAt(song, 'singer') ?? const []) {
      if (item is! Map<String, dynamic>) continue;
      final name = decodeHtmlEntities(_stringAt(item, 'name') ?? '').trim();
      if (name.isNotEmpty) singers.add(name);
    }
    return singers;
  }

  int? _positiveDuration(int? seconds, int scaleMs) {
    if (seconds == null || seconds <= 0) return null;
    return seconds * scaleMs;
  }

  @override
  Future<OnlineLyricsDocument> fetch(OnlineLyricsCandidate candidate) async {
    try {
      return await _fetchNativeQrc(candidate);
    } on LyricsPayloadException {
      return _fetchLrc(candidate);
    }
  }

  /// 原生 QRC 接口：一次返回加密的逐字歌词、翻译与注音。
  Future<OnlineLyricsDocument> _fetchNativeQrc(
    OnlineLyricsCandidate candidate,
  ) async {
    final songId = int.tryParse(candidate.remoteId);
    if (songId == null) {
      throw LyricsPayloadException('QQ candidate has no numeric song ID');
    }
    final intervalSeconds =
        candidate.durationMs != null && candidate.durationMs! > 0
            ? candidate.durationMs! ~/ 1000
            : 0;
    final body = jsonEncode({
      'comm': {'ct': 19, 'cv': 2111, 'uin': '0'},
      'request': {
        'module': 'music.musichallSong.PlayLyricInfo',
        'method': 'GetPlayLyricInfo',
        'param': {
          'albumName': encodeBase64(candidate.album ?? ''),
          'crypt': 1,
          'ct': 19,
          'cv': 2111,
          'interval': intervalSeconds,
          'lrc_t': 0,
          'qrc': 1,
          'qrc_t': 0,
          'roma': 1,
          'roma_t': 0,
          'singerName': encodeBase64(candidate.artists.join(' / ')),
          'songID': songId,
          'songName': encodeBase64(candidate.title),
          'trans': 1,
          'trans_t': 0,
          'type': 0,
        },
      },
    });
    final root = _parseObject(
      await _http.post(_musicuUrl, body, headers: _nativeHeaders),
    );
    final data = _objectAt(_objectAt(root, 'request'), 'data');
    if (data == null) {
      throw LyricsPayloadException('QQ QRC response has no data');
    }
    final original = decodeQqNativeField(_stringAt(data, 'lyric'));
    if (original.trim().isEmpty) {
      throw LyricsPayloadException('QQ QRC lyrics are empty');
    }
    String? decodeOptional(String? encrypted) {
      if (encrypted == null || encrypted.trim().isEmpty) return null;
      try {
        return decodeQqNativeField(encrypted);
      } on LyricsPayloadException {
        return null;
      }
    }

    return _requireUsable(parseLyricsDocument(
      original,
      translation: decodeOptional(_stringAt(data, 'trans')),
      phonetic: decodeOptional(_stringAt(data, 'roma')),
    ));
  }

  /// 老接口兜底：返回行级 LRC + 翻译。
  Future<OnlineLyricsDocument> _fetchLrc(OnlineLyricsCandidate candidate) async {
    final mediaId = candidate.mediaId;
    if (mediaId == null || mediaId.isEmpty) {
      throw LyricsPayloadException('QQ candidate has no media ID');
    }
    final root = _parseObject(await _http.get(
      _lrcUrl,
      query: {
        'songmid': mediaId,
        'format': 'json',
        'nobase64': '1',
        'g_tk': '5381',
      },
      headers: _webHeaders,
    ));
    final original =
        decodeHtmlEntities(decodeLyricField(_stringAt(root, 'lyric')));
    final translation =
        decodeHtmlEntities(decodeLyricField(_stringAt(root, 'trans')));
    return _requireUsable(
      parseLyricsDocument(original, translation: translation),
    );
  }
}

// ---------------------------------------------------------------------------
// 酷狗
// ---------------------------------------------------------------------------

class KugouLyricsSource extends OnlineLyricsSource {
  KugouLyricsSource(this._http);

  final LyricsHttpClient _http;

  @override
  OnlineSourceId get id => OnlineSourceId.kugou;

  @override
  Future<List<OnlineLyricsCandidate>> search(LyricsSearchQuery query) async {
    final root = _parseObject(await _http.get(
      'https://songsearch.kugou.com/song_search_v2',
      query: {
        'keyword': query.keyword,
        'page': '1',
        'pagesize': '20',
        'platform': 'WebFilter',
        'userid': '-1',
        'clientver': '2000',
      },
    ));
    final lists = _arrayAt(_objectAt(root, 'data'), 'lists') ?? const [];
    final candidates = <OnlineLyricsCandidate>[];
    for (final item in lists) {
      if (item is! Map<String, dynamic>) continue;
      final remoteId = _stringAt(item, 'ID');
      if (remoteId == null) continue;
      final title = _stripMarkup(_stringAt(item, 'SongName') ?? '');
      if (title.isEmpty) continue;
      final singerNames = _stringAt(item, 'SingerName') ?? '';
      final artists = singerNames
          .split(RegExp(r'[、/&]'))
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
      final durationSeconds = _intAt(item, 'Duration') ??
          _intAt(item, 'SQDuration') ??
          _intAt(item, 'HQDuration');
      candidates.add(OnlineLyricsCandidate(
        source: id,
        remoteId: remoteId,
        title: title,
        artists: artists,
        album: _stringAt(item, 'AlbumName') != null
            ? _stripMarkup(_stringAt(item, 'AlbumName')!)
            : null,
        durationMs: durationSeconds == null ? null : durationSeconds * 1000,
        fileHash: _stringAt(item, 'FileHash') ??
            _stringAt(item, 'SQFileHash') ??
            _stringAt(item, 'HQFileHash'),
      ));
    }
    return candidates;
  }

  @override
  Future<OnlineLyricsDocument> fetch(OnlineLyricsCandidate candidate) async {
    final lyricCandidate = await _findLyricCandidate(candidate);
    try {
      return _requireUsable(await _download(lyricCandidate, 'krc'));
    } on LyricsPayloadException {
      return _requireUsable(await _download(lyricCandidate, 'lrc'));
    }
  }

  /// 歌词候选定位：时长最接近者优先，其次得分。
  Future<Map<String, dynamic>> _findLyricCandidate(
    OnlineLyricsCandidate candidate,
  ) async {
    final query = <String, String>{
      'ver': '1',
      'man': 'yes',
      'client': 'pc',
      'keyword':
          '${candidate.artists.isNotEmpty ? '${candidate.artists.first} - ' : ''}'
              '${candidate.title}',
    };
    if (candidate.durationMs != null) {
      query['duration'] = '${candidate.durationMs}';
    }
    final fileHash = candidate.fileHash;
    if (fileHash != null && fileHash.isNotEmpty) query['hash'] = fileHash;

    final root = _parseObject(
      await _http.get('https://lyrics.kugou.com/search', query: query),
    );
    Map<String, dynamic>? best;
    int? bestDurationDelta;
    int bestScore = -1;
    final candidateDuration = candidate.durationMs;
    for (final item in _arrayAt(root, 'candidates') ?? const []) {
      if (item is! Map<String, dynamic>) continue;
      final id = _stringAt(item, 'id');
      final accessKey = _stringAt(item, 'accesskey');
      if (id == null || accessKey == null) continue;
      final duration = _intAt(item, 'duration');
      final durationDelta = duration != null && candidateDuration != null
          ? (duration - candidateDuration).abs()
          : 1 << 40; // 未知时长排最后
      final score = _intAt(item, 'score') ?? 0;
      final better = best == null ||
          durationDelta < bestDurationDelta! ||
          (durationDelta == bestDurationDelta && score > bestScore);
      if (better) {
        best = item;
        bestDurationDelta = durationDelta;
        bestScore = score;
      }
    }
    if (best == null) {
      throw LyricsPayloadException('Kugou returned no lyric candidates');
    }
    return best;
  }

  Future<OnlineLyricsDocument> _download(
    Map<String, dynamic> candidate,
    String format,
  ) async {
    final body = _parseObject(await _http.get(
      'https://lyrics.kugou.com/download',
      query: {
        'ver': '1',
        'client': 'pc',
        'id': candidate['id'].toString(),
        'accesskey': candidate['accesskey'].toString(),
        'fmt': format,
        'charset': 'utf8',
      },
    ));
    final encoded = _stringAt(body, 'content') ?? '';
    if (encoded.isEmpty) {
      throw LyricsPayloadException('Kugou lyrics are empty');
    }
    // contenttype == 2 表示明文 lrc，否则 krc 需解密。
    final decoded = format == 'krc' && _intAt(body, 'contenttype') != 2
        ? decryptKrc(encoded)
        : decodeBase64(encoded);
    return parseLyricsDocument(decoded);
  }
}

// ---------------------------------------------------------------------------
// LRCLIB
// ---------------------------------------------------------------------------

/// LRCLIB（https://lrclib.net）：唯一有公开文档与使用条款的源，要求 UA
/// 标明客户端，并**必须**遵守 429 的 `Retry-After`。
///
/// - 只收有逐行同步歌词（`syncedLyrics`）的记录；
/// - 检索响应内联歌词，[fetch] 优先取用内联缓存，省一次 `/api/get`；
/// - 请求间隔 ≥200ms、429 后进入冷却（进程级共享）。
class LrclibLyricsSource extends OnlineLyricsSource {
  LrclibLyricsSource(this._http);

  final LyricsHttpClient _http;

  @override
  OnlineSourceId get id => OnlineSourceId.lrclib;

  static const _searchEndpoint = 'https://lrclib.net/api/search';
  static const _getEndpoint = 'https://lrclib.net/api/get';
  static const _defaultCooldownMs = 60 * 1000;
  static const _minCooldownMs = 1000;
  static const _maxCooldownMs = 10 * 60 * 1000;
  static const _maxInlineEntries = 64;
  static const _httpTooManyRequests = 429;

  /// 检索响应内联的逐行歌词，按 record id 暂存给 [fetch] 用（FIFO 有上限）。
  final Map<String, String> _inlineLyrics = {};

  @override
  Future<List<OnlineLyricsCandidate>> search(LyricsSearchQuery query) async {
    final title = query.request.title.trim();
    if (title.isEmpty) return const [];
    final keyword = query.keyword.trim().isNotEmpty
        ? query.keyword.trim()
        : _fallbackKeyword(query.request, title);
    final records =
        _parseArray(await _requestText(_searchEndpoint, {'q': keyword}));
    final candidates = <OnlineLyricsCandidate>[];
    for (final element in records) {
      if (element is! Map<String, dynamic>) continue;
      final remoteId = _intAt(element, 'id')?.toString();
      final trackName = _stringAt(element, 'trackName')?.trim();
      if (remoteId == null || trackName == null || trackName.isEmpty) continue;
      final synced = _stringAt(element, 'syncedLyrics') ?? '';
      if (synced.trim().isEmpty) continue;
      final artistName = _stringAt(element, 'artistName')?.trim() ?? '';
      final duration = _doubleAt(element, 'duration');
      candidates.add(OnlineLyricsCandidate(
        source: id,
        remoteId: remoteId,
        title: trackName,
        artists: artistName.isEmpty ? const [] : [artistName],
        album: _stringAt(element, 'albumName')?.trim(),
        durationMs: duration != null && duration > 0
            ? (duration * 1000).round()
            : null,
        instrumental: _boolAt(element, 'instrumental') ?? false,
      ));
      if (_inlineLyrics.length >= _maxInlineEntries) {
        _inlineLyrics.remove(_inlineLyrics.keys.first);
      }
      _inlineLyrics[remoteId] = synced;
    }
    return candidates;
  }

  @override
  Future<OnlineLyricsDocument> fetch(OnlineLyricsCandidate candidate) async {
    var synced = _inlineLyrics[candidate.remoteId];
    if (synced == null || synced.trim().isEmpty) {
      synced = _stringAt(
        _parseObject(await _requestText('$_getEndpoint/${candidate.remoteId}')),
        'syncedLyrics',
      ) ?? '';
    }
    if (synced.trim().isEmpty) {
      throw LyricsPayloadException('Lrclib record has no synced lyrics');
    }
    return _requireUsable(parseLyricsDocument(synced));
  }

  String _fallbackKeyword(OnlineLyricsRequest request, String title) {
    final artists = request.artists
        .map((a) => a.trim())
        .where((a) => a.isNotEmpty)
        .join(' - ');
    return artists.isEmpty ? title : '$artists - $title';
  }

  Future<String> _requestText(String url, [Map<String, String>? query]) async {
    if (LrclibRateLimiter.isCoolingDown()) {
      throw LyricsTransportException('Lrclib is cooling down after HTTP 429');
    }
    await LrclibRateLimiter.acquire();
    try {
      return await _http.get(url, query: query);
    } on LyricsTransportException catch (e) {
      if (e.status == _httpTooManyRequests) {
        final waitMs = (e.retryAfterMs ?? _defaultCooldownMs)
            .clamp(_minCooldownMs, _maxCooldownMs);
        LrclibRateLimiter.startCooldown(waitMs);
      }
      rethrow;
    }
  }
}

/// LRCLIB 的进程级共享限流：请求步调（≥200ms）与 429 冷却。
class LrclibRateLimiter {
  static const int interRequestDelayMs = 200;

  static DateTime _cooldownUntil = DateTime.fromMillisecondsSinceEpoch(0);
  static DateTime _nextSlot = DateTime.fromMillisecondsSinceEpoch(0);

  static bool isCoolingDown() => DateTime.now().isBefore(_cooldownUntil);

  static void startCooldown(int ms) {
    final until = DateTime.now().add(Duration(milliseconds: ms));
    if (until.isAfter(_cooldownUntil)) _cooldownUntil = until;
  }

  /// 预约一个请求位：并发的调用方各自拿到不同的时间槽。
  static Future<void> acquire() async {
    final now = DateTime.now();
    final slot = _nextSlot.isBefore(now) ? now : _nextSlot;
    _nextSlot = slot.add(const Duration(milliseconds: interRequestDelayMs));
    final wait = slot.difference(now);
    if (!wait.isNegative && wait.inMilliseconds > 0) {
      await Future<void>.delayed(wait);
    }
  }

  static void resetForTest() {
    _cooldownUntil = DateTime.fromMillisecondsSinceEpoch(0);
    _nextSlot = DateTime.fromMillisecondsSinceEpoch(0);
  }
}
