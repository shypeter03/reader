//
//  SherpaKokoroTTSService.swift
//  Reader
//
//  第二套本地 TTS 后端：sherpa-onnx + Kokoro。
//
//  与 Qwen3-TTS 的关系：**完全独立、并列存在**。这个文件不调用、不修改、
//  不继承任何 Qwen3-TTS 的实现；只有 TTSService 这一层协议是共用的。
//  当前后端默认值是 Edge TTS，Kokoro 在降级链的兜底位（见 ``TTSEngineType/current``）；
//  在设置里可以把 Kokoro 选回主位，Qwen3-TTS 也能显式选回。
//  Kokoro 模型缺失时：主位上组合根会自动退回 Qwen3，兜底位上只是少一条退路。
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

    /// 磁盘缓存命名空间：Kokoro 的 WAV 落在 `{book}/{chapter}/kokoro-v3/` 下。
    /// 与 Qwen3-TTS 的平铺路径分开，两边互不误命中，也不改动对方的既有格式。
    ///
    /// 换版本号的理由：缓存键只有「书/章/句」，**不含声音、也不含合成前的清洗**
    /// （``KokoroSpeechText`` 只改送去合成的文本，不改句子自己的文本/ID）。所以
    /// 改 sid、改断句规则、改清洗规则，旧 WAV 都仍然会命中，听感上就是「换了个寂寞」。
    /// v2→v3：旁白换成小说旁白向的那把，且句中拉丁片段从此不念。
    /// 以后再动 ``KokoroVoiceMap`` / ``SentenceSplitter`` / ``KokoroSpeechText``，这里要一起加一位。
    nonisolated static let audioNamespace = "kokoro-v3"

    /// 一句最多试几次。
    ///
    /// 实测结论和直觉相反：坏音频**基本是确定性的**——同一 (文本, 声音, 语速) 组合
    /// 在 4 线程下连试 6 次全坏，换文本/换声音才干净（`kokoro-probe rate`）。
    /// 所以重试不是主手段，只值一次：它只能捞到那 ~1/18 的非确定性样本，
    /// 多试纯粹把整章合成时间拉长（每次 ≈2s）。真正的规避在断句阶段
    /// （``SentenceSplitter`` 不再切出 <4 字的碎片）和选声音阶段
    /// （``KokoroVoiceMap`` 挑稳健的 sid）。过不去的句子交给降级链。
    nonisolated static let generationAttempts = 2

    /// 只重试「重掷骰子可能过」的错误。结构性错误（sid 越界、声音表不一致、
    /// 引擎没加载）重试一万次也一样，必须立刻抛给降级链。
    nonisolated static func isRetryable(_ error: Error) -> Bool {
        switch error {
        case KokoroTTSError.corruptedAudio, KokoroTTSError.silentAudio, KokoroTTSError.emptyAudio:
            return true
        default:
            return false
        }
    }

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

    /// 进程驻留内存（phys_footprint）峰值。放在实例上而不是全局变量里：本类是
    /// 进程内单实例，actor 的串行性天然保护它。`MemoryProbe` 读的是 MLX allocator
    /// 的计数器，Kokoro 走 ONNX Runtime、不产生任何 MLX 分配，所以必须另外量。
    /// 注意它是**整个进程**的量（含 LLM 与播放器），不是 Kokoro 自己的占用；
    /// Kokoro 自己的部分看 `kokoroLoadDeltaMB`。
    private var peakFootprintMB: Double = 0

    /// 加载引擎这一步真实增加的驻留量 = 权重 + ORT arena，才是 Kokoro 的账面占用。
    private var kokoroLoadDeltaMB: Double = 0

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
        kokoroLoadDeltaMB = footprintAfter - footprintBefore

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
        进程驻留 \(String(format: "%.0f", footprintBefore))→\(String(format: "%.0f", footprintAfter))MB（Kokoro 自身 +\(String(format: "%.0f", kokoroLoadDeltaMB))MB）
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

        // 坏音频（整段前缀 NaN / 全静音）主要由「文本 + 声音」这一对决定，不是每句掷骰子，
        // 所以只补一次；过不去就抛，让 FallbackTTSService 把这一句交给 Edge。
        let (spokenText, droppedFragments) = KokoroSpeechText.speakable(text)
        if !droppedFragments.isEmpty {
            print("[Kokoro🚫] 吞掉非中文片段 \(droppedFragments) ← 「\(text.prefix(16))…」")
        }

        var generated: KokoroGenerationResult?
        var lastError: Error?
        var attempts = 0

        while attempts < Self.generationAttempts {
            attempts += 1
            do {
                generated = try await engine.generate(text: spokenText, voice: voice, speed: speed)
                break
            } catch {
                lastError = error
                if Self.isRetryable(error), attempts < Self.generationAttempts {
                    print("[Kokoro🔁] 「\(text.prefix(12))」第 \(attempts) 次失败（\(error)），重试")
                } else {
                    break
                }
            }
        }

        let result: KokoroGenerationResult
        if let generated {
            result = generated
        } else {
            let error = lastError ?? KokoroTTSError.engineNotLoaded
            print("[Kokoro⚠️] 合成失败（voice=\(voice.name) sid=\(voice.sid)，试了 \(attempts) 次）：\(error)")
            throw error
        }

        let metrics = result.metrics
        let wav = result.audio.wavData()
        let footprintNow = KokoroProcessMemory.footprintMB()
        peakFootprintMB = max(peakFootprintMB, footprintNow)

        if !didLogFirstGeneration {
            didLogFirstGeneration = true
            print("[Kokoro⏱] 首句生成 \(String(format: "%.0f", metrics.generationTime * 1000))ms（含冷启动）")
        }

        // 并行度 = 进程 CPU 秒 / 墙钟秒。≈ 线程数说明「真在算」；明显小于 1 说明
        // 线程被饿着（抢核）或被降频。配上热档和**当前**驻留，才能把
        // 「后面的句子 RTF 涨到 3」归因到 长度 / 抢核 / 降频 / 内存压力 中的哪一个。
        let parallelism = metrics.generationTime > 0
            ? metrics.cpuTime / metrics.generationTime : 0
        let characters = spokenText.filter { $0.isLetter || $0.isNumber }.count

        // 首尾都打：句尾多出怪音（听感像英文单词）只可能来自**文本尾部**的某个
        // 非中文片段，光看前 8 个字永远定位不到。这里打的是清洗后真正送进去的文本。
        print("""
        [Kokoro⏱] 「\(spokenText.prefix(8))…\(spokenText.suffix(12))」 voice=\(voice.name)(sid \(voice.sid)) \
        speed=\(String(format: "%.2f", metrics.appliedSpeed)) \
        字\(characters) \
        音频 \(String(format: "%.2f", metrics.audioDuration))s \
        生成 \(String(format: "%.0f", metrics.generationTime * 1000))ms \
        RTF \(String(format: "%.2f", metrics.rtf)) \
        并行度\(String(format: "%.2f", parallelism))/\(numThreads)线程 \
        \(KokoroProcessMemory.thermalState()) \
        驻留 \(String(format: "%.0f", footprintNow))MB（峰值 \(String(format: "%.0f", peakFootprintMB))MB）
        """)
        MemoryProbe.log("Kokoro 单句合成")

        return wav
    }

    // MARK: - Unload

    func unload() async {
        guard let engine else { return }
        let footprintBefore = KokoroProcessMemory.footprintMB()
        await engine.unload()
        self.engine = nil
        voiceTable = []
        resolvedVoices = [:]
        let footprintAfter = KokoroProcessMemory.footprintMB()
        // 两个数一起打：交还量才是 Kokoro 的账，剩下的驻留属于别人（MLX cached、
        // 播放器、App 自身），别记在它头上。
        print("""
        Kokoro 已卸载：进程驻留 \(String(format: "%.0f", footprintBefore))→\
        \(String(format: "%.0f", footprintAfter))MB（交还 \(String(format: "%.0f", max(0, footprintBefore - footprintAfter)))MB，\
        Kokoro 账面占用 \(String(format: "%.0f", kokoroLoadDeltaMB))MB，进程峰值 \(String(format: "%.0f", peakFootprintMB))MB）
        """)
        MemoryProbe.log("Kokoro 卸载后")
    }
}
