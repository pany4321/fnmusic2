import 'package:flutter/widgets.dart';

import '../state/settings_layout_state.dart';
import 'tv_grid_delegate.dart';
import '../services/tv_detection.dart';

/// TV 端布局辅助（10-foot UI）。
///
/// TV 布局尺寸由调用方仅在 TV 模式下使用，手机端不使用这些值。
class TvLayout {
  TvLayout._();

  /// 高逻辑分辨率屏幕上的车机界面按屏幕短边适度放大。
  /// 以 720dp 为基准，限制上限避免 4K 屏幕上的控件过大。
  static double recommendedUiScale(BuildContext context) {
    final shortestSide =
        (TvUiScaleScope.maybeOf(context)?.unscaledSize ??
                MediaQuery.sizeOf(context))
            .shortestSide;
    // 车机观看距离（60–100cm）虽比 TV 近，但行驶颠簸 + 余光操作要求更大的
    // 默认控件；用户未手动设置缩放时车机下限提到 1.1。
    if (TvDetection.kind.value == TvDeviceKind.car) {
      return (shortestSide / 720).clamp(1.1, 1.4);
    }
    return (shortestSide / 720).clamp(1.0, 1.3);
  }

  static double configuredUiScale(BuildContext context) =>
      AppLayoutSettings.tvUiScaleOverride.value ?? recommendedUiScale(context);

  /// Existing component size multipliers are unnecessary inside the app scale.
  static double uiScale(BuildContext context) =>
      TvUiScaleScope.maybeOf(context) == null
      ? configuredUiScale(context)
      : 1.0;

  /// TV 网格列数：按逻辑宽度分级，1080p 盒子（约 1920 逻辑宽）取 5-6 列。
  static int gridColumns(double width) {
    if (width >= 1600) return 6;
    if (width >= 1200) return 5;
    return 4;
  }

  static SliverGridDelegate gridDelegate(
    BuildContext context, {
    required int columns,
    required double mainAxisSpacing,
    required double childAspectRatio,
  }) {
    if (AppLayoutSettings.tvMode.value) {
      return TvGridDelegate(
        crossAxisCount: columns,
        minimumCardWidth:
            140 *
            (MediaQuery.textScalerOf(context).scale(15) / 15).clamp(1.0, 2.0),
        crossAxisSpacing: 14,
        mainAxisSpacing: mainAxisSpacing,
        childAspectRatio: childAspectRatio,
      );
    }
    return SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: columns,
      crossAxisSpacing: 14,
      mainAxisSpacing: mainAxisSpacing,
      childAspectRatio: childAspectRatio,
    );
  }

  /// TV 卡片宽高比（宽/高）。
  ///
  /// 网格卡是「正方形封面 + 标题」结构：卡片高度 ≈ 封面(W) + 标题区(~40px)。
  /// 若比例太小（如 0.5 = 高是宽的 2 倍），正方形封面下方会空出一大段
  /// 空白。TV 用 0.84~0.88 让卡片高度恰好容纳正方形封面 + 标题，无空隙。
  static double cardAspectRatio(int columns) {
    return switch (columns) {
      4 => 0.88,
      5 => 0.86,
      _ => 0.84,
    };
  }

  /// 页面水平/垂直留白：TV 从 3 米外观看，间距比手机大，底部无需
  /// 160px 手势条留白（TV 没有全面屏手势条）。
  static EdgeInsets pagePadding() => const EdgeInsets.fromLTRB(32, 12, 32, 32);

  /// 列表行封面/缩略图尺寸。
  static double artworkSize() => 56;

  /// 列表行最小高度（加大命中区域，方便遥控器聚焦）。
  static double tileMinHeight() => 72;

  /// 侧栏宽度（TabletLayoutHost 使用），比手机端抽屉更宽。
  static const double railWidthMin = 320;
  static const double railWidthMax = 360;
}

class TvUiScaleScope extends InheritedWidget {
  final Size unscaledSize;
  final double scale;

  const TvUiScaleScope({
    super.key,
    required this.unscaledSize,
    required this.scale,
    required super.child,
  });

  static TvUiScaleScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<TvUiScaleScope>();

  @override
  bool updateShouldNotify(TvUiScaleScope oldWidget) =>
      unscaledSize != oldWidget.unscaledSize || scale != oldWidget.scale;
}
