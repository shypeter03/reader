//
//  SherpaKokoroTTSService.swift
//  Reader
//
//  第二套本地 TTS 后端：sherpa-onnx + Kokoro。
//
//  与 Qwen3-TTS 的关系：**完全独立、并列存在**。这个文件不调用、不修改、
//  不继承任何 Qwen3-TTS 的实现；只有 TTSService 这一层协议是共用的。
//  当前后端默认值就是 Kokoro（见 ``TTSEngineType/current``），Qwen3-TTS 可在
//  设置里显式选回；Kokoro 模型缺失时组合根会自动退回 Qwen3。
//
//  生命周期（要求「整个章节只加载一次模型」）：
//   - `init` 不加载、不抛错 → 模型没装也照样能启动 App；
//   - 第一句 `synthesize` 时 `load()`，之后引擎常驻；
//   - 后续每句复用同一个引擎；
//   - 只有 `unload()`（切换后端 / 内存吃紧）才释放。
//
//  并发：`KokoroTTSEngine` 本身是 actor，本类也是 actor，所以底层那个
//  C 侧 TTS 实例不会被多个 Task 同时戳。
//

import Foundation
import SherpaKokoroKit

actor SherpaKokoroTTSService: TTSService {

    /// 磁盘缓存命名空间：Kokoro 的 WAV 落在 `{book}/{chapter}/kokoro/` 下。
    /// 与 Qwen3-TTS 的平铺路径分开，两边互不误命中，也不改动对方的既有格式。
    nonisolated static let audioNamespace = "kokoro"

    /// 引擎在第一次合成时才建（构造可能因为模型缺失抛错）。
    private var engine: KokoroTTSEngine?

    /// 当前模型的声音表（下标即 sid），来自引擎加载时的 metadata 解析。
    private var voiceTable: [KokoroVoice] = []

    /// voiceID → 声音。缓存它有两个作用：省掉每句一次查表，以及保证
    /// 「同一角色在整个进程里绝不换嗓」（查表本身是确定性的，这里是双保险）。
    private var resolvedVoices: [String: KokoroVoice] = [:]

    private let language: KokoroConfiguration.Language
    private let numThreads: Int

    private var didLogFirstGeneration = false

    /// 进程常驻内存峰值。放在实例上而不是全局变量里：本类是进程内单实例，
    /// actor 的串行性天然保护它。`MemoryProbe` 读的是 MLX allocator 的计数器，
    /// Kokoro 走 ONNX Runtime、不产生任何 MLX 分配，所以必须另外量。
    private var peakFootprintMB: Double = 0

    init(
        language: KokoroConfiguration.Language = .zh,
        numThreads: Int = KokoroConfiguration.recommendedThreadCount
    ) {
        self.language = language
        self.numThreads = numThreads
    }

    /// 模型是否已经就位（只查目录、不加载）。设置页用它决定要不要提示下载。
    /// `nonisolated`：组合根在 `ReaderContainer.init` 里同步调用它，那里不能 await。
    nonisolated static func modelDirectoryIfAvailable() -> String? {
        (try? KokoroModelLocator.resolveKokoroModelDirectory())?.path
    }

    // MARK: - Load

    private func ensureEngine() async throws -> KokoroTTSEngine {
        if let engine { return engine }

        let footprintBefore = KokoroProcessMemory.footprintMB()
        let started = CFAbsoluteTimeGetCurrent()
        let built = try KokoroTTSEngine.automatic(language: language, numThreads: numThreads)
        let report = try await built.load()
        let elapsed = (CFAbsoluteTimeGetCurrent() - started) * 1000

        engine = built
        voiceTable = await built.voices
        resolvedVoices = [:]

        let footprintAfter = KokoroProcessMemory.footprintMB()
        peakFootprintMB = max(peakFootprintMB, footprintAfter)

        // 声音表来自模型 metadata，不是代码里的常量：换 v1_0/v1_1 时这行日志
        // 就是「实际用的是哪套 sid」的证据。
        let zh = voiceTable.chinese
        let bundleRoot = Bundle.main.bundlePath
        let fromBundle = report.modelDirectory.hasPrefix(bundleRoot)

        print("""
        [Kokoro⏱] 模型加载 \(String(format: "%.0f", elapsed))ms \
        来源=\(fromBundle ? "App bundle" : "外部目录") dir=\(report.modelDirectory) \
        sherpa-onnx=\(report.sherpaOnnxVersion) ort=\(report.onnxruntimeVersion) \
        sampleRate=\(report.sampleRate)Hz voices=\(report.speakerCount) \
        中文=\(zh.count)(男 \(zh.chinese(gender: .male).count)/女 \(zh.chinese(gender: .female).count)) \
        threads=\(report.numThreads) ruleFST=\(report.ruleFSTCount) \
        常驻内存 \(String(format: "%.0f", footprintBefore))→\(String(format: "%.0f", footprintAfter))MB
        """)
        print("[Kokoro🗣] \(KokoroVoiceMap.resolvedSidSummary(for: voiceTable))")
        MemoryProbe.log("Kokoro 加载后")
        return built
    }

    // MARK: - TTSService

    /// Kokoro 真实可控的只有三样：`sid`（音色）、`speed`（语速）、`silence_scale`（停顿比例）。
    /// 所以下面这些入参是被**显式忽略**的，不是漏实现：
    ///
    /// - `pitch`：Kokoro 的 ONNX 图没有音高入口，sherpa-onnx 也不提供后处理变调。
    ///   用 AVAudioUnitTimePitch 二次处理属于伪造控制且带音质损失，这里不做。
    /// - `voiceStrength` / `intensity`：同理，没有对应控制量。
    /// - `emotion`：**不再额外映射一次**。上游的 `speed` 已经由
    ///   ``Emotion/defaultSpeed`` 带上了各情绪的推荐语速，再叠加
    ///   ``KokoroEmotion/speedDelta`` 会重复计算（sad 会变成 0.92×0.94）。
    ///   情绪→语速这条 Kokoro 唯一有效的通道已经生效了。
    /// - Qwen3 的 `instruct` 自然语言风格提示：Kokoro 没有这个概念，不传。
    func synthesize(
        text: String,
        voiceID: String,
        emotion: Emotion,
        intensity: Double,
        speed: Double,
        pitch: Double,
        voiceStrength: Double
    ) async throws -> Data {

        let engine = try await ensureEngine()

        let voice: KokoroVoice
        if let cached = resolvedVoices[voiceID] {
            voice = cached
        } else {
            guard let picked = KokoroVoiceMap.voice(for: voiceID, in: voiceTable) else {
                throw KokoroTTSError.speakerTableUnavailable(
                    modelFile: "当前模型没有中文声音（共 \(voiceTable.count) 把）")
            }
            voice = picked
            resolvedVoices[voiceID] = picked
        }

        let result: KokoroGenerationResult
        do {
            result = try await engine.generate(text: text, voice: voice, speed: speed)
        } catch {
            print("[Kokoro⚠️] 合成失败（voice=\(voice.name) sid=\(voice.sid)）：\(error)")
            throw error
        }

        let metrics = result.metrics
        let wav = result.audio.wavData()
        peakFootprintMB = max(peakFootprintMB, KokoroProcessMemory.footprintMB())

        if !didLogFirstGeneration {
            didLogFirstGeneration = true
            print("[Kokoro⏱] 首句生成 \(String(format: "%.0f", metrics.generationTime * 1000))ms（含冷启动）")
        }

        print("""
        [Kokoro⏱] 「\(text.prefix(8))」 voice=\(voice.name)(sid \(voice.sid)) \
        speed=\(String(format: "%.2f", metrics.appliedSpeed)) \
        音频 \(String(format: "%.2f", metrics.audioDuration))s \
        生成 \(String(format: "%.0f", metrics.generationTime * 1000))ms \
        RTF \(String(format: "%.2f", metrics.rtf)) \
        峰值内存 \(String(format: "%.0f", peakFootprintMB))MB
        """)
        MemoryProbe.log("Kokoro 单句合成")

        return wav
    }

    // MARK: - Unload

    func unload() async {
        guard let engine else { return }
        await engine.unload()
        self.engine = nil
        voiceTable = []
        resolvedVoices = [:]
        print("Kokoro 已卸载，权重内存已释放（峰值 \(String(format: "%.0f", peakFootprintMB))MB）")
        MemoryProbe.log("Kokoro 卸载后")
    }
}
