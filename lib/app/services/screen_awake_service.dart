/// 播放中屏幕常亮服务（车机/TV 模式）。
///
/// 部分车机有「无交互超时息屏」策略：音乐继续播但屏幕黑掉，想切歌必须
/// 先唤醒屏幕，驾驶中不可操作。本服务在「TV/车机模式 + 正在播放 + 用户
/// 未关闭开关」时持有 wakelock，暂停/停止即释放。
///
/// 控制器抽象成接口（[ScreenAwakeController]）便于单测注入假实现；
/// 默认实现走 wakelock_plus。手机（非 TV 模式）永远不持有，行为不变。
library;

import 'package:flutter/foundation.dart';

import '../state/settings_layout_state.dart';
import 'player_service.dart';
import 'screen_awake_controller.dart';

class ScreenAwakeService {
  ScreenAwakeService._({ScreenAwakeController? controller})
      : _controller = controller ?? WakelockScreenAwakeController();

  static final ScreenAwakeService instance = ScreenAwakeService._();

  final ScreenAwakeController _controller;
  bool _initialized = false;
  bool _lastApplied = false;

  /// 当前是否应当保持屏幕常亮（纯函数，供测试断言）。
  ///
  /// 条件：TV/车机模式 && 正在播放 && 开关未关闭。
  static bool desiredAwake({
    required bool tvMode,
    required bool playing,
    required bool keepScreenOnEnabled,
  }) {
    return tvMode && playing && keepScreenOnEnabled;
  }

  void init() {
    if (_initialized) return;
    _initialized = true;
    PlayerService.instance.isPlaying.addListener(_apply);
    AppLayoutSettings.tvMode.addListener(_apply);
    AppLayoutSettings.keepScreenOnWhilePlaying.addListener(_apply);
    _apply();
  }

  void _apply() {
    final awake = desiredAwake(
      tvMode: AppLayoutSettings.tvMode.value,
      playing: PlayerService.instance.isPlaying.value,
      keepScreenOnEnabled: AppLayoutSettings.keepScreenOnWhilePlaying.value,
    );
    if (awake == _lastApplied) return;
    _lastApplied = awake;
    if (awake) {
      _controller.enable();
    } else {
      _controller.disable();
    }
  }

  /// 测试用：重置初始化状态。
  @visibleForTesting
  static ScreenAwakeService createForTest(ScreenAwakeController controller) {
    return ScreenAwakeService._(controller: controller);
  }
}
