//
//  KokoroTTSEngine.swift
//  SherpaKokoroKit
//

import Foundation
import SherpaOnnx

/// sherpa-onnx + Kokoro 的独立 TTS 后端。
///
/// 设计约束：
/// - **模型只加载一次**。``load()`` 之后 ``generate(text:voice:speed:)`` 复用同一个
///   C 引擎实例，直到 ``unload()``。绝不出现「每句 load→generate→destroy」。
/// - **串行**。ONNX Runtime 的 `OfflineTts` 不是线程安全的，所以整个引擎包在
///   actor 里，同一时刻只有一个 generate 在跑（sherpa 内部也是一条固定线程池）。
///   并发预取交给上层的作业队列排队，不在这里并发推理。
public actor KokoroTTSEngine {

    public let configuration: KokoroConfiguration

    private var engine: SherpaOnnxOfflineTtsWrapper?

    private var report: KokoroLoadReport?

    /// 加载时按模型 metadata 解析出来的 sid 表，下标即 sid。
    private var voiceTable: [KokoroVoice] = []

    public init(configuration: KokoroConfiguration) {
        self.configuration = configuration
    }

    /// 用默认候选目录创建（找不到模型直接抛错，不会留下半死的实例）。
    public static func automatic(
        language: KokoroConfiguration.Language = .zh,
        numThreads: Int = KokoroConfiguration.recommendedThreadCount
    ) throws -> KokoroTTSEngine {
        let config = try KokoroConfiguration.automatic(language: language)
        var mutable = config
        mutable.numThreads = numThreads
        return KokoroTTSEngine(configuration: mutable)
    }

    // MARK: - Load

    /// 加载 Kokoro 权重。幂等：已加载时直接返回上一次的报告。
    @discardableResult
    public func load() throws -> KokoroLoadReport {
        if let report { return report }

        let files = configuration.modelFiles
        let started = CFAbsoluteTimeGetCurrent()

        // 这些 Swift 字符串必须活到 Create 返回：wrapper 里的 toCPointer 只是
        // 把 String 的 UTF-8 缓冲区指针递给 C，C 层在 Create 内部会各自拷贝。
        let modelPath = files.model.path
        let voicesPath = files.voices.path
        let tokensPath = files.tokens.path
        let dataDirPath = files.espeakData.path
        let lexiconArg = configuration.lexiconArgument
        let ruleFSTArg = configuration.ruleFSTArgument

        let kokoro = sherpaOnnxOfflineTtsKokoroModelConfig(
            model: modelPath,
            voices: voicesPath,
            tokens: tokensPath,
            dataDir: dataDirPath,
            lengthScale: 1.0,
            dictDir: "",
            lexicon: lexiconArg,
            // 中文没有对应的 lang 取值；留空让 sherpa 按 voices.bin 的
            // meta_data.voice 走，语言由 lexicon 决定。
            lang: ""
        )

        let modelConfig = sherpaOnnxOfflineTtsModelConfig(
            kokoro: kokoro,
            numThreads: configuration.numThreads,
            debug: configuration.debug ? 1 : 0,
            provider: "cpu"
        )

        let ttsConfig = sherpaOnnxOfflineTtsConfig(
            model: modelConfig,
            ruleFsts: ruleFSTArg,
            ruleFars: "",
            maxNumSentences: 1,
            silenceScale: configuration.silenceScale
        )

        var mutableConfig = ttsConfig
        let created = withExtendedLifetime(
            (modelPath, voicesPath, tokensPath, dataDirPath, lexiconArg, ruleFSTArg)
        ) {
            SherpaOnnxOfflineTtsWrapper(config: &mutableConfig)
        }

        guard created.tts != nil else {
            throw KokoroTTSError.engineCreateFailed(directory: files.directory.path)
        }

        let speakerCount = Int(created.numSpeakers)
        guard speakerCount > 0 else {
            throw KokoroTTSError.engineCreateFailed(directory: files.directory.path)
        }

        // sid 表必须来自这个模型本身：v1_0 有 54 把声音、v1_1 有 103 把，
        // 同一个 sid 在两边指向完全不同的人（v1_1 的 sid 52 是女声 zf_088，
        // v1_0 的 sid 52 是男声 zm_yunyang）。越界检查挡不住这种错位，
        // 所以读不到表就停在这里，不用任何「默认表」兜底。
        guard let names = KokoroSpeakerTable.speakerNames(modelURL: files.model) else {
            throw KokoroTTSError.speakerTableUnavailable(
                modelFile: files.model.lastPathComponent)
        }
        guard names.count == speakerCount else {
            throw KokoroTTSError.speakerTableMismatch(
                metadataCount: names.count, engineCount: speakerCount)
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - started
        engine = created
        voiceTable = KokoroVoice.table(from: names)

        let loaded = KokoroLoadReport(
            modelDirectory: files.directory.path,
            loadTime: elapsed,
            sampleRate: Int(created.sampleRate),
            speakerCount: speakerCount,
            numThreads: configuration.numThreads,
            language: configuration.language.rawValue,
            sherpaOnnxVersion: getSherpaOnnxVersion(),
            onnxruntimeVersion: getSherpaOnnxOnnxruntimeVersion(),
            ruleFSTCount: configuration.usesTextNormalizationRules ? files.ruleFSTS.count : 0,
            lexiconFiles: files.lexicons.map(\.lastPathComponent),
            speakerNames: names
        )
        report = loaded
        return loaded
    }

    public var loadReport: KokoroLoadReport? { report }

    public var isLoaded: Bool { engine != nil }

    /// 模型实际支持的说话人数量（加载后才有值）。用于校验 sid 越界。
    public var speakerCount: Int? { report?.speakerCount }

    /// 加载后从模型 metadata 解析出的声音表，下标即 sid。未加载时为空。
    public var voices: [KokoroVoice] { voiceTable }

    /// 表里的中文声音（`zf_`/`zm_`），Reader 朗读小说只用这批。
    public var chineseVoices: [KokoroVoice] { voiceTable.chinese }

    // MARK: - Generate

    /// 合成一句话。
    ///
    /// - Parameter voice: 必须是 ``voices`` 里的一把（即由当前这个模型解析出来的），
    ///   所以这里没有默认值——换模型时「默认旁白」本身就是个会错的东西。
    /// - Parameter speed: 语速，>1 更快。底层真实支持，会被夹到
    ///   ``KokoroConfiguration/minimumSpeed``...``KokoroConfiguration/maximumSpeed``。
    /// - Note: 这里刻意**没有** `instruct` / `pitch` / `emotion` / `voiceStrength`
    ///   参数。sherpa-onnx 的 Kokoro 只暴露 `sid`、`speed`、`silence_scale`
    ///   三个可控量，伪造这些参数只会让上层误以为它们在起作用。
    ///   情绪到 Kokoro 的有限映射放在 ``KokoroEmotionMapping``。
    public func generate(
        text: String,
        voice: KokoroVoice,
        speed: Double? = nil
    ) throws -> KokoroGenerationResult {

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw KokoroTTSError.emptyAudio(text: text)
        }

        let engine = try requireEngine()

        let count = voiceTable.count
        guard count > 0 else { throw KokoroTTSError.engineNotLoaded }
        if voice.sid < 0 || voice.sid >= count {
            throw KokoroTTSError.invalidVoice(sid: voice.sid, speakerCount: count)
        }
        // 名字也要对得上：只校验 sid 范围的话，拿 v1_0 的表去戳 v1_1 的引擎
        // 依然是「合法 sid」，只会静默换人。
        if voiceTable[voice.sid].name != voice.name {
            throw KokoroTTSError.speakerNameMismatch(
                sid: voice.sid,
                expected: voiceTable[voice.sid].name,
                given: voice.name)
        }

        let effectiveSpeed = KokoroConfiguration.clampedSpeed(speed ?? Double(configuration.defaultSpeed))

        let config = SherpaOnnxGenerationConfigSwift(
            silenceScale: configuration.silenceScale,
            speed: effectiveSpeed,
            sid: voice.sid
        )

        let started = CFAbsoluteTimeGetCurrent()
        let audio = engine.generateWithConfig(text: trimmed, config: config, callback: nil, arg: nil)
        let elapsed = CFAbsoluteTimeGetCurrent() - started

        let samples = audio.samples
        guard !samples.isEmpty else {
            throw KokoroTTSError.emptyAudio(text: text)
        }

        let sampleRate = Int(audio.sampleRate)
        let result = KokoroAudio(samples: samples, sampleRate: sampleRate)
        let duration = result.duration

        return KokoroGenerationResult(
            audio: result,
            metrics: KokoroGenerationMetrics(
                voice: voice,
                requestedSpeed: speed ?? Double(configuration.defaultSpeed),
                appliedSpeed: Double(effectiveSpeed),
                sampleCount: samples.count,
                sampleRate: sampleRate,
                audioDuration: duration,
                generationTime: elapsed,
                rtf: duration > 0 ? elapsed / duration : .infinity
            )
        )
    }

    private func requireEngine() throws -> SherpaOnnxOfflineTtsWrapper {
        guard let engine else { throw KokoroTTSError.engineNotLoaded }
        return engine
    }

    // MARK: - Unload

    /// 释放 C 侧引擎。权重内存随 wrapper 的 deinit 归还。
    public func unload() {
        engine = nil
        report = nil
        voiceTable = []
    }
}

// MARK: - Reports

public struct KokoroLoadReport: Sendable {
    public let modelDirectory: String
    /// 权重加载耗时（秒）。这是 Kokoro 相对 Qwen3-TTS 的主要优势之一。
    public let loadTime: TimeInterval
    public let sampleRate: Int
    public let speakerCount: Int
    public let numThreads: Int
    public let language: String
    public let sherpaOnnxVersion: String
    public let onnxruntimeVersion: String
    public let ruleFSTCount: Int
    public let lexiconFiles: [String]
    /// 模型 metadata 里的 sid→声音名表（下标即 sid）。换模型时唯一的真相来源。
    public let speakerNames: [String]
}

public struct KokoroGenerationMetrics: Sendable {
    public let voice: KokoroVoice
    public let requestedSpeed: Double
    public let appliedSpeed: Double
    public let sampleCount: Int
    public let sampleRate: Int
    public let audioDuration: Double
    public let generationTime: Double
    /// real-time factor：generationTime / audioDuration。越小越好。
    public let rtf: Double
}

public struct KokoroGenerationResult: Sendable {
    public let audio: KokoroAudio
    public let metrics: KokoroGenerationMetrics
}
