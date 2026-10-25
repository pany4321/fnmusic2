import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// TV / 车机环境检测。
///
/// 目标：同一个 APK 同时运行在手机/平板、Android TV 与车机上。TV/车机端
/// 检测到后自动切换 TV 布局（大字大按钮）+ 旋钮/遥控器/方向盘方向键导航，
/// 手机端行为完全不受影响。
///
/// 检测策略（hybrid）：
/// 1. [setOverride] 测试/开发覆盖 —— 非 null 时直接短路；
/// 2. 原生 MethodChannel 查询 —— `uiMode == TELEVISION/CAR`、LEANBACK 或
///    automotive 特性（原生 `MainActivity.isTvDevice` 实现）。车机与 TV 共用
///    同一套焦点导航与大屏布局；
/// 3. 纯 Dart 启发式回退 —— 通道失败/非 Android 时用「横屏 + 大屏」近似，
///    仅用于开发机验证，不参与真机判断。
///
/// 手机被驾驶类 App 置成 CAR uiMode 会误入 TV 布局：用户可在设置页关闭
/// 「自动识别 TV / 车机」（AppLayoutSettings.disableTvAutoDetect）。
class TvDetection {
  TvDetection._();

  /// 是否检测到 TV 环境。由 [ensureLoaded] 在 `runApp` 前填充。
  static final ValueNotifier<bool> result = ValueNotifier(false);

  /// 测试覆盖：非 null 时 [detect] 直接返回该值，跳过原生查询。
  static bool? _overrideForTest;

  static const MethodChannel _channel = MethodChannel('com.feiniu.music/tv');

  static const String _dartDefineKey = 'FEINIU_TV_MODE';

  static Future<void>? _loading;

  /// 供 main() 在 runApp 前调用：完成检测并写入 [result]。
  static Future<void> ensureLoaded() => _loading ??= _doLoad();

  static Future<void> _doLoad() async {
    result.value = await detect();
  }

  /// 测试/开发专用：强制指定检测结果。
  @visibleForTesting
  static void setOverride(bool? value) {
    _overrideForTest = value;
  }

  /// 执行 TV 检测。任何异常都不抛出，保证启动链稳定。
  /// 检测结果同时写入 [result]，供启动后各处 ValueListenableBuilder 订阅。
  static Future<bool> detect() async {
    final override = _overrideForTest;
    if (override != null) {
      result.value = override;
      return override;
    }

    // 编译期强制（--dart-define=FEINIU_TV_MODE=1），开发调试用。
    const dartDefine = String.fromEnvironment(_dartDefineKey);
    if (dartDefine == '1') {
      result.value = true;
      return true;
    }

    if (Platform.isAndroid) {
      try {
        final value = await _channel.invokeMethod<bool>('isTvDevice');
        if (value != null) {
          result.value = value;
          return value;
        }
      } catch (_) {
        // 通道不可用（例如嵌入式/测试环境），走回退。
      }
    }

    // 非 Android / 通道失败：不猜测。真机 TV 必走原生通道；
    // 开发机模拟请用 --dart-define=FEINIU_TV_MODE=1。
    result.value = false;
    return false;
  }
}
