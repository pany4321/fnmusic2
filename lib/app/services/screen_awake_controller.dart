/// 屏幕常亮控制器抽象 + wakelock_plus 默认实现。
library;

import 'package:wakelock_plus/wakelock_plus.dart';

abstract class ScreenAwakeController {
  Future<void> enable();
  Future<void> disable();
}

class WakelockScreenAwakeController implements ScreenAwakeController {
  @override
  Future<void> enable() => WakelockPlus.enable();

  @override
  Future<void> disable() => WakelockPlus.disable();
}
