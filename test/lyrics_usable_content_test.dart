// 歌词可用性判定回归测试：决定「要不要联网补歌词」的判定口径。
//
// 背景：NAS 曲库常常完全没有歌词，歌词全靠联网补。旧判定用
// `trim().isNotEmpty`，会把「非空但不可用」的文本（纯 BOM、只有 [ti:] 头、
// 只有空行）当成有歌词，从而永远不触发联网搜索、播放页一直空白。
import 'package:flutter_test/flutter_test.dart';

import 'package:feiniu_music/app/services/lyrics/lyrics_parser.dart';

void main() {
  group('LyricsParser.hasUsableContent', () {
    test('null / 空串 / 纯空白 → 不可用', () {
      expect(LyricsParser.hasUsableContent(null), isFalse);
      expect(LyricsParser.hasUsableContent(''), isFalse);
      expect(LyricsParser.hasUsableContent('   \n\n\t  '), isFalse);
    });

    test('纯 BOM → 不可用（旧逻辑会误判为有歌词）', () {
      expect(LyricsParser.hasUsableContent('\uFEFF'), isFalse);
      expect(LyricsParser.hasUsableContent('\uFEFF\uFEFF\n'), isFalse);
    });

    test('只有 LRC 元数据头 → 不可用', () {
      expect(
        LyricsParser.hasUsableContent(
          '[ti:某歌]\n[ar:某歌手]\n[al:某专辑]\n[by:xx]\n[offset:0]',
        ),
        isFalse,
      );
    });

    test('只有时间戳没有文本 → 不可用', () {
      expect(
        LyricsParser.hasUsableContent('[00:01.00]\n[00:02.00]\n[00:03.00]'),
        isFalse,
      );
    });

    test('带时间戳的正常歌词 → 可用', () {
      expect(
        LyricsParser.hasUsableContent('[ti:x]\n[00:01.00]你好\n[00:02.00]世界'),
        isTrue,
      );
    });

    test('无时间戳的纯文本歌词 → 可用（应用会按顺序生成时间轴）', () {
      expect(LyricsParser.hasUsableContent('第一行\n第二行'), isTrue);
    });

    test('BOM 开头但后面有歌词 → 可用', () {
      expect(
        LyricsParser.hasUsableContent('\uFEFF[00:01.00]你好'),
        isTrue,
      );
    });
  });
}
