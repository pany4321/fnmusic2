/// speech_to_text 平台引擎适配器（Android/iOS）。
library;

import 'package:speech_to_text/speech_to_text.dart';

import 'voice_search_controller.dart';

class SpeechToTextEngine implements SpeechToTextLike {
  final SpeechToText _stt = SpeechToText();

  @override
  Future<bool> initialize() => _stt.initialize();

  @override
  Future<bool> listen({
    required String localeId,
    required void Function(String text) onResult,
    required void Function() onFinal,
  }) async {
    // 插件的 listen 返回 Future<dynamic>（内部实际完成 bool）。
    final started = await _stt.listen(
      onResult: (result) {
        final text = result.recognizedWords;
        if (text.isNotEmpty) onResult(text);
        if (result.finalResult) onFinal();
      },
      listenOptions: SpeechListenOptions(
        localeId: localeId,
        partialResults: true,
        // 静默 1.5s 视为说完：插件停止听写并产出最终结果
        // （Android 系统另有 1–3s 强制暂停，实际会更早结束）。
        pauseFor: const Duration(milliseconds: 1500),
        cancelOnError: true,
      ),
    );
    return started == true;
  }

  @override
  Future<void> stop() => _stt.stop();
}
