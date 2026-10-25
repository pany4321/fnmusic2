# online_lyrics

内置多源在线歌词获取包（纯 Dart，无 Flutter 依赖）：**网易云 / QQ 音乐 / 酷狗 /
LRCLIB** 应用内直连搜索与取词，无需服务端增强（FnMusicEnhance）。

移植自 [fn-music](https://github.com/pany4321/fn-music)（GPL-3.0-only）的
`core/lyrics` 模块，其上游为 [LDDC](https://github.com/chenmozhijin/LDDC)；
LRCLIB 按 https://lrclib.net/docs 公开文档实现。

## 能力

- **两轮编排**（`LyricsMatchCoordinator`）：第一轮快源（网易云 / QQ 桌面搜索 /
  酷狗 / LRCLIB，单源 1.8s 预算）命中即返回；全部落空才进第二轮深挖（QQ 老接口
  `client_search_cp`，召回最好但慢，4.5s 预算）。快源全体网络失败时离线短路。
- **候选评分闸门**（`LyricsCandidateScorer`）：标题/歌手/专辑 difflib 相似度
  加权；时长差 >5s 拒绝；live/remix/伴奏/剪辑版等版本冲突一票否决；合辑歌手
  对不上时「标题几乎一致 + 时长 ≤2s」兜底放行；多源共识加分。
- **逐字歌词**：QQ QRC（XML 包装 + 3DES + zlib）、网易 YRC、酷狗 KRC（XOR +
  zlib）解密解析为带逐词时间戳的结构化文档；时长差过大自动降级为逐行。
- **翻译与注音**：侧轨按最近行起始对齐（±1500ms）；LRC 同时间戳多行按惯例
  视为「原文 + 翻译」。
- **日文假名注音剔除**：`（よ）` 类注音从正文与逐词轨道移除，普通括号保留。
- **LRCLIB 合规**：请求间隔 ≥200ms、429 按 `Retry-After` 进程级冷却、UA 标明
  客户端、只收有同步歌词的记录。
- **渲染**（`renderDocumentToLrcText`）：输出宿主 `LyricsParser` 可读的
  LRC 文本——逐词行渲染为交错逐字格式，翻译/注音行以同时间戳紧随其后。

## QRC 解密实现说明（重要）

QQ QRC 的 3DES **与标准 DES/3DES 库（pointycastle 等）不兼容**：上游 C#
参考实现按小端 uint 对块做字内反序位寻址。`src/lddc_tripledes.dart` 是
LDDC `tripledes.py` 的逐位移植，已用真实 `GetPlayLyricInfo` 载荷做块级
比对验证（`test/fixtures_qrc_payload.txt`）。不要改用 pointycastle。

## 应用接入

- `lib/app/services/lyrics/online_lyrics_gateway.dart`：映射「匹配设置」的
  歌词模式与翻译/注音开关到渲染偏好。
- `LyricsService`：无歌词自动搜索内置源优先，服务端增强数据源兜底。
- 歌曲编辑页手动匹配的歌词预取同样内置源优先。

## 本地验证

```bash
# 单元测试（离线，20 个）
dart test

# 四源在线探针（搜索 + 取词 + 端到端编排）
dart run tool/probe_sources.dart

# NAS 曲库命中率探针（凭据只经环境变量传入，勿写入文件）
FN_BASE=https://<host>:<port> FN_USER=<user> FN_PASS=<pass> \
  dart run tool/nas_hit_rate_probe.dart 30
```

## 许可

GPL-3.0-only（与上游 fn-music / LDDC 一致）。
