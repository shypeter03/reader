# 纸声（Reader）

本地优先的中文小说 EPUB 阅读器：导入一本书 → 端侧标注情绪与说话人 → 书页式排版 → 逐句朗读（旁白和不同角色用不同嗓音）。全程可离线，权重由用户在 App 内下载，不打包进 App。

- 平台：iOS（App 目标最低 **17.6**，取自产物 `LC_BUILD_VERSION`；iPad 适配双页/宽纸面）
- UI：SwiftUI + 一处 UIKit（`UIPageViewController` 的卷页翻页）
- 推理：MLX Swift（千问解析 + 千问语音）、sherpa-onnx（Kokoro）、Edge TTS（联网兜底）

## 快速开始

```sh
xcodebuild -scheme Reader -sdk iphoneos -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build
```

两个坑：

- **不要用 `-target Reader`**：会在 `MLXHuggingFaceMacros` 上失败，必须走 `-scheme` + `-sdk iphoneos`。
- **MLX 编不进 Mac 命令行探针**（`xcrun swiftc` 那一路不行），所以 `.probe/` 里的探针一律纯 Swift / 纯算式，不 import MLX。真机是唯一能验推理与听感的地方。

模型不在仓库里：**设置 → 模型下载** 逐文件拉进沙盒（带进度、sha256 校验、失败退镜像）。缺权重时对应后端在降级链里被跳过，不会拿失败次数去撞。

## 目录

| 目录 | 做什么 |
| --- | --- |
| `Reader/Parsing`, `Reader/Import` | EPUB 解包、章节树、正文与图片抽取、句子切分 |
| `Reader/AI` | 端侧标注：`CharacterAnalysis`（说话人/性别，纯规则）、`FastChapterAnalyzer`（规则情绪）、`QwenChapterAnalyzer` + `MLXQwenService`（千问只做情绪+强度）、`MemoryProbe` |
| `Reader/Engine`, `Reader/Render` | 排版内核（分页、两端对齐、行距）与把纸画出来的渲染端 |
| `Reader/Core` | `ReaderPipeline`：任务队列、内存闸口、排产窗口；`AppLog` |
| `Reader/TTS` | 外层 `FallbackTTSService`（三后端顺位降级）+ 各后端实现；`VoiceManager`（角色→嗓音） |
| `Reader/Qwen3TTS` | swift-qwen3-tts 那套引擎的本地副本（talker / code predictor / 声码） |
| `Reader/Storage` | `ModelManifest` + `ModelStore`（权重清单与落地）、`AudioStore`、章节与分页缓存 |
| `Reader/View` | 书库、阅读页、播放坞、设置页、`PlayerManager` |

## 运行时链路

1. **导入**：`fileImporter` 收 `.epub`（安全作用域 URL，可能在 iCloud）→ 解出章节与句子。
2. **解析**（可完全离线，也可完全不跑模型）：规则引擎定「谁在说话」和性别，千问只补「什么情绪、多强」。关掉**增强情绪表现**后，标注只走规则，千问权重不再加载，所有句子统一语气。
3. **排产**：解析按窗口补产（`analysisWindowBatches = 200`、`analysisWindowChapters = 40`）；音频只提前排 `ttsLookahead = 24` 句跑道。终态失败（额度用尽、预估超预算）不再重跑。
4. **分页**：点开一章 1s 内出正文是硬指标——排产与写盘不许挂在 `openChapter` 的 await 上，验收看 `[Open]` 日志。
5. **朗读**：逐句合成落盘（按后端分命名空间：`edge-v1` / `kokoro-v3` / 千问是平铺旧形状），读缓存按顺位全问一遍，所以换后端不会把整本书重录。

## 语音后端

`FallbackTTSService` 拿一个顺序（选谁谁第一，其余兜底，例如选千问是 `qwen → edge → kokoro`），一句一句试：

- 连续失败 `failureThreshold = 4` 次才把那一格从本轮链里摘掉，并且**当场卸它的权重**；
- 「这一段两次没过时长质检」（`outputRejected`）**不计**连坏次数——判的是输出，不是后端坏了；
- 会往 Metal 提交推理的只有千问（`submitsToGPU`），所以进后台必须停它，Edge/Kokoro 可以继续出声。

千问那一路的质检与闸门（`Qwen3TTSService`）：帧率 12.5 帧 = 1 秒音频；一帧上限按「预期时长 ×2.2」算（48 字 ≈ 330 帧）；一句一份墙钟预算（`max(12s, 上限帧数 × 0.30s)`），两次重试花同一份。句末留 0.4s 呼吸，被裁开的半句只留 0.05s（接缝后面紧跟着另一次合成，两处都留 0.4s 听感就是「话在半路停一下」）。

## 内存与后台：三条必须知道的

1. **后台不许提交 GPU**。MLX 在后台跑 GPU 会抛 Swift 抓不住的 C++ `std::runtime_error`，进程直接 terminate。所有推理入口先过 `AppBackgroundGate.ensureForeground()`。
2. **置 nil 不等于把内存还给系统**。失引用的 buffer 留在 MLX 分配器缓存池里（上限 `cacheLimitBytes = 2GiB`，超过 `clearThresholdBytes = 1536MB` 才回收），而 jetsam 判的是进程驻留。所以「卸载」必须跟着 `Memory.clearCache()`——解析和 TTS 两条路都要。
3. **内存闸口只记增量工作集，不含权重基线**。`MemoryBudgetManager`（`budgetBytes = 2GiB`，TTS 估 900MB、解析估 600MB）是人为声明的额度，`availableBytes = budget − reserved`，不读真实内存；而千问语音光权重就是 ~1.61GB（`ModelManifest` 记的 bytes：960MB + 650MB）。这是当前已知的结构性缺口，日志里 `[TTS][Memory] … 进程驻留 X MB（加载前 Y MB）` 和 `[Perf] … 内存上限=…MB 缓存上限=…MB` 就是用来把这道闸的数字定下来的。

## 探针（`.probe/`，不入库）

改排版、播放状态机、并发形状之前，先在 `.probe/` 跑对应脚本拿基线；**基线只能动手前存**。要点：

- 每个探针是一个可执行 `run-*.sh`，用 `xcrun -sdk macosx swiftc` 编一个 `main.swift`；
- 涉及 Swift 并发/actor 调度的探针必须按 `-swift-version 5` 编（工程是 `SWIFT_VERSION = 5.0`），语言模式换了调度规则就换了，结论不作数；
- 改了循环、播放、新增判定分支之前，先跑**回退版**确认探针会红；
- 热路径改前后用 `.probe/run-perf-ab.sh old|new` 切快照对比，不要用 `git stash`（工作区常有大量未提交）。

日志：`设置 → 导出日志文件`。上限是 2MB × 最近两段（最坏 4MB），排查完该删。真机核对项都靠日志说话，比较数字要同一个 iOS 大版本。

## 阅读页交互（口径固定，别再改动）

- 翻页带（含边缘 30pt）优先于点击手势；正文中部单击＝弹按钮（攒 250ms），双击＝读那一句；
- 翻书效果用 `UIPageViewController.pageCurl`，时长只能靠 `layer.speed` 拧；
- 纸上不印说话人名，`characterName` 只给语音用；
- 底部页码只有全书口径（第 N 页 / 共 M 页），取不到正文的章按 0 面计。
