// ignore_for_file: avoid_print
// NAS 曲库在线歌词命中率探针：登录飞牛音乐 → 取真实曲目 → 走内置在线源
// 匹配歌词，统计命中率。
//
// 凭据一律从环境变量读取（FN_BASE / FN_USER / FN_PASS），不落入代码仓库。
// 用法：
//   FN_BASE=... FN_USER=... FN_PASS=... dart run tool/nas_hit_rate_probe.dart [采样数]
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:online_lyrics/online_lyrics.dart';

Future<void> main(List<String> args) async {
  final base = Platform.environment['FN_BASE'];
  final user = Platform.environment['FN_USER'];
  final pass = Platform.environment['FN_PASS'];
  if (base == null || user == null || pass == null) {
    print('请设置 FN_BASE / FN_USER / FN_PASS 环境变量');
    exit(2);
  }
  final sampleSize = args.isNotEmpty ? int.tryParse(args.first) ?? 30 : 30;

  final dio = Dio(BaseOptions(
    baseUrl: base.replaceAll(RegExp(r'/+$'), ''),
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 20),
  ));

  // ① 登录（密码 sha256 hex，与客户端一致）
  final deviceId = List.generate(
    16,
    (_) => Random().nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  final login = await dio.post<Map<String, dynamic>>(
    '/music/api/v1/user/password-login',
    data: {
      'username': user,
      'password': sha256.convert(utf8.encode(pass)).toString(),
      'deviceId': deviceId,
    },
  );
  final loginBody = login.data!['data'] as Map<String, dynamic>;
  final token = loginBody['userToken'] as String;
  print('登录成功，token 已获取');

  // ② 取曲目列表
  final list = await dio.get<Map<String, dynamic>>(
    '/music/api/v1/track/list',
    queryParameters: {'page': 1, 'size': 200},
    options: Options(headers: {'Cookie': 'music-token=$token'}),
  );
  final items = ((list.data!['data'] as Map<String, dynamic>)['list'] as List)
      .cast<Map<String, dynamic>>();
  print('曲库返回 ${items.length} 首');

  // 优先无歌词曲目（这正是自动搜索的目标场景），不足则补普通曲目。
  String titleOf(Map<String, dynamic> t) => (t['title'] ?? '') as String;
  List<String> artistsOf(Map<String, dynamic> t) =>
      ((t['artists'] as List?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map((a) => (a['name'] ?? '') as String)
          .where((n) => n.isNotEmpty)
          .toList();
  int durationOf(Map<String, dynamic> t) {
    final d = t['duration'];
    return d is num ? d.round() : 0;
  }

  String albumOf(Map<String, dynamic> t) =>
      ((t['album'] as Map<String, dynamic>?)?['name'] ?? '') as String;

  final noLyric = items
      .where((t) => t['hasLyric'] == false && titleOf(t).isNotEmpty)
      .toList();
  final rest = items
      .where((t) => t['hasLyric'] != false && titleOf(t).isNotEmpty)
      .toList();
  final sample = [...noLyric.take(sampleSize)];
  if (sample.length < sampleSize) {
    sample.addAll(rest.take(sampleSize - sample.length));
  }
  print('采样 ${sample.length} 首（其中无歌词 ${noLyric.length} 首，'
      '采样命中无歌词 ${sample.where((t) => t['hasLyric'] == false).length} 首）\n');

  // ③ 逐首走内置在线源
  var hit = 0;
  var miss = 0;
  var wordTimed = 0;
  var translated = 0;
  final misses = <String>[];
  final stopwatch = Stopwatch();
  for (final t in sample) {
    final title = titleOf(t);
    final artists = artistsOf(t);
    stopwatch..reset()..start();
    OnlineLyricsMatch? match;
    try {
      match = await OnlineLyricsClient.instance.fetchBestLyrics(
        title: title,
        artists: artists,
        album: albumOf(t),
        durationMs: durationOf(t) > 0 ? durationOf(t) : null,
      );
    } catch (_) {}
    final ms = stopwatch.elapsedMilliseconds;
    if (match == null) {
      miss++;
      misses.add('$title - ${artists.join("/")}');
      print('✗ ${ms.toString().padLeft(5)}ms  $title - ${artists.join("/")}');
      continue;
    }
    hit++;
    if (match.document.quality == LyricsContentQuality.wordTimed) wordTimed++;
    if (match.document.translatedLineCount > 0) translated++;
    print('✓ ${ms.toString().padLeft(5)}ms  $title - ${artists.join("/")} '
        '← ${match.source.name} score=${match.score.toStringAsFixed(0)} '
        'quality=${match.document.quality.name}');
    // 控制请求节奏，避免对在线源过于密集。
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }

  print('\n=== 汇总 ===');
  print('命中 $hit / ${sample.length}（${(hit * 100 / sample.length).toStringAsFixed(1)}%），'
      '未命中 $miss');
  print('逐字歌词 $wordTimed 首，含翻译 $translated 首');
  if (misses.isNotEmpty) {
    print('未命中列表：');
    for (final m in misses.take(10)) {
      print('  - $m');
    }
  }
}
