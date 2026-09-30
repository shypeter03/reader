//
//  Qwen3TTSService.swift
//  Reader
//

import Foundation
import MLX
import MLXNN

/// 基于 swift-qwen3-tts（AtomGradient）原生 Swift 实现的本地 TTS 后端。
/// 配套模型：Qwen3-TTS-12Hz-0.6B-CustomVoice-MLX-4bit
/// （官方 12.5Hz 声码器 + 4bit 量化，完整词表）。
actor Qwen3TTSService: TTSService {

    private var model: Qwen3TTSModel?

    private var isLoaded = false

    // MARK: - Model Config

    /// Bundle 内的蓝色 folder reference 名（需以 folder reference 方式加入工程）。
    private static let bundleResourceName =
        "Qwen3-TTS-12Hz-0.6B-CustomVoice-MLX-4bit"

    /// 与 swift-qwen3-tts demo 一致：让模型自行检测语言。
    private static let language = "auto"

    /// Reader 是短句朗读，要的是稳定而不是多样：上游默认
    /// temperature 0.9 / topK 50 / topP 1.0 更容易漂到「越读越虚」。
    private static let temperature: Float = 0.7
    private static let topK = 40
    private static let topP: Float = 0.9
    private static let repetitionPenalty: Float = 1.05

    /// 帧数上限（codec 12.5Hz）：按文本长度给预算，长句留够余量即可。
    /// 固定 2048 只会让漂移样本在「已经说完」之后继续白烧 GPU。
    private static func maxTokens(for text: String) -> Int {
        switch text.count {
        case ..<31: return 512
        case ..<101: return 768
        case ..<201: return 1024
        default: return 1536
        }
    }

    // MARK: - Model Directory Resolution

    /// fromPretrained 只读取目录（tokenizer.json 已随仓库提供），bundle 只读
    /// 也能直接加载；组件不齐时提前 fail-loud，绝不带着残缺权重进「已加载」。
    private static func resolveModelDirectory() throws -> URL {

        guard let root = Bundle.main.url(
            forResource: bundleResourceName,
            withExtension: nil
        ) else {
            throw LocalTTSError.synthesisFailed(
                "未在 app bundle 找到模型文件夹 \(bundleResourceName)。请确认 ~/Models 下已下载该仓库并以 folder reference 打入工程。"
            )
        }

        let missing = missingComponents(in: root)
        guard missing.isEmpty else {
            throw LocalTTSError.incompleteModel(missing: missing)
        }

        return root
    }

    /// 权重在不在 app bundle 里。**只查目录，不加载、不碰推理**：TTS 外层用它决定
    /// 这一格要不要试（缺权重是结构性不可用，不该拿四次失败去撞）。
    nonisolated static func modelAvailable() -> Bool {
        Bundle.main.url(forResource: bundleResourceName, withExtension: nil) != nil
    }

    private static func missingComponents(in url: URL) -> [String] {

        let fm = FileManager.default
        var missing: [String] = []

        func exists(_ path: String) -> Bool {
            fm.fileExists(atPath: url.appendingPathComponent(path).path)
        }

        func hasSafetensors(_ dir: String) -> Bool {
            let entries = (try? fm.contentsOfDirectory(
                at: url.appendingPathComponent(dir, isDirectory: true),
                includingPropertiesForKeys: nil
            )) ?? []
            return entries.contains { $0.pathExtension == "safetensors" }
        }

        if !exists("config.json") { missing.append("config.json") }
        if !hasSafetensors(".") { missing.append("talker 权重 *.safetensors") }
        if !exists("tokenizer.json") { missing.append("tokenizer.json") }
        if !exists("speech_tokenizer/config.json") { missing.append("speech_tokenizer/config.json") }
        if !hasSafetensors("speech_tokenizer") { missing.append("speech_tokenizer/ 内的 *.safetensors（声码 decoder）") }

        return missing
    }

    // MARK: - Load

    private func load() async throws {
        guard !isLoaded else { return }

        print("开始加载 Qwen3-TTS 12Hz 本地语音模型 (swift-qwen3-tts, CustomVoice 4bit)...")

        let dir = try Self.resolveModelDirectory()
        print("[TTS] ① 校验模型组件… 通过 (talker + speech_tokenizer decoder)")

        MemoryProbe.log("TTS 加载 前")

        let loaded = try await Qwen3TTSModel.fromPretrained(dir.path)

        model = loaded
        isLoaded = true

        MemoryProbe.log("TTS 加载 后")
        Self.logRuntimeProfile(loaded)
        print("TTS Ready：\(loaded.ttsModelType)，采样率 \(loaded.sampleRate)Hz，说话人 \(loaded.supportedSpeakers.joined(separator: "/"))（本地离线）")

        await warmUp()
        
    }

    /// 一次性运行时画像（P0-1 诊断）：确认真的走 Metal GPU、内存/缓存上限是多少、
    /// 权重是否确实为 4bit（uint8 + fp16 scale）而不是退化成 float32。
    private static func logRuntimeProfile(_ model: Qwen3TTSModel) {

        let device = Device.defaultDevice()
        let deviceType = device.deviceType.map { "\($0)" } ?? "nil"
        print(
            "[Perf] device=\(deviceType) | 内存上限=\(Memory.memoryLimit / 1_048_576)MB "
                + "缓存上限=\(Memory.cacheLimit / 1_048_576)MB 当前缓存=\(Memory.snapshot().cacheMemory / 1_048_576)MB"
        )

        var byDtype: [String: (tensors: Int, elements: Int)] = [:]
        for (_, array) in model.parameters().flattened() {
            let key = "\(array.dtype)"
            var entry = byDtype[key] ?? (0, 0)
            entry.tensors += 1
            entry.elements += array.size
            byDtype[key] = entry
        }
        let summary = byDtype
            .sorted { $0.value.elements > $1.value.elements }
            .map { "\($0.key)×\($0.value.tensors)张量/\($0.value.elements)元素" }
            .joined(separator: " ")
        print("[Perf] 权重 dtype 分布：\(summary)")
    }

    /// 首次 generate 附带 Metal kernel 编译 / 计算图构建等一次性开销。
    /// 用一句极短文本走与正式合成相同的路径，把这部分吸收在加载阶段。
    private func warmUp() async {
        guard let model else { return }

        let start = CFAbsoluteTimeGetCurrent()

        do {
            _ = try await model.generate(
                text: "好。",
                speaker: VoiceManager.narratorVoice(),
                instruct: nil,
                language: Self.language,
                temperature: Self.temperature,
                topK: Self.topK,
                topP: Self.topP,
                repetitionPenalty: Self.repetitionPenalty,
                maxTokens: 75
            )
        } catch {
            print("[TTS] 预热未完成：\(error)")
        }

        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
        print("[TTS] 预热完成：\(String(format: "%.0f", ms))ms（一次性 kernel/构图开销已吸收）")
    }

    func unload() async {
        model = nil
        isLoaded = false
        print("Qwen3-TTS 已卸载，内存已释放")
    }

    // MARK: - Synthesize

    func synthesize(
        text: String,
        voiceID: String,
        emotion: Emotion,
        intensity: Double,
        speed: Double,
        pitch: Double,
        voiceStrength: Double
    ) async throws -> Data {

        // 提交之前先问后台：这条链路是 MLX，在后台跑 GPU 会让驱动抛出 Swift 抓不住的
        // C++ `std::runtime_error`（进程 terminate）。见 `AppBackgroundGate`。
        try AppBackgroundGate.ensureForeground()

        if !isLoaded {
            try await load()
        }

        guard let model else {
            throw LocalTTSError.modelNotLoaded
        }

        var style = VoiceManager.stylePrompt(
            emotion: emotion,
            intensity: intensity,
            speed: speed,
            pitch: pitch,
            voiceStrength: voiceStrength
        )

        if VoiceManager.isUnnamedVoice(voiceID) {
            style += "；\(VoiceManager.clarityRule)"
        }

        let frameBudget = Self.maxTokens(for: text)
        print("[TTS] instruct(\(style.count)字) 帧预算=\(frameBudget)：\(style.prefix(40))")

        let sampleRate = Double(model.sampleRate)

        // 有效字数用于时长合理性判断（中文正常语速约 4 字/秒）
        let contentCount = text.filter { $0.isLetter || $0.isNumber }.count
        let expectedDuration = contentCount > 0
            ? Double(contentCount) / 4.0
            : 0.5

        var accepted: [Float]?

        // 高 temperature 下 talker 偶发漂移：立即 EOS（静音）、语速崩坏、
        // 拖尾或输出与文本无关的语音。校验时长，异常则降温重试一次。
        let synthStart = CFAbsoluteTimeGetCurrent()
        for attempt in 1 ... 2 {
            let attemptStart = CFAbsoluteTimeGetCurrent()

            let audio = try await model.generate(
                text: text,
                speaker: voiceID,
                instruct: style.isEmpty ? nil : style,
                language: Self.language,
                temperature: attempt == 2 ? 0.6 : Self.temperature,
                topK: Self.topK,
                topP: Self.topP,
                repetitionPenalty: Self.repetitionPenalty,
                maxTokens: frameBudget
            )

            eval(audio)
            let rawSamples = audio.asType(.float32).asArray(Float.self)
            let genMs = (CFAbsoluteTimeGetCurrent() - attemptStart) * 1000

            let trimmed = Self.trimSilence(rawSamples, sampleRate: sampleRate)
            let duration = Double(trimmed.count) / sampleRate

            // codec 帧数按 12.5Hz 从裁后音频反推
            let frames = Int((duration * 12.5).rounded())

            print("[TTS⏱] 「\(text.prefix(8))」 总 \(String(format: "%.0f", genMs))ms | 音频 \(String(format: "%.2f", duration))s(~\(frames)帧) | RTF \(String(format: "%.2f", genMs / 1000 / max(0.01, duration)))")

            let tooShort = contentCount > 0 && duration < expectedDuration * 0.45
            let tooLong = contentCount > 0 && duration > expectedDuration * 2.2
            let silent = trimmed.count < Int(sampleRate * 0.1)

            if silent || tooShort || tooLong {
                print("[TTS] ⚠️ 时长异常(第\(attempt)次): \(String(format: "%.2f", duration))s / 预期 \(String(format: "%.2f", expectedDuration))s — \(text.prefix(12))")
                continue
            }

            accepted = trimmed
            break
        }

        // 两次都不合格就抛错，绝不落盘「更接近预期的那个」：produce 之后按
        // sentenceID 命中磁盘缓存，一次残句会被永久复用，用户听到的就是
        // 「播几个字就结束」，而且再也等不到重录。失败交给调度器重试。
        guard let samples = accepted else {
            throw LocalTTSError.synthesisFailed(
                "两次合成均不合格（预期 \(String(format: "%.2f", expectedDuration))s）：\(text.prefix(12))"
            )
        }

        let wavStart = CFAbsoluteTimeGetCurrent()
        let data = Self.audioToWAV(samples, sampleRate: sampleRate)
        let wavMs = (CFAbsoluteTimeGetCurrent() - wavStart) * 1000

        let totalMs = (CFAbsoluteTimeGetCurrent() - synthStart) * 1000
        print("[TTS⏱] 单句总计 \(String(format: "%.0f", totalMs))ms（WAV 编码 \(String(format: "%.0f", wavMs))ms）\(text.prefix(8))")

        MemoryProbe.log("单句合成完成 (\(text.prefix(8)))")

        print("语音生成完成 \(text.prefix(20))... 大小: \(data.count) bytes")

        return data
    }

    // MARK: - Audio Sanity Helpers

    /// 裁掉过长的首尾静音，保留自然呼吸感。
    /// 漂移样本常见 1s+ 的尾部静音，直接听感就是“拖着”。
    private static func trimSilence(
        _ samples: [Float],
        sampleRate: Double,
        threshold: Float = 0.02,
        keepLeading: Double = 0.05,
        keepTrailing: Double = 0.4
    ) -> [Float] {
        guard !samples.isEmpty else { return samples }

        func findLoud(from start: Int, to end: Int, scanningUp: Bool) -> Int? {
            var i = start
            while i != end {
                if abs(samples[i]) >= threshold { return i }
                i += scanningUp ? 1 : -1
            }
            return nil
        }

        guard let firstLoud = findLoud(from: 0, to: samples.count, scanningUp: true),
              let lastLoud = findLoud(from: samples.count - 1, to: -1, scanningUp: false)
        else {
            // 全静音
            return []
        }

        let lead = Int(keepLeading * sampleRate)
        let trail = Int(keepTrailing * sampleRate)
        let start = max(0, firstLoud - lead)
        let end = min(samples.count, lastLoud + 1 + trail)
        guard start > 0 || end < samples.count else { return samples }
        return Array(samples[start ..< end])
    }

    // MARK: - WAV Encoder

    private nonisolated static func audioToWAV(_ samples: [Float], sampleRate: Double) -> Data {
        // 逐样本 append 会有数万次 2 字节小分配 + Data 反复扩容；
        // 这里一次性转 Int16 并整块拷贝（Apple 平台内存即小端）。
        var pcm = [Int16](repeating: 0, count: samples.count)
        for i in samples.indices {
            pcm[i] = Int16(max(-1.0, min(1.0, samples[i])) * 32767.0)
        }

        var data = Data(capacity: 44 + pcm.count * 2)

        let numChannels = 1
        let bitsPerSample: UInt32 = 16
        let byteRate = UInt32(sampleRate) * UInt32(numChannels) * bitsPerSample / 8
        let blockAlign = UInt16(numChannels) * UInt16(bitsPerSample / 8)
        let dataSize = UInt32(samples.count) * UInt32(bitsPerSample / 8)

        data.append(contentsOf: Array("RIFF".utf8))
        data.append(contentsOf: withUnsafeBytes(of: UInt32(36 + dataSize).littleEndian) { Array($0) })
        data.append(contentsOf: Array("WAVE".utf8))

        data.append(contentsOf: Array("fmt ".utf8))
        data.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(numChannels).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(bitsPerSample).littleEndian) { Array($0) })

        data.append(contentsOf: Array("data".utf8))
        data.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })

        pcm.withUnsafeBytes { raw in
            data.append(contentsOf: raw.bindMemory(to: UInt8.self))
        }

        return data
    }
}

// MARK: - Errors

enum LocalTTSError: Error, LocalizedError {
    case modelNotLoaded
    case incompleteModel(missing: [String])
    case synthesisFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "TTS 模型未加载"
        case .incompleteModel(let missing):
            return """
            Qwen3-TTS 模型不完整，无法离线合成语音。缺失：\(missing.joined(separator: "、"))。
            请在 ~/Models/Qwen3TTSCache/Qwen3-TTS-12Hz-0.6B-CustomVoice-MLX-4bit/ 下放入完整模型仓库（含 speech_tokenizer/model.safetensors），重新构建。
            """
        case .synthesisFailed(let reason):
            return "语音合成失败: \(reason)"
        }
    }
}
