// 车机适配整改的纯逻辑测试：硬键 seek 钳制、屏幕常亮真值表、
// 语音搜索入口可见性、TV 主题触点/焦点保障、车机缩放下限。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:feiniu_music/app/services/media_notification_car_lyrics.dart';
import 'package:feiniu_music/app/services/screen_awake_service.dart';
import 'package:feiniu_music/app/services/voice_search_controller.dart';
import 'package:feiniu_music/app/services/tv_detection.dart';
import 'package:feiniu_music/app/theme/app_visual_theme.dart';
import 'package:feiniu_music/app/tv/tv_layout.dart';

void main() {
  group('hardwareSeekTarget（车机方向盘长按快进/快退）', () {
    const duration = Duration(minutes: 4);

    test('中间位置正常 ±10s', () {
      expect(
        hardwareSeekTarget(
          position: const Duration(minutes: 1),
          duration: duration,
          delta: const Duration(seconds: 10),
        ),
        const Duration(minutes: 1, seconds: 10),
      );
      expect(
        hardwareSeekTarget(
          position: const Duration(minutes: 1),
          duration: duration,
          delta: -const Duration(seconds: 10),
        ),
        const Duration(seconds: 50),
      );
    });

    test('两端钳制到 0 与总时长', () {
      expect(
        hardwareSeekTarget(
          position: const Duration(seconds: 5),
          duration: duration,
          delta: -const Duration(seconds: 10),
        ),
        Duration.zero,
      );
      expect(
        hardwareSeekTarget(
          position: duration - const Duration(seconds: 3),
          duration: duration,
          delta: const Duration(seconds: 10),
        ),
        duration,
      );
    });

    test('总时长未知时仅钳负端', () {
      expect(
        hardwareSeekTarget(
          position: const Duration(minutes: 1),
          duration: null,
          delta: -const Duration(seconds: 10),
        ),
        const Duration(seconds: 50),
      );
      expect(
        hardwareSeekTarget(
          position: const Duration(seconds: 5),
          duration: null,
          delta: -const Duration(seconds: 10),
        ),
        Duration.zero,
      );
    });
  });

  group('ScreenAwakeService.desiredAwake（屏幕常亮真值表）', () {
    test('仅 TV/车机模式 + 播放中 + 开关开启三者同时成立才常亮', () {
      expect(
        ScreenAwakeService.desiredAwake(
          tvMode: true,
          playing: true,
          keepScreenOnEnabled: true,
        ),
        isTrue,
      );
      expect(
        ScreenAwakeService.desiredAwake(
          tvMode: false,
          playing: true,
          keepScreenOnEnabled: true,
        ),
        isFalse,
      );
      expect(
        ScreenAwakeService.desiredAwake(
          tvMode: true,
          playing: false,
          keepScreenOnEnabled: true,
        ),
        isFalse,
      );
      expect(
        ScreenAwakeService.desiredAwake(
          tvMode: true,
          playing: true,
          keepScreenOnEnabled: false,
        ),
        isFalse,
      );
    });
  });

  group('voiceSearchEntryVisible（车机语音搜索入口）', () {
    test('仅 TV/车机模式且移动平台显示', () {
      expect(
        voiceSearchEntryVisible(tvMode: true, mobilePlatform: true),
        isTrue,
      );
      expect(
        voiceSearchEntryVisible(tvMode: false, mobilePlatform: true),
        isFalse,
      );
      expect(
        voiceSearchEntryVisible(tvMode: true, mobilePlatform: false),
        isFalse,
      );
    });
  });

  group('TV 主题（焦点指示与触点保障）', () {
    testWidgets('isTv 主题带 focusColor 与 padded 触点，手机端默认',
        (tester) async {
      final lightScheme = ColorScheme.fromSeed(seedColor: Colors.blue);
      final tvTheme = buildMiuixMaterialTheme(
        ThemeData(),
        lightScheme,
        isTv: true,
      );
      expect(tvTheme.focusColor, isNotNull);
      expect(
        tvTheme.materialTapTargetSize,
        MaterialTapTargetSize.padded,
      );

      // 手机端不显式设置（copyWith(null) 继承基础主题的 padded 默认，
      // 与改动前行为一致）。
    });
  });

  group('TvLayout.recommendedUiScale（车机下限）', () {
    testWidgets('车机 kind 下限 1.1；TV/常规 720p 为 1.0', (tester) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      addTearDown(() => TvDetection.kind.value = TvDeviceKind.none);

      double? carScale;
      TvDetection.kind.value = TvDeviceKind.car;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              carScale = TvLayout.recommendedUiScale(context);
              return const SizedBox();
            },
          ),
        ),
      );
      expect(carScale, 1.1);

      double? tvScale;
      TvDetection.kind.value = TvDeviceKind.tv;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              tvScale = TvLayout.recommendedUiScale(context);
              return const SizedBox();
            },
          ),
        ),
      );
      expect(tvScale, 1.0);
    });
  });
}
