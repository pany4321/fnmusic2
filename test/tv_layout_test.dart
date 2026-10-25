import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:feiniu_music/app/state/settings_layout_state.dart';
import 'package:feiniu_music/app/tv/tv_layout.dart';
import 'package:feiniu_music/app/theme/app_visual_theme.dart';

/// TV 布局辅助与模式模型的单元测试。
///
/// 验证：
/// - TV 模式永不显示底部导航栏（effectiveTabletMode 生效）；
/// - TV 网格列数按宽度分级；
/// - TV 主题 focusColor 仅在 TV 模式生效（手机端主题逐字节不变）。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppLayoutSettings.resetForTest();
  });

  tearDown(() {
    AppLayoutSettings.resetForTest();
  });

  group('AppLayoutSettings.effectiveTabletMode', () {
    test('手机默认：tabletMode=false, tvMode=false → effective=false', () {
      expect(AppLayoutSettings.effectiveTabletMode, isFalse);
    });

    test('用户平板模式开启 → effective=true', () {
      AppLayoutSettings.tabletMode.value = true;
      expect(AppLayoutSettings.effectiveTabletMode, isTrue);
    });

    test('TV 模式开启 → effective=true，即使 tabletMode=false', () {
      AppLayoutSettings.tvMode.value = true;
      expect(AppLayoutSettings.effectiveTabletMode, isTrue);
    });

    test('effectiveTabletModeNotifier 随任一来源变化', () {
      bool? notified;
      AppLayoutSettings.effectiveTabletModeNotifier.addListener(() {
        notified = AppLayoutSettings.effectiveTabletModeNotifier.value;
      });
      AppLayoutSettings.tvMode.value = true;
      expect(notified, isTrue);
      AppLayoutSettings.tvMode.value = false;
      expect(notified, isFalse);
    });

    test('resetForTest 复位所有模式', () {
      AppLayoutSettings.tabletMode.value = true;
      AppLayoutSettings.tvMode.value = true;
      AppLayoutSettings.resetForTest();
      expect(AppLayoutSettings.effectiveTabletMode, isFalse);
    });
  });

  group('AppLayoutSettings.syncTvMode（手动强制开关）', () {
    test('自动检测关闭 + 手动强制开 → tvMode=true', () {
      TvDetectionAutoValue.value = false;
      AppLayoutSettings.syncTvMode();
      expect(AppLayoutSettings.tvMode.value, isFalse);

      AppLayoutSettings.forceTvMode.value = true;
      AppLayoutSettings.syncTvMode();
      expect(AppLayoutSettings.tvMode.value, isTrue);
    });

    test('自动检测开 + 手动强制关 → tvMode=true（或关系）', () {
      TvDetectionAutoValue.value = true;
      AppLayoutSettings.syncTvMode();
      expect(AppLayoutSettings.tvMode.value, isTrue);
    });

    test('手动强制关 + 自动检测关 → tvMode=false', () {
      TvDetectionAutoValue.value = false;
      AppLayoutSettings.forceTvMode.value = false;
      AppLayoutSettings.syncTvMode();
      expect(AppLayoutSettings.tvMode.value, isFalse);
    });

    test('重启后持久化的强制 TV 开关恢复生效（load→sync 顺序与 main 一致）', () async {
      // 模拟上次启动时打开过「TV 模式」开关并已持久化。启动顺序必须与
      // main() 一致：先 ensureLoaded() 读回 forceTvMode，再 syncTvMode()。
      SharedPreferences.setMockInitialValues({'setting_force_tv_mode': true});
      AppLayoutSettings.resetForTest();
      await AppLayoutSettings.ensureLoaded();
      expect(AppLayoutSettings.forceTvMode.value, isTrue);
      expect(AppLayoutSettings.tvMode.value, isFalse); // load 不自动合并
      AppLayoutSettings.syncTvMode();
      expect(AppLayoutSettings.tvMode.value, isTrue);
    });
  });

  group('TvLayout.gridColumns', () {
    test('宽度分级：1080p 电视 6 列，中屏 5 列，小屏 4 列', () {
      expect(TvLayout.gridColumns(1920), 6);
      expect(TvLayout.gridColumns(1600), 6);
      expect(TvLayout.gridColumns(1366), 5);
      expect(TvLayout.gridColumns(1200), 5);
      expect(TvLayout.gridColumns(1024), 4);
      expect(TvLayout.gridColumns(800), 4);
    });

    test('cardAspectRatio 覆盖 4/5/6 列', () {
      expect(TvLayout.cardAspectRatio(4), 0.88);
      expect(TvLayout.cardAspectRatio(5), 0.86);
      expect(TvLayout.cardAspectRatio(6), 0.84);
    });
  });

  testWidgets('TV 界面尺寸随逻辑分辨率增长并有上限', (tester) async {
    Future<double> scaleAt(Size size) async {
      double? scale;
      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(size: size),
          child: Builder(
            builder: (context) {
              scale = TvLayout.uiScale(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      return scale!;
    }

    expect(await scaleAt(const Size(1280, 720)), 1);
    expect(await scaleAt(const Size(1600, 900)), 1.25);
    expect(await scaleAt(const Size(1920, 1080)), 1.3);
    expect(await scaleAt(const Size(3840, 2160)), 1.3);
  });

  testWidgets('车机缩放可手动覆盖推荐值、持久化并恢复自动档', (tester) async {
    double? scale;
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(size: Size(1920, 1080)),
        child: Builder(
          builder: (context) {
            scale = TvLayout.uiScale(context);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    expect(scale, 1.3);

    await AppLayoutSettings.setTvUiScaleOverride(2.0);
    await tester.pump();
    expect(TvLayout.uiScale(tester.element(find.byType(Builder))), 2.0);

    AppLayoutSettings.resetForTest();
    await AppLayoutSettings.ensureLoaded();
    expect(AppLayoutSettings.tvUiScaleOverride.value, 2.0);

    await AppLayoutSettings.setTvUiScaleOverride(null);
    expect(TvLayout.uiScale(tester.element(find.byType(Builder))), 1.3);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('setting_tv_ui_scale_override'), isFalse);
  });

  test('车机缩放超出范围时限制为 80% 到 200%', () async {
    await AppLayoutSettings.setTvUiScaleOverride(2.5);
    expect(AppLayoutSettings.tvUiScaleOverride.value, 2.0);
    await AppLayoutSettings.setTvUiScaleOverride(0.5);
    expect(AppLayoutSettings.tvUiScaleOverride.value, 0.8);
  });

  group('AppLayoutSettings.consumeTvEdgeHint（首次启动提示）', () {
    test('首次调用返回 true，之后返回 false（只提醒一次）', () async {
      // 空 prefs 加载 → _tvEdgeHintShown=false（未展示过）。
      SharedPreferences.setMockInitialValues({});
      AppLayoutSettings.resetForTest();
      await AppLayoutSettings.ensureLoaded();
      expect(await AppLayoutSettings.consumeTvEdgeHint(), isTrue);
      expect(await AppLayoutSettings.consumeTvEdgeHint(), isFalse);
    });

    test('已展示过（prefs 为 true）→ 不再提醒', () async {
      SharedPreferences.setMockInitialValues({
        'setting_tv_edge_hint_shown': true,
      });
      AppLayoutSettings.resetForTest();
      await AppLayoutSettings.ensureLoaded();
      expect(await AppLayoutSettings.consumeTvEdgeHint(), isFalse);
    });
  });

  group('TV 主题 focusColor', () {
    test('非 TV：focusColor 保持默认（手机端主题逐字节不变）', () {
      final base = ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
      );
      final theme = buildMiuixMaterialTheme(base, base.colorScheme);
      // copyWith(focusColor: null) 不会覆盖默认值，应等于 base 的计算结果。
      expect(theme.focusColor, base.focusColor);
      expect(theme.highlightColor, base.highlightColor);
    });

    test('TV：focusColor 为 primary 半透明色（区别于默认）', () {
      final base = ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
      );
      final scheme = base.colorScheme;
      final theme = buildMiuixMaterialTheme(base, scheme, isTv: true);
      // ThemeData.focusColor 非空：TV 分支覆盖为主题色半透明，与默认不同。
      expect(theme.focusColor, isNot(base.focusColor));
      expect(theme.focusColor.a, closeTo(0.34, 0.01));
    });
  });

  group('AppLayoutSettings.orientationsForDevice（屏幕方向策略）', () {
    test('TV：恒横屏（左右两方向）', () {
      final orientations = AppLayoutSettings.orientationsForDevice(
        isTv: true,
        shortestSide: 400,
      );
      expect(orientations, contains(DeviceOrientation.landscapeLeft));
      expect(orientations, contains(DeviceOrientation.landscapeRight));
      expect(orientations, isNot(contains(DeviceOrientation.portraitUp)));
      expect(orientations.length, 2);
    });

    test('平板（最短边≥600dp）：四方向自由旋转', () {
      final orientations = AppLayoutSettings.orientationsForDevice(
        isTv: false,
        shortestSide: 800,
      );
      expect(orientations, contains(DeviceOrientation.landscapeLeft));
      expect(orientations, contains(DeviceOrientation.portraitUp));
      expect(orientations.length, 4);
    });

    test('手机（最短边<600dp）：锁竖屏', () {
      final orientations = AppLayoutSettings.orientationsForDevice(
        isTv: false,
        shortestSide: 390,
      );
      expect(orientations, [DeviceOrientation.portraitUp]);
    });

    test('手机 + 手动平板模式：四方向自由旋转', () {
      final orientations = AppLayoutSettings.orientationsForDevice(
        isTv: false,
        shortestSide: 390,
        manualTabletMode: true,
      );
      expect(orientations, contains(DeviceOrientation.landscapeLeft));
      expect(orientations.length, 4);
    });

    test('手机播放页：临时开放四方向', () {
      final orientations = AppLayoutSettings.orientationsForPlayer(isTv: false);

      expect(orientations, contains(DeviceOrientation.portraitUp));
      expect(orientations, contains(DeviceOrientation.landscapeLeft));
      expect(orientations, contains(DeviceOrientation.landscapeRight));
      expect(orientations.length, 4);
    });

    test('TV 播放页：仍只允许左右横屏', () {
      final orientations = AppLayoutSettings.orientationsForPlayer(isTv: true);

      expect(orientations, contains(DeviceOrientation.landscapeLeft));
      expect(orientations, contains(DeviceOrientation.landscapeRight));
      expect(orientations, isNot(contains(DeviceOrientation.portraitUp)));
      expect(orientations.length, 2);
    });
  });
    group('disableTvAutoDetect（车机误判逃生开关）', () {
      test('自动检测开 + 关闭自动识别 → tvMode=false（手动强制仍可开启）', () {
        TvDetectionAutoValue.value = true;
        AppLayoutSettings.disableTvAutoDetect.value = true;
        AppLayoutSettings.forceTvMode.value = false;
        AppLayoutSettings.syncTvMode();
        expect(AppLayoutSettings.tvMode.value, isFalse);

        // 手动强制优先级最高：自动识别关闭也挡不住强制开。
        AppLayoutSettings.forceTvMode.value = true;
        AppLayoutSettings.syncTvMode();
        expect(AppLayoutSettings.tvMode.value, isTrue);
      });

      test('自动识别关闭的偏好随 ensureLoaded 恢复', () async {
        SharedPreferences.setMockInitialValues({
          'setting_disable_tv_auto_detect': true,
        });
        AppLayoutSettings.resetForTest();
        await AppLayoutSettings.ensureLoaded();
        expect(AppLayoutSettings.disableTvAutoDetect.value, isTrue);
      });
    });

}
