//
//  FallbackTTSService.swift
//  Reader
//
//  TTS 降级链：优先用主后端，它抛错时改用备用后端。当前是 Edge 为主、Kokoro 兜底
//  （``TTSEngineType`` 选 `.sherpaKokoro` 时两者反向）。
//
//  为什么需要：任何一边单独坏掉都不该让整章静音。Edge 是网络后端，可能没网、可能被
//  服务端拒；Kokoro 的权重在 App 之外，可能没被 folder reference 拷进来、可能在内存
//  紧张时创建引擎失败、也可能某一句本地推理出问题。
//
//  两个后端各自认识自己的声音：传给它们的 `voiceID` 都是 ``VoiceManager`` 那套
//  Qwen3 说话人名，映射分别在 ``EdgeTTSService/resolveVoice(_:)`` 与
//  ``KokoroVoiceMap`` 里做，这一层不做翻译——所以换主备顺序不需要改这里。
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
    /// 一章几百句，每句都先失败一次等于把整章合成时间翻倍；而「连续几句都失败」
    /// 已经说明问题是结构性的（权重缺失 / 模型不匹配 / 引擎起不来 / 网络不通），
    /// 不会自己好。
    ///
    /// 4 而不是更早的 8：主后端现在是 Edge，一次失败最坏要等
    /// `超时 × 句内重试` 秒，8 句就是几分钟的静音才轮到本地出声。
    static let primaryFailureThreshold = 4

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
                voiceID: voiceID,
                emotion: emotion,
                intensity: intensity,
                speed: speed,
                pitch: pitch,
                voiceStrength: voiceStrength
            )
            if !didLogSwitch {
                didLogSwitch = true
                print("[TTS降级] 已切到备用后端继续朗读。"
                    + "注意：备用后端的音色与本角色的主后端声音不会一致。")
            }
            return data
        } catch let backupError {
            // 两边都失败时抛主后端的错：才是「本该出声却没出声」的那个原因。
            throw primaryError ?? backupError
        }
    }

    // MARK: - Unload

    /// 供 `TTSGenerator.unloadModel()` 穿透包装层。
    ///
    /// 两个槽都要试：主备顺序换过之后本地后端可能在任意一边，只查 primary
    /// 就等于「卸了个寂寞」，权重继续白占着内存。备用后端是无状态的（Edge），转型自然失败。
    func unloadAll() async {
        for service in [primary, backup] {
            if let kokoro = service as? SherpaKokoroTTSService {
                await kokoro.unload()
            }
            if let qwen3 = service as? Qwen3TTSService {
                await qwen3.unload()
            }
        }
        primaryFailures = 0
        primarySkipped = false
        lastPrimaryError = nil
    }
}
