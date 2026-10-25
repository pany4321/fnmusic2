/// 车载蓝牙歌词：开启、为当前歌曲且播放中时，返回要写入 `MediaItem.title` 的
/// 歌词行。返回 `null` 表示不覆盖（车机显示真实歌名）。
///
/// AVRCP 只把 TITLE / ARTIST / ALBUM / TRACK_NUMBER / NUM_TRACKS / GENRE /
/// DURATION 等标准属性发给车机，`METADATA_KEY_LYRICS` 不会到达车机（AOSP
/// `avrcp/helpers/Util.java` 的 `bundleToMetadata` 只读这 7 个 key）。因此用
/// `title` 携带当前歌词行，让车机在 TITLE 位置显示歌词。
///
/// 暂停时不覆盖：暂停态保留真实 queueIndex（见
/// `MediaNotificationService._stateFromSnap`），AOSP AVRCP 的
/// `isMetadataSynced()` 要求队列当前项 title 与会话 metadata title 一致才
/// 放行更新，歌词行必然不一致；暂停回退真实歌名即可让暂停态完全正常
/// （列表 + 高亮 + 歌名），播放中再由 queueIndex=null 绕过该检查。
String? carLyricsTitleOverride({
  required bool carLyricsEnabled,
  required bool isCurrentSong,
  required bool isPlaying,
  required String? currentCarLyricLine,
}) {
  if (!carLyricsEnabled || !isCurrentSong || !isPlaying) return null;
  final line = currentCarLyricLine?.trim() ?? '';
  return line.isEmpty ? null : line;
}

/// 车载歌词行的发布节流闸（前沿放行 + 尾沿合并）。
///
/// 每行歌词变化都会触发一次 MediaItem 发布，即一次 AVRCP
/// METADATA_CHANGED 推送；快歌/短行密集时对老车机是元数据风暴（每次重置
/// 跑马灯、部分车机整屏刷新）。闸门保证两次发布间隔不小于 [minInterval]：
/// 间隔内的新行合并为一次尾沿发布（总是发最新行）。
///
/// 纯逻辑类（时间由调用方注入），测试见 test/car_lyrics_publish_gate_test.dart。
class CarLyricsPublishGate {
  CarLyricsPublishGate({this.minInterval = const Duration(seconds: 1)});

  /// 两次发布的最小间隔。
  final Duration minInterval;

  DateTime? _lastPublishedAt;

  /// 立即发布是否放行（放行即记录发布时刻）。
  bool tryAcquire(DateTime now) {
    final last = _lastPublishedAt;
    if (last == null || now.difference(last) >= minInterval) {
      _lastPublishedAt = now;
      return true;
    }
    return false;
  }

  /// 距下一次可发布的剩余等待（调度尾沿发布用）。
  Duration remainingAfter(DateTime now) {
    final last = _lastPublishedAt;
    if (last == null) return Duration.zero;
    final elapsed = now.difference(last);
    if (elapsed >= minInterval) return Duration.zero;
    return minInterval - elapsed;
  }

  /// 记录一次发布（尾沿定时器触发时调用）。
  void markPublished(DateTime now) {
    _lastPublishedAt = now;
  }

  /// 逃逸通道：车载歌词关闭/暂停等场景直接发布时同步记录，
  /// 避免紧随其后的歌词行被误判为「间隔内」。
  void reset() {
    _lastPublishedAt = null;
  }
}
