//
//  GenerationTypes.swift
//  AtomGradient
//
//  Copyright (c) AtomGradient. All rights reserved.
//
//

import Foundation

// MARK: - Generation Info

/// Information about the audio generation process.
public struct AudioGenerationInfo: Sendable {
    public let promptTokenCount: Int
    public let generationTokenCount: Int
    public let prefillTime: TimeInterval
    public let generateTime: TimeInterval
    public let tokensPerSecond: Double
    public let peakMemoryUsage: Double

    public init(
        promptTokenCount: Int,
        generationTokenCount: Int,
        prefillTime: TimeInterval,
        generateTime: TimeInterval,
        tokensPerSecond: Double,
        peakMemoryUsage: Double
    ) {
        self.promptTokenCount = promptTokenCount
        self.generationTokenCount = generationTokenCount
        self.prefillTime = prefillTime
        self.generateTime = generateTime
        self.tokensPerSecond = tokensPerSecond
        self.peakMemoryUsage = peakMemoryUsage
    }

    public var summary: String {
        """
        Prompt:     \(promptTokenCount) tokens, \(String(format: "%.2f", Double(promptTokenCount) / max(prefillTime, 0.001))) tokens/s, \(String(format: "%.3f", prefillTime))s
        Generation: \(generationTokenCount) tokens, \(String(format: "%.2f", tokensPerSecond)) tokens/s, \(String(format: "%.3f", generateTime))s
        Peak Memory Usage: \(peakMemoryUsage) GB
        """
    }
}

// MARK: - Generation Events

/// Events emitted during audio generation.
public enum AudioGeneration: Sendable {
    /// A generated token ID
    case token(Int)
    /// Generation statistics
    case info(AudioGenerationInfo)
    /// Final generated audio: Float32 PCM samples, flattened row-major.
    /// 值类型而非 MLXArray：事件要跨任务边界投递，MLXArray 不是 Sendable。
    case audio([Float])
}

// MARK: - Decode Step Probe（临时插桩，P0-1）

/// 自回归单帧的分段耗时探针：talker 前向 / 采样同步 / code predictor 15 步。
/// 每帧只取 4 次墙钟，25 帧聚合一行日志。用完把 `enabled` 置 false 即完全静默。
struct DecodeStepProbe {

    static var enabled = true

    private var marker = CFAbsoluteTimeGetCurrent()
    private var talker = 0.0
    private var sample = 0.0
    private var codes = 0.0
    private var frames = 0
    private var slowestFrame = 0.0
    private var totalTalker = 0.0
    private var totalSample = 0.0
    private var totalCodes = 0.0
    private var windowTalker = 0.0
    private var windowSample = 0.0
    private var windowCodes = 0.0
    private var windowFrames = 0
    private var dtypeLogged = false

    private mutating func elapsed() -> Double {
        let now = CFAbsoluteTimeGetCurrent()
        let dt = (now - marker) * 1000
        marker = now
        return dt
    }

    /// 首帧打印一次实际计算 dtype：4bit 权重反量化后若落到 float32，这里就能看见。
    mutating func afterTalker(
        logitsDtype: @autoclosure () -> String = "?",
        hiddenDtype: @autoclosure () -> String = "?"
    ) {
        guard Self.enabled else { return }
        talker = elapsed()
        if !dtypeLogged {
            dtypeLogged = true
            print("[Perf] 计算 dtype：logits=\(logitsDtype()) hidden=\(hiddenDtype())")
        }
    }

    mutating func afterSample() {
        guard Self.enabled else { return }
        sample = elapsed()
    }

    mutating func afterCodes(frameCount: Int) {
        guard Self.enabled else { return }
        codes = elapsed()
        frames += 1
        windowFrames += 1
        totalTalker += talker
        totalSample += sample
        totalCodes += codes
        windowTalker += talker
        windowSample += sample
        windowCodes += codes
        let total = talker + sample + codes
        slowestFrame = max(slowestFrame, total)

        if frames % 25 == 0 {
            print("[Perf] \(windowLine(frames: frames, frameCount: frameCount))")
            windowTalker = 0; windowSample = 0; windowCodes = 0; windowFrames = 0
        }
    }

    mutating func finish(frameCount: Int) {
        guard Self.enabled, frames > 0 else { return }
        let mean = (totalTalker + totalSample + totalCodes) / Double(frames)
        print(
            "[Perf] 解码收尾 \(frames) 帧/ \(frameCount) token：单帧均值 \(ms(mean))（talker \(ms(totalTalker / Double(frames))) + sample \(ms(totalSample / Double(frames))) + codes15 \(ms(totalCodes / Double(frames)))），最慢单帧 \(ms(slowestFrame)) = 均值的 \(String(format: "%.2f", slowestFrame / max(mean, 0.001)))x"
        )
    }

    private func windowLine(frames: Int, frameCount: Int) -> String {
        let n = Double(max(windowFrames, 1))
        return
            "frame#\(frames) 近\(windowFrames)帧均值：talker=\(ms(windowTalker / n)) sample=\(ms(windowSample / n)) codes15=\(ms(windowCodes / n)) 单帧合计=\(ms((windowTalker + windowSample + windowCodes) / n)) 已产token=\(frameCount)"
    }

    private func ms(_ value: Double) -> String {
        String(format: "%.1fms", value)
    }
}

// MARK: - Generation Errors

/// Errors that can occur during audio generation.
public enum AudioGenerationError: Error, LocalizedError {
    case modelNotInitialized(String)
    case generationFailed(String)
    case invalidInput(String)
    case audioDecodingFailed(String)
    case audioEncodingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .modelNotInitialized(let message):
            return "Model not initialized: \(message)"
        case .generationFailed(let message):
            return "Generation failed: \(message)"
        case .invalidInput(let message):
            return "Invalid input: \(message)"
        case .audioDecodingFailed(let message):
            return "Audio decoding failed: \(message)"
        case .audioEncodingFailed(let message):
            return "Audio encoding failed: \(message)"
        }
    }
}

// MARK: - Token Configuration Protocol

/// Protocol for model-specific token configuration.
public protocol AudioTokenConfiguration {
    /// Token ID for start of speech
    var startOfSpeech: Int { get }
    /// Token ID for end of speech
    var endOfSpeech: Int { get }
    /// Token ID for end of text
    var endOfText: Int { get }
    /// Offset added to audio token indices
    var audioTokensStart: Int { get }
    /// Pad token ID
    var padTokenId: Int { get }
}

// MARK: - Generation Parameters

/// Parameters for controlling audio generation.
public struct AudioGenerateParameters: Sendable {
    public let maxTokens: Int
    public let temperature: Float
    public let topP: Float
    public let repetitionPenalty: Float
    public let repetitionContextSize: Int

    public init(
        maxTokens: Int = 1200,
        temperature: Float = 0.6,
        topP: Float = 0.8,
        repetitionPenalty: Float = 1.3,
        repetitionContextSize: Int = 20
    ) {
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topP = topP
        self.repetitionPenalty = repetitionPenalty
        self.repetitionContextSize = repetitionContextSize
    }
}
