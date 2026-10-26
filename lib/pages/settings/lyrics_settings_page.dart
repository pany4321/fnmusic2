import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:signals_flutter/signals_flutter.dart' hide computed;

import '../../app/services/island_lyric_service.dart';
import '../../app/services/lyrics/lyrics_service.dart';
import '../../app/state/settings_island_lyric.dart';
import '../../app/state/settings_lyric_auto_search.dart';
import '../../app/state/settings_state.dart';
import '../../components/index.dart';

class LyricsSettingsPage extends StatefulWidget {
  const LyricsSettingsPage({super.key});

  @override
  State<LyricsSettingsPage> createState() => _LyricsSettingsPageState();
}

class _LyricsSettingsPageState extends State<LyricsSettingsPage>
    with SignalsMixin {
  static const String _prefsMeizuLyrics = 'lyrics_meizu_enabled';
  static const String _prefsLyriconEnabled = 'lyrics_lyricon_enabled';
  static const String _prefsLyriconForceKaraoke = 'lyrics_lyricon_force_karaoke';
  static const String _prefsLyriconHideTranslation =
      'lyrics_lyricon_hide_translation';

  late final _meizuLyrics = createSignal(false);
  late final _lyriconEnabled = createSignal(false);
  late final _lyriconForceKaraoke = createSignal(false);
  late final _lyriconHideTranslation = createSignal(false);
  late final _carBluetoothLyrics = createSignal(false);
  late final _loading = createSignal(true);

  /// 是否 HyperOS/MIUI 设备（「息屏通知设置」跳转行仅在其上显示）。
  late final _isHyperOs = createSignal(false);

  /// 灵动岛 / 焦点通知能力（探测结果决定显示哪些通知类型开关）。
  late final _capabilities =
      createSignal<IslandCapabilities>(IslandCapabilities.none);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    await MediaNotificationSettings.ensureLoaded();
    await IslandLyricSettings.ensureLoaded();
    if (!mounted) return;
    _meizuLyrics.value = prefs.getBool(_prefsMeizuLyrics) ?? false;
    _lyriconEnabled.value = prefs.getBool(_prefsLyriconEnabled) ?? false;
    _lyriconForceKaraoke.value =
        prefs.getBool(_prefsLyriconForceKaraoke) ?? false;
    _lyriconHideTranslation.value =
        prefs.getBool(_prefsLyriconHideTranslation) ?? false;
    _carBluetoothLyrics.value =
        MediaNotificationSettings.carBluetoothLyrics.value;
    await LyricsService.instance.refreshSettings();
    // 探测当前设备是否 HyperOS（决定是否显示「息屏通知设置」跳转行）。
    _isHyperOs.value = await IslandLyricService.isHyperOs();
    // 探测灵动岛 / 焦点通知能力（决定显示哪些通知类型开关）。
    final caps = await IslandLyricService.queryCapabilities();
    if (!mounted) return;
    _capabilities.value = caps;
    _ensureNotificationTypeAvailable(caps);
    _loading.value = false;
  }

  /// 若当前保存的通知类型在当前设备上不可用，回退到可用的默认类型
  /// （优先实时通知，其次焦点通知；都不可用时整个区块会被隐藏）。
  void _ensureNotificationTypeAvailable(IslandCapabilities caps) {
    final liveAvailable = caps.liveEnabled;
    final focusAvailable = caps.focusEnabled;
    final current = IslandLyricSettings.notificationType.value;
    final currentAvailable = current == IslandLyricSettings.typeLive
        ? liveAvailable
        : focusAvailable;
    if (currentAvailable) return;
    if (liveAvailable) {
      IslandLyricSettings.setNotificationType(IslandLyricSettings.typeLive);
    } else if (focusAvailable) {
      IslandLyricSettings.setNotificationType(IslandLyricSettings.typeFocus);
    }
  }

  Future<void> _updateBool(String key, bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, value);
    await LyricsService.instance.refreshSettings();
  }

  void _setMeizuLyrics(bool value) async {
    _meizuLyrics.value = value;
    _updateBool(_prefsMeizuLyrics, value);
  }

  void _setLyriconEnabled(bool value) {
    _lyriconEnabled.value = value;
    _updateBool(_prefsLyriconEnabled, value);
  }

  void _setLyriconForceKaraoke(bool value) {
    _lyriconForceKaraoke.value = value;
    _updateBool(_prefsLyriconForceKaraoke, value);
  }

  void _setLyriconHideTranslation(bool value) {
    _lyriconHideTranslation.value = value;
    _updateBool(_prefsLyriconHideTranslation, value);
  }

  void _setCarBluetoothLyrics(bool value) {
    _carBluetoothLyrics.value = value;
    MediaNotificationSettings.setCarBluetoothLyrics(value);
  }

  /// 打开 MIUI/HyperOS 息屏通知设置页（提示用户关闭息屏通知）。
  Future<void> _openAodSettings() async {
    final ok = await IslandLyricService.openAodSettings();
    if (!mounted) return;
    if (!ok) {
      AppToast.show(
        context,
        '无法打开息屏通知设置（可能不是小米设备或系统限制）',
        type: ToastType.error,
      );
    }
  }

  /// 切换「Shizuku 绕过白名单」：开启前先探测 Shizuku 授权，
  /// 未授权则拉起系统授权弹窗，授权成功才真正开启。
  Future<void> _setBypassFocusLimit(bool value) async {
    if (value) {
      final granted = await IslandLyricService.checkShizukuGranted();
      if (!mounted) return;
      if (!granted) {
        AppToast.show(
          context,
          'Shizuku 未授权或未运行，无法开启绕过',
          type: ToastType.error,
        );
        return;
      }
    }
    await IslandLyricSettings.setBypassFocusLimit(value);
  }

  @override
  Widget build(BuildContext context) {
    return Watch.builder(
      builder: (context) {
        if (_loading.value) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        return AppPageScaffold(
          extendBodyBehindAppBar: true,
          appBar: const AppTopBar(
            title: '歌词设置',
            backgroundColor: Colors.transparent,
            elevation: 0,
          ),
          showMiniPlayer: false,
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: [
              // 在线歌词：NAS 曲库常常完全没有歌词，联网取词是唯一来源。
              // 从「元数据管理」移到这里 —— 那边整段被服务端增强的可达性
              // 门控（未配置 FnMusicEnhance 时整块隐藏），导致没有后端的
              // 用户根本看不到这个开关。
              AppSettingSection(
                title: '在线歌词',
                children: [
                  ValueListenableBuilder<bool>(
                    valueListenable: LyricAutoSearchSettings.enabled,
                    builder: (context, enabled, _) {
                      return Column(
                        children: [
                          AppSettingSwitchTile(
                            title: '播放无歌词时自动搜索',
                            subtitle: enabled
                                ? '无歌词时联网搜索（内置源优先，无需服务端）'
                                : '关闭后仅使用 NAS 自带歌词与本地缓存',
                            value: enabled,
                            onChanged: (value) =>
                                LyricAutoSearchSettings.setEnabled(value),
                          ),
                          if (enabled) ...[
                            const Divider(height: 1),
                            ValueListenableBuilder<bool>(
                              valueListenable:
                                  LyricAutoSearchSettings.useBuiltinOnline,
                              builder: (context, builtin, _) {
                                return AppSettingSwitchTile(
                                  title: '内置在线歌词源',
                                  subtitle: builtin
                                      ? '直连网易云/QQ/酷狗/LRCLIB，支持逐字、翻译与繁简转换'
                                      : '仅通过服务端增强数据源搜索',
                                  value: builtin,
                                  onChanged: (value) =>
                                      LyricAutoSearchSettings
                                          .setUseBuiltinOnline(value),
                                );
                              },
                            ),
                            const Divider(height: 1),
                            ValueListenableBuilder<bool>(
                              valueListenable:
                                  LyricAutoSearchSettings.writeBack,
                              builder: (context, writeBack, _) {
                                return AppSettingSwitchTile(
                                  title: '搜索到后回写到 NAS',
                                  subtitle: writeBack
                                      ? '命中歌词写入服务端增强，其他设备可用（需已配置）'
                                      : '仅本地缓存，不回写服务器',
                                  value: writeBack,
                                  onChanged: (value) =>
                                      LyricAutoSearchSettings.setWriteBack(value),
                                );
                              },
                            ),
                          ],
                        ],
                      );
                    },
                  ),
                ],
              ),
              AppSettingSection(
                title: '状态栏歌词',
                children: [
                  AppSettingSwitchTile(
                    title: '魅族状态栏歌词',
                    subtitle: '需要系统或插件支持，不然请勿开启',
                    value: _meizuLyrics.value,
                    onChanged: _setMeizuLyrics,
                  ),
                  AppSettingSwitchTile(
                    title: 'Lyricon 服务',
                    subtitle: '为状态栏歌词应用提供服务支持',
                    value: _lyriconEnabled.value,
                    onChanged: _setLyriconEnabled,
                  ),
                  if (_lyriconEnabled.value)
                    AppSettingSwitchTile(
                      title: '强制逐字',
                      subtitle: '使用软件逐字模拟，一般不用开启',
                      value: _lyriconForceKaraoke.value,
                      onChanged: _setLyriconForceKaraoke,
                    ),
                  if (_lyriconEnabled.value)
                    AppSettingSwitchTile(
                      title: '隐藏歌词翻译',
                      subtitle: '仅发送原文歌词',
                      value: _lyriconHideTranslation.value,
                      onChanged: _setLyriconHideTranslation,
                    ),
                ],
              ),
              AppSettingSection(
                title: '车载蓝牙歌词',
                children: [
                  AppSettingSwitchTile(
                    title: '车载蓝牙歌词',
                    subtitle: '通过媒体会话发送歌词，供车载蓝牙播放器显示',
                    value: _carBluetoothLyrics.value,
                    onChanged: _setCarBluetoothLyrics,
                  ),
                ],
              ),
              AppSettingSection(
                title: '通知歌词灵动岛',
                children: [
                  // 灵动岛歌词主开关 + 子选项：两者都不可用时整个区块隐藏
                  ..._buildIslandSection(),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  /// 灵动岛设置区块内容。
  ///
  /// 按设备能力（[IslandCapabilities]）隐藏开关：
  /// - 实时通知需 [IslandCapabilities.liveEnabled]（Android 16+）；
  /// - 焦点通知需 [IslandCapabilities.focusEnabled]（HyperOS 2/OS2+ 焦点协议 +
  ///   权限开启）。
  /// - 两种模式都不可用时返回空（整个区块隐藏）。
  List<Widget> _buildIslandSection() {
    final caps = _capabilities.value;
    final liveAvailable = caps.liveEnabled;
    final focusAvailable = caps.focusEnabled;
    if (!liveAvailable && !focusAvailable) return const [];

    return [
      ValueListenableBuilder<bool>(
        valueListenable: IslandLyricSettings.enabled,
        builder: (context, enabled, _) {
          return AppSettingSwitchTile(
            title: '灵动岛歌词',
            subtitle: '播放有歌词的歌曲时，在系统灵动岛显示当前歌词行'
                '（实时通知需 Android 16+，HyperOS 需 3.0.300+，'
                'ColorOS/OneUI/AOSP 社区支持；焦点通知需 HyperOS 2/OS2+）',
            value: enabled,
            onChanged: (value) {
              IslandLyricSettings.setEnabled(value);
            },
          );
        },
      ),
      // 子选项随「灵动岛歌词」主开关显示/隐藏：未开启时隐藏
      ValueListenableBuilder<bool>(
        valueListenable: IslandLyricSettings.enabled,
        builder: (context, enabled, _) {
          if (!enabled) return const SizedBox.shrink();
          return Column(
            children: [
              // 通知类型：实时通知（无 root/Shizuku）vs 焦点通知
              ValueListenableBuilder<int>(
                valueListenable: IslandLyricSettings.notificationType,
                builder: (context, type, _) {
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '通知类型',
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        const SizedBox(height: 10),
                        SizedBox(
                          width: double.infinity,
                          child: SegmentedButton<int>(
                            segments: [
                              if (liveAvailable)
                                const ButtonSegment(
                                  value: IslandLyricSettings.typeLive,
                                  icon: Icon(
                                    Icons.notifications_active_outlined,
                                  ),
                                  label: Text('实时通知'),
                                ),
                              if (focusAvailable)
                                const ButtonSegment(
                                  value: IslandLyricSettings.typeFocus,
                                  icon: Icon(
                                    Icons.notification_important_outlined,
                                  ),
                                  label: Text('焦点通知'),
                                ),
                            ],
                            selected: {type},
                            showSelectedIcon: false,
                            onSelectionChanged: (selection) {
                              IslandLyricSettings.setNotificationType(
                                selection.first,
                              );
                            },
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          type == IslandLyricSettings.typeLive
                              ? '实时通知（实况通知）：无 root/Shizuku，'
                                  '走系统实时通知接口上岛。支持小米 '
                                  'HyperOS（3.0.300+，已验证）、ColorOS、'
                                  'OneUI、AOSP（社区支持），需 Android 16+'
                              : '焦点通知：走 MIUI 焦点通知上岛。HyperOS '
                                  '2/OS2 起支持（OS2 与 OS3 模板不同，OS3 '
                                  '为超级岛），需将本应用加入系统焦点通知白名单'
                                  '（或开启下方 Shizuku 绕过）',
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                        ),
                      ],
                    ),
                  );
                },
              ),
              // Shizuku 绕过焦点通知白名单：仅焦点通知需要白名单，
              // 实时通知无需此开关（无 root 直接上岛）。
              ValueListenableBuilder<int>(
                valueListenable: IslandLyricSettings.notificationType,
                builder: (context, type, _) {
                  if (type != IslandLyricSettings.typeFocus) {
                    return const SizedBox.shrink();
                  }
                  return ValueListenableBuilder<bool>(
                    valueListenable: IslandLyricSettings.bypassFocusLimit,
                    builder: (context, bypass, _) {
                      return AppSettingSwitchTile(
                        title: 'Shizuku 绕过白名单',
                        subtitle: '通过 Shizuku 在发送时短暂拦截 XMSF 网络'
                            '以绕过焦点通知白名单（需已授予 Shizuku 权限）'
                            '。注意：可能导致耗电增加或消息延迟',
                        value: bypass,
                        onChanged: _setBypassFocusLimit,
                      );
                    },
                  );
                },
              ),
              ValueListenableBuilder<bool>(
                valueListenable: IslandLyricSettings.showProgress,
                builder: (context, showProgress, _) {
                  return AppSettingSwitchTile(
                    title: '显示播放进度',
                    subtitle: '在灵动岛小胶囊上显示播放进度',
                    value: showProgress,
                    onChanged: (value) {
                      IslandLyricSettings.setShowProgress(value);
                    },
                  );
                },
              ),
              // 息屏歌词：焦点通知下可开/关；实时通知下息屏歌词由系统
              // 实时动态自带（关不掉），开关显示为置灰常开，但关闭状态
              // 仍透传给 service 层。
              ValueListenableBuilder<int>(
                valueListenable: IslandLyricSettings.notificationType,
                builder: (context, type, _) {
                  final isLive = type == IslandLyricSettings.typeLive;
                  return Column(
                    children: [
                      ValueListenableBuilder<bool>(
                        valueListenable: IslandLyricSettings.aodLyrics,
                        builder: (context, aodLyrics, _) {
                          // 反向语义：开 = 息屏显示歌曲名；关（默认）=
                          // 息屏显示歌词。实时通知下开关不可操作，
                          // 显示为关闭（默认）；但实际设置值仍透传。
                          return AppSettingSwitchTile(
                            title: '息屏显示为歌名',
                            subtitle: isLive
                                ? '实时通知不支持，保持关闭'
                                : '开启后息屏显示歌曲名；关闭则息屏显示当前歌词'
                                    '（封面+歌词）',
                            value: isLive ? false : aodLyrics,
                            onChanged: isLive
                                ? null
                                : (value) {
                                    IslandLyricSettings.setAodLyrics(value);
                                  },
                          );
                        },
                      ),
                      if (_isHyperOs.value)
                        AppSettingTile(
                          title: '息屏通知设置',
                          subtitle: '跳转到系统息屏通知设置页，'
                              '关闭息屏通知以配合息屏歌词使用避免被系统息屏重复亮屏',
                          onTap: _openAodSettings,
                        ),
                    ],
                  );
                },
              ),
              ValueListenableBuilder<bool>(
                valueListenable: IslandLyricSettings.testMode,
                builder: (context, testMode, _) {
                  return AppSettingSwitchTile(
                    title: '测试模式',
                    subtitle: '不播放音乐时也持续模拟发送通知，'
                        '验证暂停/无播放时灵动岛是否仍能显示',
                    value: testMode,
                    onChanged: (value) {
                      IslandLyricSettings.setTestMode(value);
                    },
                  );
                },
              ),
            ],
          );
        },
      ),
    ];
  }
}
