//
//  FallbackTTSService.swift
//  Reader
//
//  TTS 的**外层**：三个后端 + 一条顺位 + 热加载热卸载。合成方（``TTSGenerator``）只问这里，
//  不认具体哪个后端。
//
//  顺位：默认 `edge → kokoro → qwen`，设置里选中的那个挪到最前、其余保持相对次序
//  （选 Kokoro 就是 `kokoro → edge → qwen`，选 Qwen3 就是 `qwen → edge → kokoro`）。
//  前一个抛错就轮到后一个：任何一边单独坏掉都不该让整章静音——Edge 可能没网、可能被服务端
//  拒；Kokoro 的权重可能没被 folder reference 拷进来、可能某一句本地推理出问题；
//  Qwen3 是 MLX，权重装不下时创建模型会抛。
//
//  为什么每一句都重读一次设置：设置页写的就是 UserDefaults，读它比合成一句便宜三个数量级，
//  而换后端因此**不需要重启 App**，也不需要 UI 往这条链里塞通知。
//
//  热加载：后端第一次用到才建，建的时候也不载权重（权重在各后端自己的 `synthesize` 里
//  第一次加载，之后引擎常驻）。热卸载：换后端时把旧那几份交还（新主位在下一句自己载），
//  内存门禁调 ``unloadAll()`` 时全部交还。
//
//  两个本地后端各自认识自己的声音：传给它们的 `voiceID` 都是 ``VoiceManager`` 那套
//  Qwen3 说话人名，映射分别在 ``EdgeTTSService/resolveVoice(_:)`` 与 ``KokoroVoiceMap`` 里做，
//  这一层不做翻译——所以换顺位不需要改那里。
//
//  这一层自己不含任何 Qwen3-TTS 逻辑：Qwen3 只是它管的三个槽之一，权重与推理都在
//  ``Qwen3TTSService`` 里，一行没动。
//

import Foundation

/// 一句的产物：字节，和**真出声的那个后端**。
///
/// 后端要一起返回：磁盘缓存的子目录是按后端分的（见 ``TTSEngineType/audioNamespace``），
/// 由哪个后端出的声就得落回哪个目录，否则 Edge 兜底时合成的 Kokoro 音频会存进 `edge-v1`，
/// 下次切回 Kokoro 反而查不到、整本重录一遍。
struct TTSSynthesis: Sendable {

    let data: Data

    let backend: TTSEngineType
}

actor FallbackTTSService {

    /// 一个后端连续失败这么多次，本进程不再试它（换后端或内存门禁卸载时重新计数）。
    ///
    /// 一章几百句，每句都先失败一次等于把整章合成时间翻倍；而「连续几句都失败」已经说明
    /// 问题是结构性的（权重缺失 / 模型不匹配 / 引擎起不来 / 网络不通），不会自己好。
    ///
    /// 4 而不是更早：Edge 一次失败最坏要等 `超时 × 句内重试` 秒，4 句就是几十秒静音才换嗓。
    static let failureThreshold = 4

    /// 默认顺位。选中谁就把谁挪到最前。
    static let defaultOrder: [TTSEngineType] = [.edge, .sherpaKokoro, .qwen3]

    static func rotation(for selected: TTSEngineType) -> [TTSEngineType] {
        [selected] + defaultOrder.filter { $0 != selected }
    }

    private struct Slot {
        let engine: TTSEngineType

        /// 权重到没到位。没打进来是**结构性**不可用：一次都不该试，更不该拿失败去计数。
        /// 只在排链时查一次（file manager），不每句查。
        let present: Bool

        /// 建一次就留着：引擎/权重只该在第一次用时载一遍。nil = 还没用过。
        var service: (any TTSService)?

        var failures = 0
        var skipped = false
    }

    private var slots: [Slot]

    /// 已经折算进 `slots` 的那个选择。每句和它比一次，不一样就是用户刚换了后端。
    private var appliedSelection: TTSEngineType

    /// 「已经降到后面那一槽」这句话本进程只说一次。
    private var didLogFallback = false

    init() {
        let selected = TTSEngineType.current
        appliedSelection = selected
        slots = Self.slots(for: selected)
        Self.logChain(selected, changed: false)
    }

    // MARK: - 排链

    private static func slots(for selected: TTSEngineType) -> [Slot] {
        rotation(for: selected).map { Slot(engine: $0, present: weightsPresent($0)) }
    }

    private static func weightsPresent(_ engine: TTSEngineType) -> Bool {
        switch engine {
        case .edge: return true
        case .sherpaKokoro: return SherpaKokoroTTSService.modelDirectoryIfAvailable() != nil
        case .qwen3: return Qwen3TTSService.modelAvailable()
        }
    }

    /// 这一槽此刻能不能出声。缺权重和「在后台不能碰 GPU」都不是后端的错，跳过即可，
    /// 一次都不记失败（记满会把它在整条链里永久踢掉）。
    private func canTake(_ slot: Slot) -> Bool {
        guard slot.present else { return false }
        // Qwen3 是 MLX：在后台提交 Metal 会让进程被 C++ 异常直接 terminate，不是偏好。
        guard !slot.engine.submitsToGPU || !AppBackgroundGate.shared.isBackground else { return false }
        return true
    }

    /// 顺位链上还有没有「在后台也能出声」的一格。
    ///
    /// 后台门禁问的是这个，而不是「用户现在选的是哪个后端」：选了 Qwen3（MLX，后台提交 GPU
    /// 会崩）并不等于熄屏后就没法继续听——外层本来就会跳过不能出声的那一格，用 Edge 或
    /// Kokoro 顶上（见 ``canTake(_:)``）。把整条队列挂起等于把自己的退路一起关掉，
    /// 表现就是「一熄屏朗读过几句就停住，解锁也不回来」。
    func hasBackgroundCapableSlot() async -> Bool {
        await applySelectionIfChanged()
        return slots.contains { !$0.skipped && canTake($0) }
    }

    // MARK: - 缓存目录

    /// 读缓存要轮询的后端子目录，按当前顺位排（选中那个先查，所以两边都存过时用的是现在这个）。
    ///
    /// 为什么要全部轮一遍：换后端不该把整本书重新合成一遍——那些音频本来就躺在别的子目录里，
    /// 而且 Edge 兜底时补的那几句本来就出自 Kokoro，按顺位查才认得出。
    func cacheNamespaces() async -> [String?] {
        await applySelectionIfChanged()
        return slots.map { $0.engine.audioNamespace }
    }

    // MARK: - 合成

    func synthesize(
        text: String,
        voiceID: String,
        emotion: Emotion,
        intensity: Double,
        speed: Double,
        pitch: Double,
        voiceStrength: Double
    ) async throws -> TTSSynthesis {

        await applySelectionIfChanged()

        var lastError: Error?

        for index in slots.indices {

            guard !slots[index].skipped, canTake(slots[index]) else { continue }

            if slots[index].service == nil {
                slots[index].service = Self.make(slots[index].engine)
            }
            guard let service = slots[index].service else { continue }

            do {
                let data = try await service.synthesize(
                    text: text,
                    voiceID: voiceID,
                    emotion: emotion,
                    intensity: intensity,
                    speed: speed,
                    pitch: pitch,
                    voiceStrength: voiceStrength
                )

                if index > 0, !didLogFallback {
                    didLogFallback = true
                    // 只说一次：后面每句都换嗓是同一件事，重复打只会盖掉别的日志。
                    // 换出来的声音和本角色在主后端那把不会一致，这是降级本来就有的代价。
                    print("[TTS降级] 已改用顺位 \(index + 1) 的 \(slots[index].engine.rawValue) 继续朗读，"
                        + "同一角色在后端之间音色会有差别")
                }
                slots[index].failures = 0

                return TTSSynthesis(data: data, backend: slots[index].engine)

            } catch {
                slots[index].failures += 1
                lastError = error

                if slots[index].failures >= Self.failureThreshold {
                    slots[index].skipped = true
                    // 坏掉的那个把权重交还：它接下来不会再出声，内存该让给还在跑的槽。
                    await Self.release(service)
                    slots[index].service = nil
                    print("⚠️ [TTS降级] \(slots[index].engine.rawValue) 连续失败 \(slots[index].failures) 次，"
                        + "本次运行不再试它（换后端或重启会重新尝试），权重已卸载")
                } else {
                    print("⚠️ [TTS降级 \(slots[index].failures)/\(Self.failureThreshold)] "
                        + "\(slots[index].engine.rawValue) 失败：\(error)")
                }
            }
        }

        throw lastError ?? TTSSynthesisError.noBackendAvailable(
            order: slots.map(\.engine).map(\.rawValue)
        )
    }

    // MARK: - 卸载

    /// 供 `TTSGenerator.unloadModel()`（内存门禁、进后台）穿透外层：三个槽谁载过就卸谁。
    ///
    /// Edge 是无状态的，转型不进去，自然什么都不做。失败计数一并归零：这一次卸载之后
    /// 后端可能已经换了（比如网络回来了），不该被上一轮的判定永久挡在门外。
    func unloadAll() async {
        for slot in slots {
            if let service = slot.service { await Self.release(service) }
        }
        for index in slots.indices {
            slots[index].service = nil
            slots[index].failures = 0
            slots[index].skipped = false
        }
        didLogFallback = false
    }

    // MARK: - 内部

    /// 后端实例：建它不载权重（``SherpaKokoroTTSService`` / ``Qwen3TTSService`` 都是
    /// 第一次 `synthesize` 才 load），所以三个槽可以全建着，谁也没用过就是零占用。
    private static func make(_ engine: TTSEngineType) -> any TTSService {
        switch engine {
        case .edge: return EdgeTTSService()
        case .sherpaKokoro: return SherpaKokoroTTSService()
        case .qwen3: return Qwen3TTSService()
        }
    }

    private static func release(_ service: any TTSService) async {
        if let kokoro = service as? SherpaKokoroTTSService {
            await kokoro.unload()
        }
        if let qwen3 = service as? Qwen3TTSService {
            await qwen3.unload()
        }
    }

    /// 用户换了后端：重排顺位、把旧的那几份权重交还、失败计数归零、立即生效。
    ///
    /// 先换 `slots` 再逐个卸载：中间那个 `await` 让出线程时，新的句子已经按新顺位在跑了，
    /// 而它用的实例是刚建的那个，不会被这场卸载误伤。
    private func applySelectionIfChanged() async {
        let selected = TTSEngineType.current
        guard selected != appliedSelection else { return }
        appliedSelection = selected

        let stale = slots.compactMap(\.service)
        slots = Self.slots(for: selected)
        didLogFallback = false
        for service in stale {
            await Self.release(service)
        }
        Self.logChain(selected, changed: true)
    }

    private static func logChain(_ selected: TTSEngineType, changed: Bool) {
        let order = rotation(for: selected).map(\.rawValue).joined(separator: " → ")
        print("[TTS] 后端=\(selected.rawValue) 缓存子目录=\(selected.audioNamespace ?? "(平铺)") 顺位=\(order)"
            + (changed ? " ← 设置已改，立即生效，不用重启" : ""))
        // 缺权重要说出来：否则「为什么这一句没有退路」只能去猜是规则没生效还是包没打进东西。
        for engine in defaultOrder where !weightsPresent(engine) {
            print("[TTS] \(engine.rawValue) 权重未就位，这一条链上它那一格是空的"
                + "（本地后端的权重靠 folder reference 在 build 时拷进 App；放哪里怎么找，设置页那一行写着）")
        }
    }
}

enum TTSSynthesisError: Error, LocalizedError {

    case noBackendAvailable(order: [String])

    var errorDescription: String? {
        switch self {
        case .noBackendAvailable(let order):
            return "语音后端全部失败（顺位 \(order.joined(separator: " → "))），这一句留空跳过"
        }
    }
}
