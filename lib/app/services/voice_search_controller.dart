/// 车机/TV 模式下的语音搜索控制器（speech_to_text 封装）。
///
/// 车机输入法各异（部分无旋钮 IME），驾驶中键盘输入不可行 —— 语音是
/// 唯一安全的搜索入口。仅在 TV/车机模式 + 移动平台（Android/iOS）开放，
/// 手机端入口不展示（系统键盘可用，避免额外麦克风权限打扰）。
///
/// [SpeechToTextLike] 抽象出最小接口便于单测注入假实现。
library;

import 'package:flutter/foundation.dart';

/// 语音搜索入口的可见性判定（纯函数，供测试与 UI 共用）。
bool voiceSearchEntryVisible({
  required bool tvMode,
  required bool mobilePlatform,
}) {
  return tvMode && mobilePlatform;
}

/// 语音引擎的最小接口（平台实现见 voice_search_speech_engine.dart，
/// 测试注入假实现）。
abstract class SpeechToTextLike {
  Future<bool> initialize();

  /// 返回是否成功开始听写；[onFinal] 在识别结束（最终结果）时回调。
  Future<bool> listen({
    required String localeId,
    required void Function(String text) onResult,
    required void Function() onFinal,
  });

  Future<void> stop();
}

class VoiceSearchController {
  VoiceSearchController({required SpeechToTextLike engine})
      : _engine = engine;

  final SpeechToTextLike _engine;

  /// UI 观察：是否正在聆听。
  final ValueNotifier<bool> listening = ValueNotifier(false);

  bool _initialized = false;
  bool _initFailed = false;

  /// 开始/停止语音听写。识别文本通过 [onText] 流式回调（局部结果），
  /// 结束时回调 [onDone]。初始化失败静默返回 false（入口不弹错，
  /// 下次点击再试）。
  Future<bool> toggle({
    required void Function(String text) onText,
    required void Function() onDone,
  }) async {
    if (listening.value) {
      listening.value = false;
      await _engine.stop();
      onDone();
      return true;
    }
    if (_initFailed) return false;
    if (!_initialized) {
      _initialized = await _engine.initialize();
      if (!_initialized) {
        _initFailed = true;
        return false;
      }
    }
    listening.value = true;
    final ok = await _engine.listen(
      localeId: 'zh_CN',
      onResult: onText,
      onFinal: () {
        listening.value = false;
        onDone();
      },
    );
    if (!ok) listening.value = false;
    return ok;
  }

  @visibleForTesting
  void debugReset() {
    _initialized = false;
    _initFailed = false;
    listening.value = false;
  }
}
