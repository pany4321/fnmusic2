import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 播放无歌词音乐时自动搜索歌词设置。
///
/// 开启后，播放无歌词（NAS 歌词接口返回空/无有效歌词行）的音乐时自动
/// 搜索：优先走内置在线歌词源（[useBuiltinOnline]，应用内直连网易云/QQ/
/// 酷狗/LRCLIB，无需服务端增强），未命中且已配置服务端增强时再走数据源
/// 插件。命中后写入本地缓存；[writeBack] 开启且服务端增强可用时再写 NAS。
///
/// **默认开启**：服务端是否存歌词因库而异，很多 NAS 曲库完全没有歌词，
/// 此时内置源是唯一来源。默认关闭会让「有歌词」变成需要用户自己找开关
/// 才成立的隐式前提（实测踩坑）。服务端自带歌词时本地/服务端命中即返回，
/// 不会产生额外的在线请求。
class LyricAutoSearchSettings {
  static const String _prefsEnabled = 'lyric_auto_search_enabled';
  static const String _prefsWriteBack = 'lyric_auto_search_write_back';
  static const String _prefsUseBuiltinOnline =
      'lyric_auto_search_builtin_online';

  /// 自动搜索歌词开关（默认开启）。
  static final ValueNotifier<bool> enabled = ValueNotifier(true);

  /// 搜索到歌词后自动回写到 NAS（服务端增强）。默认关闭。
  static final ValueNotifier<bool> writeBack = ValueNotifier(false);

  /// 内置在线歌词源（应用内直连，无需服务端增强）。默认开启。
  static final ValueNotifier<bool> useBuiltinOnline = ValueNotifier(true);

  static bool _loaded = false;

  static bool get loaded => _loaded;

  static Future<void> ensureLoaded() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    enabled.value = prefs.getBool(_prefsEnabled) ?? true;
    writeBack.value = prefs.getBool(_prefsWriteBack) ?? false;
    useBuiltinOnline.value = prefs.getBool(_prefsUseBuiltinOnline) ?? true;
    _loaded = true;
  }

  static Future<void> setEnabled(bool value) async {
    enabled.value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsEnabled, value);
  }

  static Future<void> setWriteBack(bool value) async {
    writeBack.value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsWriteBack, value);
  }

  static Future<void> setUseBuiltinOnline(bool value) async {
    useBuiltinOnline.value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsUseBuiltinOnline, value);
  }
}
