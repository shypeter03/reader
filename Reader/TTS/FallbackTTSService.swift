//
//  FallbackTTSService.swift
//  Reader
//
//  TTS 降级链：优先用主后端（Kokoro），它抛错时改用备用后端（Edge TTS）。
//
//  为什么需要：Kokoro 的权重是 App 之外的资源，可能没被 folder reference 拷进来、
//  可能在内存紧张时创建引擎失败、也可能某一句本地推理出问题。任何一种都会让
//  「这一章一句都读不出来」。Edge TTS 走网络，音质一般，但几乎总能把话说完。
//
//  这一层不调用任何 Qwen3-TTS 逻辑；Qwen3-TTS 走的是另一条完整后端
//  （``TTSEngineType/qwen3``），不参与降级。
//

import Foundation

actor FallbackTTSService: TTSService {

    private let primary: any TTSService
    private let backup: any TTSService

    /// 主后端连续失败多少次后，本进程不再试它。
    ///
    /// 一章几百句，每句都先失败一次等于把整章合成时间翻倍；而「连续 8 句都失败」
    /// 已经说明问题是结构性的（权重缺失 / 模型不匹配 / 引擎起不来），不会自己好。
    static let primaryFailureThreshold = 8

    private var primaryFailures = 0
    private var primarySkipped = false
    private var lastPrimaryError: Error?
    private var didLogSwitch = false

    init(
        primary: any TTSService,
        backup: any TTSService
    ) {
        self.primary = primary
        self.backup = backup
    }

    /// 备用后端用的是 Edge，所以这里必须把 Qwen3 的 speaker 名换成 Edge 的 voice 名。
    /// Edge 收到 `<voice name="Ryan">` 这种不认识的名字会让整次请求失败，
    /// 降级就等于没降成——所以这里必须**穷尽**，绝不把未知名字直接透传给 Edge。
    private static let edgeVoices: [String: String] = [
        "Uncle_Fu": EdgeTTSService.Voice.yunyang,   // 旁白/年长男
        "Ryan": EdgeTTSService.Voice.yunxi,
        "Aiden": EdgeTTSService.Voice.yunxi,
        "Dylan": EdgeTTSService.Voice.yunxi,
        "Eric": EdgeTTSService.Voice.yunjian,
        "Vivian": EdgeTTSService.Voice.xiaoxiao,
        "Serena": EdgeTTSService.Voice.xiaoyi,
    ]

    static func backupVoice(for voiceID: String) -> String {
        let trimmed = voiceID.trimmingCharacters(in: .whitespacesAndNewlines)

        if let mapped = edgeVoices[trimmed] { return mapped }
        if EdgeTTSService.Voice.all.contains(where: { $0.id == trimmed }) { return trimmed }
        if trimmed == "narrator" || trimmed.isEmpty { return EdgeTTSService.Voice.yunyang }

        // 角色表里可能有历史遗留的自定义 voiceID：按字节确定性散列挑一把，
        // 同一角色每次都落到同一个声音，不会出现同一角色两句换一个嗓。
        let pool = EdgeTTSService.Voice.all.map(\.id)
        var acc = 0
        for byte in trimmed.utf8 {
            acc = (acc &* 31 &+ Int(byte)) % 1_000_003
        }
        return pool[acc % pool.count]
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

        var primaryError: Error?

        if primarySkipped {
            primaryError = lastPrimaryError
        } else {
            do {
                let data = try await primary.synthesize(
                    text: text,
                    voiceID: voiceID,
                    emotion: emotion,
                    intensity: intensity,
                    speed: speed,
                    pitch: pitch,
                    voiceStrength: voiceStrength
                )
                primaryFailures = 0
                lastPrimaryError = nil
                return data
            } catch {
                primaryFailures += 1
                primaryError = error
                lastPrimaryError = error
                if primaryFailures >= Self.primaryFailureThreshold {
                    primarySkipped = true
                    print("⚠️ [TTS降级] 主后端连续失败 \(primaryFailures) 次，"
                        + "本次运行不再使用它（重启 App 会重新尝试）")
                } else {
                    print("⚠️ [TTS降级 \(primaryFailures)/\(Self.primaryFailureThreshold)] "
                        + "主后端失败：\(error)")
                }
            }
        }

        do {
            let data = try await backup.synthesize(
                text: text,
                voiceID: Self.backupVoice(for: voiceID),
                emotion: emotion,
                intensity: intensity,
                speed: speed,
                pitch: pitch,
                voiceStrength: voiceStrength
            )
            if !didLogSwitch {
                didLogSwitch = true
                print("[TTS降级] 已切到备用后端（Edge TTS）继续朗读。"
                    + "注意：备用后端的音色与本角色的 Kokoro 声音不会一致。")
            }
            return data
        } catch let backupError {
            // 两边都失败时抛主后端的错：才是「本该出声却没出声」的那个原因。
            throw primaryError ?? backupError
        }
    }

    // MARK: - Unload

    /// 供 `TTSGenerator.unloadModel()` 穿透包装层。备用后端是无状态的，不用管。
    func unloadAll() async {
        if let kokoro = primary as? SherpaKokoroTTSService {
            await kokoro.unload()
        }
        if let qwen3 = primary as? Qwen3TTSService {
            await qwen3.unload()
        }
        primaryFailures = 0
        primarySkipped = false
        lastPrimaryError = nil
    }
}
