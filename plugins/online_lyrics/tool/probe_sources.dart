// ignore_for_file: avoid_print
// 在线探针：对四个真实源做搜索 + 取词，验证移植后的接口路径与解密链路。
// 用法：dart run tool/probe_sources.dart
import 'package:online_lyrics/online_lyrics.dart';
import 'package:online_lyrics/src/http_client.dart';
import 'package:online_lyrics/src/match_policy.dart';
import 'package:online_lyrics/src/sources.dart';

const probes = [
  (title: '晴天', artists: ['周杰伦'], album: '叶惠美', durationMs: 269000),
  (title: '泡沫', artists: ['邓紫棋'], album: 'Xposed', durationMs: 244000),
];

Future<void> probeSource(
  String name,
  OnlineLyricsSource source,
  Map<int, List<OnlineLyricsCandidate>> found, {
  int index = 0,
}) async {
  final probe = probes[index];
  final request = OnlineLyricsRequest(
    title: probe.title,
    artists: probe.artists,
    album: probe.album,
    durationMs: probe.durationMs,
  );
  final stopwatch = Stopwatch()..start();
  try {
    final candidates = await source
        .search(LyricsSearchQuery('${probe.artists.first} - ${probe.title}',
            request))
        .timeout(const Duration(seconds: 10));
    final ms = stopwatch.elapsedMilliseconds;
    final scored = LyricsCandidateScorer().score(request, candidates);
    final top = scored.take(3).toList();
    print('[$name] search ${candidates.length} 条 ($ms ms)，'
        '过闸门 ${scored.length} 条');
    if (top.isEmpty) return;
    final match = await source.fetch(top.first.candidate);
    print('[$name] fetch OK：${match.lines.length} 行，'
        '质量 ${match.quality.name}，逐词覆盖 '
        '${(match.wordTimedCoverage * 100).toStringAsFixed(0)}%，'
        '翻译行 ${match.translatedLineCount}');
    print('[$name] 首行预览: ${match.lines.first.text}');
    found[index] = scored.map((s) => s.candidate).toList();
  } catch (e) {
    print('[$name] 失败: $e');
  }
}

Future<void> main() async {
  final http = LyricsHttpClient();
  final found = <int, List<OnlineLyricsCandidate>>{};

  print('=== 逐源探针（晴天 - 周杰伦） ===');
  await probeSource('网易云', NeteaseLyricsSource(http), found);
  await probeSource('QQ桌面', QqMusicLyricsSource(http), found);
  await probeSource('酷狗', KugouLyricsSource(http), found);
  await probeSource('LRCLIB', LrclibLyricsSource(http), found);
  await probeSource('QQ深挖', QqMusicLyricsSource(http, deepSearch: true), found);

  print('\n=== 端到端编排（fetchBestLyrics） ===');
  for (var i = 0; i < probes.length; i++) {
    final probe = probes[i];
    final stopwatch = Stopwatch()..start();
    final match = await OnlineLyricsClient.instance.fetchBestLyrics(
      title: probe.title,
      artists: probe.artists,
      album: probe.album,
      durationMs: probe.durationMs,
      onFailure: (failure) => print('  失败类别: $failure'),
    );
    final ms = stopwatch.elapsedMilliseconds;
    if (match == null) {
      print('「${probe.title}」未命中 ($ms ms)');
      continue;
    }
    final rendered = OnlineLyricsClient.instance.renderToLrcText(match);
    final lines = rendered.split('\n').where((l) => l.isNotEmpty).toList();
    print('「${probe.title}」命中：${match.source.name}，'
        'score ${match.score.toStringAsFixed(1)}，'
        '质量 ${match.document.quality.name}，'
        '渲染 ${lines.length} 行 ($ms ms)');
    print('  前 3 行: ${lines.take(3).join(' | ')}');
  }
}
