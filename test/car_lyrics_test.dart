import 'package:flutter_test/flutter_test.dart';
import 'package:feiniu_music/app/services/media_notification_car_lyrics.dart';

void main() {
  group('carLyricsTitleOverride', () {
    test('开关关闭时返回 null（车机显示真实歌名）', () {
      expect(
        carLyricsTitleOverride(
          carLyricsEnabled: false,
          isCurrentSong: true,
          isPlaying: true,
          currentCarLyricLine: '我们不一样',
        ),
        isNull,
      );
    });

    test('非当前歌曲时返回 null（队列其他曲目保持真实歌名）', () {
      expect(
        carLyricsTitleOverride(
          carLyricsEnabled: true,
          isCurrentSong: false,
          isPlaying: true,
          currentCarLyricLine: '我们不一样',
        ),
        isNull,
      );
    });

    test('暂停时返回 null（暂停态回退真实歌名，配合真实 queueIndex 通过 AVRCP 同步检查）', () {
      expect(
        carLyricsTitleOverride(
          carLyricsEnabled: true,
          isCurrentSong: true,
          isPlaying: false,
          currentCarLyricLine: '我们不一样',
        ),
        isNull,
      );
    });

    test('歌词行为 null / 空 / 纯空白时返回 null', () {
      for (final line in [null, '', '   ', '\t\n']) {
        expect(
          carLyricsTitleOverride(
            carLyricsEnabled: true,
            isCurrentSong: true,
            isPlaying: true,
            currentCarLyricLine: line,
          ),
          isNull,
          reason: 'line=$line',
        );
      }
    });

    test('开启、当前歌曲且播放中返回 trim 后的歌词行', () {
      expect(
        carLyricsTitleOverride(
          carLyricsEnabled: true,
          isCurrentSong: true,
          isPlaying: true,
          currentCarLyricLine: '  我们不一样  ',
        ),
        '我们不一样',
      );
    });

    test('覆盖决策不依赖 showLyrics（开关独立）', () {
      // 该纯函数没有 showLyrics 入参，只受 carLyricsEnabled + isCurrentSong
      // + isPlaying + 歌词行驱动——锁定车载开关与「通知显示歌词」开关独立。
      final override = carLyricsTitleOverride(
        carLyricsEnabled: true,
        isCurrentSong: true,
        isPlaying: true,
        currentCarLyricLine: '人生短短几个秋',
      );
      expect(override, '人生短短几个秋');
    });
  });

  group('CarLyricsPublishGate', () {
    test('首次发布立即放行，间隔内拒绝并给出剩余等待', () {
      final gate = CarLyricsPublishGate(
        minInterval: const Duration(seconds: 1),
      );
      final t0 = DateTime(2026, 1, 1, 12, 0, 0);
      expect(gate.tryAcquire(t0), isTrue);
      final t500 = t0.add(const Duration(milliseconds: 500));
      expect(gate.tryAcquire(t500), isFalse);
      expect(
        gate.remainingAfter(t500),
        const Duration(milliseconds: 500),
      );
    });

    test('间隔期满后再次放行；markPublished 重置窗口', () {
      final gate = CarLyricsPublishGate(
        minInterval: const Duration(seconds: 1),
      );
      final t0 = DateTime(2026, 1, 1, 12, 0, 0);
      gate.tryAcquire(t0);
      final t999 = t0.add(const Duration(milliseconds: 999));
      expect(gate.tryAcquire(t999), isFalse);
      // 尾沿发布完成时刻
      gate.markPublished(t0.add(const Duration(milliseconds: 1000)));
      final t1500 = t0.add(const Duration(milliseconds: 1500));
      expect(gate.tryAcquire(t1500), isFalse); // 距尾沿仅 500ms
      expect(
        gate.remainingAfter(t1500),
        const Duration(milliseconds: 500),
      );
      final t2500 = t0.add(const Duration(milliseconds: 2500));
      expect(gate.tryAcquire(t2500), isTrue);
    });

    test('切歌/开关切换 reset 后首行立即发布', () {
      final gate = CarLyricsPublishGate(
        minInterval: const Duration(seconds: 1),
      );
      final t0 = DateTime(2026, 1, 1, 12, 0, 0);
      gate.tryAcquire(t0);
      gate.reset();
      final t100 = t0.add(const Duration(milliseconds: 100));
      expect(gate.tryAcquire(t100), isTrue);
      // 刚放行后，距下一次发布需再等满一个完整间隔。
      expect(
        gate.remainingAfter(t100),
        const Duration(seconds: 1),
      );
    });
  });
}
