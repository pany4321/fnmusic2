/// 内置多源在线歌词获取：网易云 / QQ 音乐 / 酷狗 / LRCLIB。
///
/// 移植自 fn-music（GPL-3.0-only）core/lyrics 模块，接口行为保持一致：
/// 两轮编排（快源 → QQ 深挖）、候选评分闸门、QRC/KRC 解密、LRCLIB 限流。
library;

export 'src/coordinator.dart';
export 'src/models.dart';
export 'src/online_lyrics_client.dart';
