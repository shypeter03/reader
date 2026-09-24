//
//  EdgeTTSService.swift
//  Reader
//
//  Edge TTS 的网络细节全部交给 `SwiftEdgeTTS`（herrkaefer/SwiftEdgeTTS 1.3.0）：
//  WebSocket 握手、`Sec-MS-GEC` DRM 令牌、speech.config、音频分片与 turn.end 的解析都在库里。
//  这个文件只留 Reader 自己的策略：选哪把声音、情绪怎么折成 prosody、句中拉丁片段怎么去掉，
//  以及把库里「合成到文件」的产物取回成 `Data`（`AudioStore` 要的是字节，不是路径）。
//
//  为什么换掉 brewusinc/Edge-TTS 1.0.0：它把 `Sec-MS-GEC-Version` 钉在 Chromium 130，
//  微软现在就拒这一档握手——本机实测 WS upgrade 返回 403、连接挂死不返回，
//  也就是「websocket 无法连接」的直接原因。新库跟 Python edge-tts 7.2.7 的口径
//  （Chromium 143 + 用服务端 Date 头校正时钟偏移再算令牌），本机实测 1~3s 出
//  24kHz/48kbps 的 MP3，四路并发各句互不串。
//

import Foundation
import SherpaKokoroKit
import SwiftEdgeTTS

actor EdgeTTSService: TTSService {

    // MARK: - Edge TTS Voices

    enum Voice {

        static let xiaoxiao = "zh-CN-XiaoxiaoNeural"
        static let yunxi = "zh-CN-YunxiNeural"
        static let yunyang = "zh-CN-YunyangNeural"
        static let xiaoyi = "zh-CN-XiaoyiNeural"
        static let yunjian = "zh-CN-YunjianNeural"

        static let all: [(id: String, gender: Gender)] = [
            (xiaoxiao, .female),
            (yunxi, .male),
            (yunyang, .male),
            (xiaoyi, .female),
            (yunjian, .male),
        ]
    }

    /// 磁盘缓存命名空间：Edge 的音频落在 `{书}/{章}/edge-v1/` 下，与 Kokoro（`kokoro-v3`）、
    /// Qwen3（平铺）互不命中。缓存键只有「书/章/句」，不含后端也不含声音，
    /// 所以换主后端必须换命名空间，否则旧音频会原样命中、换后端等于没换。
    nonisolated static let audioNamespace = "edge-v1"

    /// 单次合成的时限。
    ///
    /// Edge 在主后端位上时这个值直接决定「网络不通时要多久才让 Kokoro 接手」：
    /// 最坏情况 = 本值 × ``attempts`` × ``FallbackTTSService.primaryFailureThreshold``
    /// 秒的静音，所以压到 10s（正常一句的往返只有 1~3s）。
    private static let synthesisTimeout: TimeInterval = 10

    /// 整句的尝试次数。Edge 是首选后端，它失败这一句才轮到 Kokoro，
    /// 不必像兜底位那样死磕——多试一次就多等一个超时。
    private static let attempts = 2

    /// 本地那两套后端的说话人名 → Edge 的 voice 名。
    ///
    /// `voiceID` 一路传下来都是 ``VoiceManager`` 给 Qwen3 CustomVoice 起的名字
    /// （`Uncle_Fu` / `Ryan`…），Edge 收到不认识的名字会让整次请求失败——
    /// 那时它就在主后端位上，等于整本书一句都不出声。所以这里必须**穷尽**，
    /// 绝不把未知名字直接透传。
    private static let speakerAlias: [String: String] = [
        "Uncle_Fu": Voice.yunyang,   // 旁白/年长男
        "Ryan": Voice.yunxi,
        "Aiden": Voice.yunxi,
        "Dylan": Voice.yunxi,
        "Eric": Voice.yunjian,
        "Vivian": Voice.xiaoxiao,
        "Serena": Voice.xiaoyi,
    ]

    /// 时限靠它落地：库里没有任何超时参数，只能从注入的 URLSession 上夹。
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.default
        // 只有 resource 那一档掐得住 WebSocket：实测把它压到 1s，一句正常要 2.5s 的
        // 请求会在 1.2s 抛 `cancelled`；而 request timeout 压到 1s 完全无效（2.6s 照样成功）。
        configuration.timeoutIntervalForResource = Self.synthesisTimeout
        session = URLSession(configuration: configuration)
    }

    // MARK: - TTSService

    func synthesize(
        text: String,
        voiceID: String,
        emotion: Emotion,
        intensity: Double,
        speed: Double,
        pitch: Double,
        voiceStrength: Double
    ) async throws -> Data {

        // Edge 的 SSML 没有「声音饱满度」这一维，volume/prosody 越低越虚，
        // 用它只会复刻我们要治的那个毛病，所以这里只接住参数不使用。
        _ = voiceStrength

        let voice = resolveVoice(voiceID)

        let (adjustedSpeed, adjustedPitch) = emotionAdjustment(
            emotion: emotion,
            intensity: intensity,
            baseSpeed: speed,
            basePitch: pitch
        )

        // 两套后端读到同一句中文时不该冒出英文：降级链上两句的音色本来就不一致，
        // 再夹一个英文词读法就更跳。
        let spoken = KokoroSpeechText.speakable(text).0

        // 每次调用各开一条 WebSocket，库自己收尾（turn.end 后 cancel），重试不用清理。
        let client = SwiftEdgeTTS.EdgeTTSService(session: session)

        // 库里已经会转义 `& < > " '`，这里再转一次会变成 `&amp;amp;`，念出来就是英文字母。
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("reader-edge-\(UUID().uuidString).mp3")
        defer { try? FileManager.default.removeItem(at: audioURL) }

        var lastError: Error?

        for attempt in 1...Self.attempts {
            do {
                _ = try await client.synthesize(
                    text: spoken,
                    voice: voice,
                    outputURL: audioURL,
                    rate: Self.ssmlRate(adjustedSpeed),
                    volume: "+0%",
                    pitch: Self.ssmlPitch(adjustedPitch)
                )
                let audioData = try Data(contentsOf: audioURL)
                // 库里「一个分片都没收到」时是拿不到文件的，但服务端拒了 SSML 也可能
                // 留个空文件；0 字节存进缓存就是一条永远播不响的静音。
                guard !audioData.isEmpty else { throw EdgeTTSError.synthesisFailed }
                if attempt > 1 { print("EdgeTTS 第 \(attempt) 次尝试成功") }
                return audioData
            } catch {
                lastError = error
                print("EdgeTTS 合成失败（尝试 \(attempt)/\(Self.attempts)）：\(error)")
                if attempt < Self.attempts {
                    try? await Task.sleep(for: .milliseconds(500 * Int64(attempt)))
                }
            }
        }

        throw lastError ?? EdgeTTSError.synthesisFailed
    }

    // MARK: - Voice Resolution

    private func resolveVoice(_ voiceID: String) -> String {

        let trimmed = voiceID.trimmingCharacters(in: .whitespacesAndNewlines)

        if let alias = Self.speakerAlias[trimmed] { return alias }
        if Voice.all.contains(where: { $0.id == trimmed }) { return trimmed }
        if trimmed == "narrator" { return Voice.yunyang }
        if trimmed.isEmpty || trimmed == "default" { return Voice.xiaoxiao }

        // 角色表里可能有历史遗留的自定义 voiceID：按字节确定性散列挑一把，
        // 同一角色每次都落到同一个声音，不会出现同一角色两句换一个嗓。
        let pool = Voice.all.map(\.id)
        var acc = 0
        for byte in trimmed.utf8 {
            acc = (acc &* 31 &+ Int(byte)) % 1_000_003
        }
        return pool[acc % pool.count]
    }

    // MARK: - Prosody

    /// SSML 的 rate 是**相对增量**，不是绝对百分比——这一点写代码的人最容易想当然，
    /// 而说错不报错，只会整本书都念得飞快。实测同一句：
    /// `"+0%"` → 4.70s、`"100%"` → 2.38s（被念成 +100%）、`"+15%"` → 4.10s、`"-15%"` → 5.52s。
    /// 所以 speed 1.0 必须发 `"+0%"`，而不是以前那个 `"100%"`。
    private static func ssmlRate(_ speed: Double) -> String {
        String(format: "%+.0f%%", (speed - 1) * 100)
    }

    /// pitch 同理要带符号和单位：`"+0Hz"`/`"+20Hz"`/`"-20Hz"` 都被接受
    /// （`"+0"` 这种少了 `Hz` 的写法服务端会直接关掉连接）。
    /// 注意这里只验过「不报错」，音高有没有真的变化，用时长是量不出来的。
    private static func ssmlPitch(_ pitch: Double) -> String {
        String(format: "%+.0fHz", pitch * 100)
    }

    private func emotionAdjustment(
        emotion: Emotion,
        intensity: Double,
        baseSpeed: Double,
        basePitch: Double
    ) -> (speed: Double, pitch: Double) {

        let factor = max(0, min(1, intensity))

        let speedDelta: Double
        let pitchDelta: Double

        switch emotion {

        case .neutral:
            speedDelta = 0
            pitchDelta = 0

        case .happy, .excited:
            speedDelta = 0.1 * factor
            pitchDelta = 0.03 * factor

        case .sad:
            speedDelta = -0.1 * factor
            pitchDelta = -0.02 * factor

        case .angry:
            speedDelta = 0.15 * factor
            pitchDelta = 0.05 * factor

        case .surprised:
            speedDelta = 0.08 * factor
            pitchDelta = 0.06 * factor

        case .fearful, .tense:
            speedDelta = 0.1 * factor
            pitchDelta = 0.02 * factor

        case .calm:
            speedDelta = -0.08 * factor
            pitchDelta = -0.01 * factor
        }

        return (
            max(0.5, min(1.5, baseSpeed + speedDelta)),
            max(-0.2, min(0.2, basePitch + pitchDelta))
        )
    }
}
