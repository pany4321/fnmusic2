// 离线单元测试：解析器、加解密、评分器与编排器（不触网）。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:online_lyrics/src/crypto_codec.dart';
import 'package:online_lyrics/src/lyrics_parsers.dart';
import 'package:online_lyrics/src/match_policy.dart';
import 'package:online_lyrics/src/models.dart';
import 'package:online_lyrics/src/coordinator.dart';
import 'package:test/test.dart';

void main() {
  group('parseLyricsDocument', () {
    test('标准 LRC + 同时间戳翻译行合并', () {
      final doc = parseLyricsDocument(
        '[00:01.25]Hello\n[00:01.25]你好\n[00:03.500]World',
      );
      expect(doc.lines, hasLength(2));
      expect(doc.lines.first.startMs, 1250);
      expect(doc.lines.first.text, 'Hello');
      expect(doc.translationLines.first.text, '你好');
      expect(doc.translatedLineCount, 1);
    });

    test('YRC 逐词时间戳保留 + 假名注音剔除', () {
      final doc = parseLyricsDocument(
        '[1000,1500](1000,300,0)世(1300,100,0)（(1400,300,0)よ(1700,100,0)）(1800,700,0)界',
      );
      final line = doc.lines.single;
      expect(line.text, '世界');
      expect(line.words.map((w) => w.text), ['世', '界']);
      expect(line.words.map((w) => w.startMs), [1000, 1800]);
      expect(doc.quality, LyricsContentQuality.wordTimed);
    });

    test('QRC XML 包装剥壳 + 词标记在文字后', () {
      final doc = parseLyricsDocument(
        '<Lyric_1 LyricType="1" LyricContent="[1000,1000]你(1000,500)好(1500,500)"/>',
      );
      final line = doc.lines.single;
      expect(line.text, '你好');
      expect(line.words.map((w) => w.startMs), [1000, 1500]);
      expect(line.endMs, 2000);
    });

    test('KRC 相对行首偏移', () {
      final doc = parseLyricsDocument('[0,1000]<0,500,0>Hel<500,500,0>lo');
      final line = doc.lines.single;
      expect(line.text, 'Hello');
      expect(line.words.map((w) => w.startMs), [0, 500]);
      expect(line.words.every((w) => w.endMs > w.startMs), isTrue);
    });

    test('零时长词保留文本（不吞字）', () {
      // KRC/YRC 的零时长标记词（间隙占位等）必须保留，时长钳到 1ms。
      final doc = parseLyricsDocument(
        '[0,2000]<0,500,0>你<500,0,0>们<600,800,0>好',
      );
      final line = doc.lines.single;
      expect(line.text, '你们好');
      expect(line.words.map((w) => w.text), ['你', '们', '好']);
      expect(line.words.map((w) => w.startMs), [0, 500, 600]);
    });

    test('行级歌词的普通括号内容保留', () {
      final doc = parseLyricsDocument('[00:01.00]世(よ)に虚（むな）しさ Live (2024)');
      expect(doc.lines.single.text, '世に虚しさ Live (2024)');
    });

    test('侧轨按最近行起始对齐', () {
      final doc = parseLyricsDocument(
        '[00:01.00]Hello\n[00:03.00]World',
        translation: '[00:01.20]你好\n[00:03.10]世界',
      );
      final rendered = renderDocumentToLrcText(doc);
      expect(rendered, contains('[00:01.000]Hello\n[00:01.000]你好'));
      expect(rendered, contains('[00:03.000]World\n[00:03.000]世界'));
    });

    test('逐词行渲染为交错逐字 LRC + 行尾结束时间戳', () {
      final doc = parseLyricsDocument('[1000,1000]你(1000,500)好(1500,500)');
      final text = renderDocumentToLrcText(doc);
      expect(text, '[00:01.000]你[00:01.500]好[00:02.000]\n');
    });
  });

  group('crypto_codec', () {
    test('KRC 加解密往返', () {
      const plain = '[0,1000]<0,500,0>Hel<500,500,0>lo\n测试歌词';
      final compressed = Uint8List.fromList(
        ZLibEncoder().convert(utf8.encode(plain)),
      );
      final key = const <int>[0x40, 0x47, 0x61, 0x77, 0x5e, 0x32, 0x74, 0x47,
        0x51, 0x36, 0x31, 0x2d, 0xce, 0xd2, 0x6e, 0x69];
      final encrypted = Uint8List(compressed.length);
      for (var i = 0; i < compressed.length; i++) {
        encrypted[i] = compressed[i] ^ key[i % key.length];
      }
      final payload = base64Encode(
        [...utf8.encode('krc1'), ...encrypted],
      );
      expect(decryptKrc(payload), plain);
    });

    test('QRC：真实 GetPlayLyricInfo 载荷解密（LDDC 语义对照）', () {
      final fixture = File('test/fixtures_qrc_payload.txt');
      final hex = fixture.readAsStringSync().trim();
      final text = decodeQqNativeField(hex);
      expect(text, contains('<?xml'));
      expect(text, contains('QrcInfos'));
    });

    test('老接口 base64 字段与 HTML 实体', () {
      final b64 = base64Encode(utf8.encode('[00:01.00]A & B'));
      expect(decodeLyricField(b64), '[00:01.00]A & B');
      expect(decodeHtmlEntities('&amp;&#39;&#65;'), "&'A");
    });
  });

  group('LyricsCandidateScorer', () {
    final scorer = LyricsCandidateScorer();
    const request = OnlineLyricsRequest(
      title: '晴天',
      artists: ['周杰伦'],
      album: '叶惠美',
      durationMs: 269000,
    );

    OnlineLyricsCandidate candidate({
      required String id,
      String title = '晴天',
      List<String> artists = const ['周杰伦'],
      String? album = '叶惠美',
      int? durationMs = 269000,
      OnlineSourceId source = OnlineSourceId.netease,
    }) =>
        OnlineLyricsCandidate(
          source: source,
          remoteId: id,
          title: title,
          artists: artists,
          album: album,
          durationMs: durationMs,
        );

    test('完全匹配得满分', () {
      final scored = scorer.score(request, [candidate(id: '1')]);
      expect(scored, hasLength(1));
      expect(scored.single.score, greaterThanOrEqualTo(99));
    });

    test('时长差超 5 秒直接拒绝', () {
      final scored = scorer.score(
        request,
        [candidate(id: '1', durationMs: 269000 + 6000)],
      );
      expect(scored, isEmpty);
    });

    test('Live/伴奏版本冲突一票否决', () {
      expect(
        scorer.score(request, [candidate(id: '1', title: '晴天 Live')]),
        isEmpty,
      );
      expect(
        scorer.score(request, [candidate(id: '1', title: '晴天 (伴奏)')]),
        isEmpty,
      );
    });

    test('多歌手名单以较短一方为分母（主唱一致即高分）', () {
      final scored = scorer.score(
        request,
        [
          candidate(
            id: '1',
            artists: ['周杰伦', '费玉清', '张三', '李四'],
          ),
        ],
      );
      expect(scored, hasLength(1));
      expect(scored.single.score, greaterThan(80));
    });

    test('歌手对不上时靠兜底闸门（标题一致 + 时长 ≤2s）放行', () {
      final scored = scorer.score(
        const OnlineLyricsRequest(
          title: '晴天',
          artists: ['群星'],
          durationMs: 269000,
        ),
        [candidate(id: '1', artists: ['某某合唱团'])],
      );
      expect(scored, hasLength(1));
    });

    test('多源共识加分且按分排序', () {
      final scored = scorer.score(request, [
        candidate(id: '1', source: OnlineSourceId.kugou),
        candidate(id: '2', source: OnlineSourceId.netease),
        candidate(id: '3', source: OnlineSourceId.qqMusic),
      ]);
      expect(scored, hasLength(3));
      // 三源命中同一录音：共识满分，排序后首选来自优先序最高的源。
      expect(scored.first.consensusCount, 3);
      expect(scored.first.score, 100.0);
      expect(scored.first.candidate.source, OnlineSourceId.netease);
    });
  });

  group('LyricsMatchCoordinator', () {
    test('快源命中直接返回，深挖轮不跑', () async {
      final fast = _FakeSource(OnlineSourceId.netease, hit: true);
      var deepRan = false;
      final deep = _FakeSource(OnlineSourceId.qqMusic, hit: true)
        ..onSearch = () => deepRan = true;
      final coordinator = LyricsMatchCoordinator(
        sources: [fast],
        deepSources: [deep],
      );
      final result = await coordinator.match(const OnlineLyricsRequest(
        title: '晴天',
        artists: ['周杰伦'],
      ));
      expect(result.found, isNotNull);
      expect(result.found!.source, OnlineSourceId.netease);
      expect(deepRan, isFalse);
    });

    test('快源全部未命中时进入深挖轮', () async {
      final fast = _FakeSource(OnlineSourceId.netease, hit: false);
      final deep = _FakeSource(OnlineSourceId.qqMusic, hit: true);
      final coordinator = LyricsMatchCoordinator(
        sources: [fast],
        deepSources: [deep],
      );
      final result = await coordinator.match(const OnlineLyricsRequest(
        title: '晴天',
        artists: ['周杰伦'],
      ));
      expect(result.found, isNotNull);
      expect(result.found!.source, OnlineSourceId.qqMusic);
    });

    test('快源全体网络失败时离线短路', () async {
      final fast = _FakeSource(OnlineSourceId.netease, hit: false)
        ..failure = LyricsTransportException('offline');
      var deepRan = false;
      final deep = _FakeSource(OnlineSourceId.qqMusic, hit: true)
        ..onSearch = () => deepRan = true;
      final coordinator = LyricsMatchCoordinator(
        sources: [fast],
        deepSources: [deep],
      );
      final result = await coordinator.match(const OnlineLyricsRequest(
        title: '晴天',
        artists: ['周杰伦'],
      ));
      expect(result.found, isNull);
      expect(result.failure, LyricsFailureKind.networkFailure);
      expect(deepRan, isFalse);
    });

    test('主关键词无合格候选时用纯标题重试', () async {
      final keywords = <String>[];
      final source = _FakeSource(
        OnlineSourceId.kugou,
        hit: true,
        candidateArtists: const ['完全不同的歌手'],
      )..searchKeywordRecorder = keywords.add;
      final coordinator = LyricsMatchCoordinator(sources: [source]);
      await coordinator.match(const OnlineLyricsRequest(
        title: '晴天',
        artists: ['Wrong Artist'],
      ));
      expect(keywords, contains('晴天'));
    });
  });
}

class _FakeSource extends OnlineLyricsSource {
  _FakeSource(
    this.sourceId, {
    required this.hit,
    this.candidateArtists,
  });

  final OnlineSourceId sourceId;
  final bool hit;

  /// 候选固定歌手；为空时镜像请求歌手（保证候选可通过评分闸门）。
  final List<String>? candidateArtists;
  LyricsTransportException? failure;
  void Function()? onSearch;
  void Function(String)? searchKeywordRecorder;

  @override
  OnlineSourceId get id => sourceId;

  @override
  Future<List<OnlineLyricsCandidate>> search(LyricsSearchQuery query) async {
    searchKeywordRecorder?.call(query.keyword);
    onSearch?.call();
    final failure = this.failure;
    if (failure != null) throw failure;
    if (!hit) return const [];
    return [
      OnlineLyricsCandidate(
        source: id,
        remoteId: 'remote-1',
        title: query.request.title,
        artists: candidateArtists ?? query.request.artists,
        durationMs: query.request.durationMs,
      ),
    ];
  }

  @override
  Future<OnlineLyricsDocument> fetch(OnlineLyricsCandidate candidate) async {
    return parseLyricsDocument('[00:01.00]line1\n[00:02.00]line2');
  }
}
