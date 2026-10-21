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

    /// 与 swift-qwen3-tts demo 一致：让模型自行检测语言。
    private static let language = "auto"

    /// Reader 是短句朗读，要的是稳定而不是多样：上游默认
    /// temperature 0.9 / topK 50 / topP 1.0 更容易漂到「越读越虚」。
    private static let temperature: Float = 0.7
    private static let topK = 40
    private static let topP: Float = 0.9
    private static let repetitionPenalty: Float = 1.05

    /// 声码器帧率：12.5 帧 = 1 秒音频（官方 12.5Hz codec）。
    private static let framesPerSecond = 12.5

    /// 句末留多长的呼吸（秒）。漂移样本常见 1s+ 的尾部静音，不裁就是「拖着」，
    /// 而句号那儿本来就该有一口气，所以留到 0.4s 为止。
    private static let naturalTrailing = 0.4

    /// **半句**（被 `SentenceSplitter.capping` 裁开的那一段）的尾巴只留这么多。
    ///
    /// 取 0.05 不是拍的：它等于 `trimSilence` 的 `keepLeading`，也就是每一段句首原本留的
    /// 那口气。接缝两边各 0.05s，中间只剩播放器换 item 的空档；按 0.4s 留的话就是
    /// 「一句本应连读的话在某个字上突然停一下」——实机听感正是这样，而真书里这种接缝
    /// 占 28.2%（`.probe/run-seam-probe.sh`：193 章 46265 句，弱边界 27.0% + 硬裁 1.1%）。
    private static let seamTrailing = 0.05

    /// 一句最快说完要多久（秒）。中文正常语速约 4 字/秒，但极短文本另有地板：
    /// 2026-09-23 实机日志里「按字数预期 ≤2s」的短句实测 1.66~5.99s——模型对一两个字也要
    /// 起腔、收尾，按字数线性外推出来的 0.25s 那条预期会把每条短句都判成「太长」，
    /// 于是每句白跑两趟 GPU。地板取实测下沿 1.6s。
    private static func expectedSeconds(for text: String) -> Double {
        let contentCount = text.filter { $0.isLetter || $0.isNumber }.count
        return max(1.6, Double(contentCount) / 4.0)
    }

    /// 一次生成的帧数上限 = 预期时长 ×2.2 换成帧。
    ///
    /// 旧口径是 512/768/1024/1536 四档定值：一句 20 字 62 帧就说完，却给 512 帧的预算，
    /// 漂移的样本因此在 GPU 上多烧近 7 倍（同一份实机日志里的单句 84s/158s/251s/347s）。
    /// 现在上限和质检同源：撞满上限就说明「说到这儿还没说完」，不必再拿时长去猜。
    private static func frameCeiling(for text: String) -> Int {
        Int((expectedSeconds(for: text) * 2.2 * framesPerSecond).rounded(.up))
    }

    /// 一句的墙钟预算：按每帧 0.30 秒给——0.30s 是实机测过的慢档，正常帧 ~0.14s
    /// （2026-09-23 那份数据；当前这套 12Hz 权重还没重测，所以取的是慢档而不是新测量）。
    /// 比这一档还慢就不是在算，是在等内存：同一次测量里出现过 13548ms 与 336s 的单帧停顿，
    /// 而播放器追上音频边界之后是干等，一句没有时限的活就能把整段朗读钉死。
    ///
    /// 折算下来是「每 1 秒音频给 3.75 秒墙钟」（0.30s/帧 × 12.5 帧/秒），而 0.14s/帧正常跑
    /// 只要 1.75 秒——被这一刀掐掉的只会是真跑偏或真卡内存的那一趟。
    /// **预算算在「一句」上，不是每趟**：两次重试各拿一份就等于把最坏耗时翻倍，
    /// 而单 worker + 24 句跑道（`ttsLookahead`）还不起——那正是「卡死」的形状。
    private static func sentenceBudgetSeconds(for ceiling: Int) -> Double {
        max(12.0, Double(ceiling) * 0.30)
    }

    // MARK: - Model Directory Resolution

    /// 权重由用户从「设置 → 模型下载」拉回沙盒（见 `ModelStore`），不再打进 App。
    /// `fromPretrained` 只读目录；组件不齐时提前 fail-loud，绝不带着残缺权重进「已加载」。
    private static func resolveModelDirectory() throws -> URL {

        let root = ModelStore.directory(.qwen3TTS)

        let missing = missingComponents(in: root)
        guard missing.isEmpty else {
            throw LocalTTSError.incompleteModel(missing: missing)
        }

        return root
    }

    /// 权重在不在沙盒里。**只查目录，不加载、不碰推理**：TTS 外层用它决定
    /// 这一格要不要试（缺权重是结构性不可用，不该拿四次失败去撞）。
    nonisolated static func modelAvailable() -> Bool {
        ModelStore.isReady(.qwen3TTS)
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
        let footprintBefore = Int(KokoroProcessMemory.footprintMB())

        let loaded = try await Qwen3TTSModel.fromPretrained(dir.path)

        model = loaded
        isLoaded = true

        MemoryProbe.log("TTS 加载 后")
        Self.logRuntimeProfile(loaded)
        print("TTS Ready：\(loaded.ttsModelType)，采样率 \(loaded.sampleRate)Hz，说话人 \(loaded.supportedSpeakers.joined(separator: "/"))（本地离线）")

        await warmUp()

        // 加载这一步结束时回收一次缓存池。`fromPretrained` 的顺序是：先按 config 建出
        // fp32 的随机权重（MLXNN 的 Linear/Embedding 初始化给的是 float32），再 `quantize`
        // 把要量的那张表换下来，最后 `model.update` 用盘上的 4bit 覆盖——中间那批 fp32 张量
        // 没人引用之后并不还给系统，而是躺在 MLX 的分配器缓存里（上限见 `Memory.cacheLimit`，
        // 设备上看 `[Perf] … 缓存上限=…MB 当前缓存=…MB`）。缓存池里的 buffer 照样占进程驻留，
        // 而系统按驻留量决定要不要杀（解析那一路的 `MLXQwenService.unload` 早就为同一件事清池，
        // TTS 这一路漏了）。
        //
        // 只在这一次无条件清：权重此时已经落定，清掉的都是加载过程的遗留，下一句要重新分配的
        // 只有激活。逐句那一路仍然走阈值（`reclaimCache`），无脑每句清会让下一句重新分配全部张量。
        let leftover = Memory.snapshot().cacheMemory
        Memory.clearCache()
        // 进程真实驻留（phys_footprint，Kokoro 那一路建的读数口径）：MLX 的 active/cached 只算
        // 它自己那点，杀进程判的是这个数。加载前/后各留一次，才能算出「这套权重到底吃多少」，
        // 而那正是内存闸口现在没有的信息（闸口的数是人写的估量，见 ReaderPipeline 的 ttsEstimate）。
        print("[TTS][Memory] 加载收尾：清掉加载遗留缓存 \(leftover / 1_048_576)MB | 进程驻留 "
            + "\(String(format: "%.0f", KokoroProcessMemory.footprintMB()))MB（加载前 \(footprintBefore)MB）")
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
        // `model = nil` 只把张量交回分配器，分配器把它们留在缓存池里（上限见 `Memory.cacheLimit`），
        // 从系统看这个进程还占着那么多。「一键关闭语音＝权重全卸」要真把内存交回去，得清一次池；
        // 现在这句打的是「已卸载」，实际没释放，是那条承诺的反面。
        // 清池只动没人引用的 buffer，正在用的权重/激活不在里面，所以另一路（解析）不受影响。
        let cached = Memory.snapshot().cacheMemory
        Memory.clearCache()
        print("Qwen3-TTS 已卸载，内存已释放（回收缓存池 \(cached / 1_048_576)MB | 进程驻留 "
            + "\(String(format: "%.0f", KokoroProcessMemory.footprintMB()))MB）")
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

        let ceiling = Self.frameCeiling(for: text)
        let expected = Self.expectedSeconds(for: text)
        // 一句一份墙钟预算，重试花的是同一份：剩下的不够就不该再试第二趟。
        let budget = Self.sentenceBudgetSeconds(for: ceiling)
        print("[TTS] instruct(\(style.count)字) 帧上限=\(ceiling)（预期 \(String(format: "%.2f", expected))s，预算 \(String(format: "%.0f", budget))s）：\(style.prefix(40))")

        let sampleRate = Double(model.sampleRate)

        var accepted: [Float]?
        var rejection = ""
        var spent = 0.0

        // 高 temperature 下 talker 偶发漂移：立即 EOS（静音、只剩几个字）、或说到帧上限还没
        // 收尾（跑偏成别的话）。校验输出，异常则降温重试一次。
        let synthStart = CFAbsoluteTimeGetCurrent()
        for attempt in 1 ... 2 {
            let attemptStart = CFAbsoluteTimeGetCurrent()

            let (rawSamples, frames) = try await generateWithinDeadline(
                text: text,
                voiceID: voiceID,
                style: style,
                temperature: attempt == 2 ? 0.6 : Self.temperature,
                ceiling: ceiling,
                deadline: max(4.0, budget - spent)
            )
            let genMs = (CFAbsoluteTimeGetCurrent() - attemptStart) * 1000
            spent += genMs / 1000

            // 半句的尾巴不许按句号那档留呼吸：它后面还有一次独立合成，中间隔着换
            // `AVPlayerItem` 的空档，两处叠起来就是「连读的话在半路停一下」。
            let joinsNext = SentenceSplitter.endsMidClause(text)
            let trimmed = Self.trimSilence(
                rawSamples,
                sampleRate: sampleRate,
                keepTrailing: joinsNext ? Self.seamTrailing : Self.naturalTrailing
            )
            let duration = Double(trimmed.samples.count) / sampleRate

            // 帧数没撞上限 = 循环自己等到了 EOS，音频长度就一定在 `ceiling` 之内，
            // 所以这一头不再需要「超过预期 2.2 倍」那条比值判据——它和上限本来就是同一件事。
            let truncated = frames >= ceiling
            let tooShort = duration < expected * 0.45
            let silent = trimmed.samples.count < Int(sampleRate * 0.1)

            print("[TTS⏱] 「\(text.prefix(8))」 总 \(String(format: "%.0f", genMs))ms | 音频 \(String(format: "%.2f", duration))s | 帧 \(frames)/\(ceiling) | RTF \(String(format: "%.2f", genMs / 1000 / max(0.01, duration))) | 尾静音 \(String(format: "%.2f", trimmed.tailSilence))s→留 \(joinsNext ? Self.seamTrailing : Self.naturalTrailing)s\(joinsNext ? "(连读段)" : "(句末)")")

            if silent || tooShort || truncated {
                rejection = silent ? "全静音"
                    : truncated ? "跑满 \(frames) 帧还没等到 EOS"
                    : "只有 \(String(format: "%.2f", duration))s / 预期 \(String(format: "%.2f", expected))s"
                print("[TTS] ⚠️ 时长异常(第\(attempt)次)：\(rejection) — \(text.prefix(12))")
                continue
            }

            accepted = trimmed.samples
            break
        }

        // 两次都不合格就抛错，绝不落盘「更接近预期的那个」：produce 之后按
        // sentenceID 命中磁盘缓存，一次残句会被永久复用，用户听到的就是
        // 「播几个字就结束」，而且再也等不到重录。
        //
        // 抛的是 `outputRejected`：它是对**这一段输出**的质检，不是后端坏了。外层拿它去计
        // 连坏次数的话，四句短对白就能把唯一还在跑的本地后端从本进程的降级链里永久摘掉
        // （`skipped` 只有换后端、权重增删才复位），表现就是「朗读突然再也不出声」。
        guard let samples = accepted else {
            Self.reclaimCache(after: "两次不合格")
            throw LocalTTSError.outputRejected(
                "\(rejection)（预期 \(String(format: "%.2f", expected))s，帧上限 \(ceiling)，已用 \(String(format: "%.0f", spent))s/预算 \(String(format: "%.0f", budget))s）：\(text.prefix(12))"
            )
        }

        let wavStart = CFAbsoluteTimeGetCurrent()
        let data = Self.audioToWAV(samples, sampleRate: sampleRate)
        let wavMs = (CFAbsoluteTimeGetCurrent() - wavStart) * 1000

        let totalMs = (CFAbsoluteTimeGetCurrent() - synthStart) * 1000
        print("[TTS⏱] 单句总计 \(String(format: "%.0f", totalMs))ms（WAV 编码 \(String(format: "%.0f", wavMs))ms）\(text.prefix(8))")

        // 成功那一路也要回收：一句生成留下的中间张量全在缓存池里，下一句接着往上堆。
        // 顶到 cacheLimit 不清的下场是同一次实机测量里的 13548ms / 336s 单帧停顿，
        // 而无脑每句 clear 会让下一句重新分配全部张量——所以照旧走阈值。
        Self.reclaimCache(after: "单句合成完成")

        MemoryProbe.log("单句合成完成 (\(text.prefix(8)))")

        print("语音生成完成 \(text.prefix(20))... 大小: \(data.count) bytes")

        return data
    }

    // MARK: - Bounded Generation

    /// 帧计数。回调在生成线程里跑（帧循环是同步的，中间没有 await），外面只在两个都收摊
    /// 之后读一次，所以一把锁够用；一次加锁相对一帧 140ms 可以忽略。
    private final class FrameCounter: @unchecked Sendable {

        private let lock = NSLock()
        private var value = 0

        func add() {
            lock.lock()
            value += 1
            lock.unlock()
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    /// 赛跑的两个孩子只有一个会给出结果，另一个必须被收干净——不然它的取消错就没人消费。
    private enum GenerationRace: Sendable {
        case samples([Float])
        /// 时限先到：生成那一趟正在被掐。
        case deadline
        /// 时限那一趟被取消（生成正常赢了）：不是结果，只是把孩子收掉。
        case notYet
    }

    /// 一趟带时限的生成。时限由调用方给（一句一份预算，重试花的是剩下的那一截）。
    ///
    /// 帧循环拦不住：那一段是同步的，谁也进不去，只能在它自己每帧查一次的
    /// `Task.isCancelled` 上使劲（见 `Qwen3.swift` 的 `generateCustomVoice`）。所以这里拿
    /// 时限和它赛跑，时限先到就取消这一组，循环在下一帧停下。
    ///
    /// 用任务组而不是 `Task {}`：独立任务不跟着上级取消，进后台那一掐就掐不到这里，
    /// 而这里掐不掉的每一帧都是往 Metal 里提交——那一次是 terminate，不是慢。
    ///
    /// **这个方法必须留在 actor 外面**（`.probe/run-deadline-probe.sh`，同语言模式 -swift-version 5）：
    /// 它是 actor 方法时，整个 `withThrowingTaskGroup` 的函数体也在这个 actor 上，而生成那个孩子
    /// 占着 actor 跑一长段没有 await 的循环，于是父任务的 `group.next()` 续延排不进去。实测
    /// 时限孩子在 100ms 就到点，父任务要等到循环跑满 400 帧（1018ms）才看见第一名，
    /// `cancelAll()` 落下时那趟已经算完了——时限只是「事后报了一句超时」。
    /// 改成 nonisolated 后同一场景 105ms 停下（第 43 帧）；从 actor 方法里 await 进来也一样管用
    /// （探针的 D 段，也就是 `synthesize` 的真实调用形状）。
    ///
    /// 这一条不只是耗时：时限掐不住 = 每一句跑偏的都把 `ceiling` 帧全跑完，还要把这一整串
    /// 帧喂给声码 decoder 解码（峰值音频长度也按满帧算），跑偏一次就是白烧一份峰值内存。
    private nonisolated func generateWithinDeadline(
        text: String,
        voiceID: String,
        style: String,
        temperature: Float,
        ceiling: Int,
        deadline: Double
    ) async throws -> (samples: [Float], frames: Int) {

        let counter = FrameCounter()

        let outcome = try await withThrowingTaskGroup(of: GenerationRace.self) { group in
            group.addTask {
                // 生成那一段留在 actor 上（`runGeneration`）：孩子是非隔离的，而 `model`
                // 是不满足 Sendable 的类实例，从孩子里直接取是一次隔离违规。跨出去的东西
                // 只有 `[Float]`。掐的机制不受影响——await 进 actor 时跑的是孩子自己的
                // job，`cancelAll()` 置的就是那个 job 的取消位。
                .samples(try await self.runGeneration(
                    text: text,
                    voiceID: voiceID,
                    style: style,
                    temperature: temperature,
                    ceiling: ceiling,
                    counter: counter
                ))
            }
            group.addTask {
                do {
                    try await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
                    return .deadline
                } catch {
                    return .notYet
                }
            }

            let first = try await group.next() ?? .notYet
            group.cancelAll()

            if case .deadline = first {
                // 被掐的那一趟还在跑最后一帧，收掉它的取消错再报时限。
                _ = try? await group.next()
                // 这一趟是半途停的：它已经攒下的中间张量全留在缓存池里，没人会再等它落定。
                Self.reclaimCache(after: "时限掐掉")
                throw LocalTTSError.tooSlow(
                    "时限 \(String(format: "%.0f", deadline))s 到了还没跑完，已跑 \(counter.count)/\(ceiling) 帧"
                )
            }
            // 另一个孩子（时限那一路）也要收干净。
            _ = try? await group.next()
            return first
        }

        guard case .samples(let samples) = outcome else {
            throw LocalTTSError.tooSlow("时限先于生成返回，却没拿到样本（帧 \(counter.count)/\(ceiling)）")
        }
        return (samples, counter.count)
    }

    /// 真正调用引擎的那一段，留在 actor 上跑：`model` 是本 actor 的隔离状态，也是个
    /// 不满足 Sendable 的类，只能在这里拿。帧计数用一个 `@unchecked Sendable` 的盒子递进去，
    /// 回调在同步帧循环里逐帧 +1，时限那一路掐完还能读到跑到第几帧。
    private func runGeneration(
        text: String,
        voiceID: String,
        style: String,
        temperature: Float,
        ceiling: Int,
        counter: FrameCounter
    ) async throws -> [Float] {

        guard let model else { throw LocalTTSError.modelNotLoaded }

        let audio = try await model.generate(
            text: text,
            speaker: voiceID,
            instruct: style.isEmpty ? nil : style,
            language: Self.language,
            temperature: temperature,
            topK: Self.topK,
            topP: Self.topP,
            repetitionPenalty: Self.repetitionPenalty,
            maxTokens: ceiling,
            onToken: { _ in counter.add() }
        )
        // 采样是在循环里逐帧攒的，交回来的是一个还没算的图：在这一趟结束前落定，
        // 别让下一句的分配压在这一次的惰性求值上。
        eval(audio)
        return audio.asType(.float32).asArray(Float.self)
    }

    /// 缓存池顶高了就回收一次。判据与解析那一路相同（见 `MLXQwenService.generate`）：
    /// 每句无脑 clearCache 会让下一句重新分配全部中间张量，而顶到 cacheLimit 却不清，
    /// 就是同一次实机测量里那种 13548ms / 336s 的单帧停顿。
    private nonisolated static func reclaimCache(after label: String) {
        let cached = Memory.snapshot().cacheMemory
        guard cached > MemoryProbe.clearThresholdBytes else { return }
        Memory.clearCache()
        print("[TTS][Memory] \(label)：cached \(cached / 1_048_576)MB > \(MemoryProbe.clearThresholdBytes / 1_048_576)MB → clearCache")
    }


    /// 裁掉过长的首尾静音，保留自然呼吸感。
    /// 漂移样本常见 1s+ 的尾部静音，直接听感就是“拖着”。
    ///
    /// 尾静音留多少要问这一句说完没有（`keepTrailing`，见调用那一段），
    /// 因为被裁开的半句后面还紧跟着一次独立合成。
    /// 返回值带上裁之前的尾静音长度：接缝到底是这段静音撑的还是播放器换 item 的空档撑的，
    /// 只有这一个数能分开，而音频只有在设备上才生成得出来。
    private struct Trimmed {
        let samples: [Float]
        /// 裁之前，最后一个有声采样到原始输出末尾之间有多长（秒）。
        let tailSilence: Double
    }

    private static func trimSilence(
        _ samples: [Float],
        sampleRate: Double,
        threshold: Float = 0.02,
        keepLeading: Double = 0.05,
        keepTrailing: Double = 0.4
    ) -> Trimmed {
        guard !samples.isEmpty else { return Trimmed(samples: [], tailSilence: 0) }

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
            return Trimmed(samples: [], tailSilence: Double(samples.count) / sampleRate)
        }

        let lead = Int(keepLeading * sampleRate)
        let trail = Int(keepTrailing * sampleRate)
        let start = max(0, firstLoud - lead)
        let end = min(samples.count, lastLoud + 1 + trail)
        let tailSilence = Double(samples.count - lastLoud - 1) / sampleRate

        guard start > 0 || end < samples.count else {
            return Trimmed(samples: samples, tailSilence: tailSilence)
        }
        return Trimmed(samples: Array(samples[start ..< end]), tailSilence: tailSilence)
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
    /// 这一段的两趟输出都没过质检（全静音 / 比预期短得多 / 跑满帧上限没等到 EOS）。
    /// 是对**这一段输出**的判断，不是后端坏了——外层拿它去计连坏次数会误摘后端，
    /// 见 `FallbackTTSService.synthesize` 的那一条分流。
    case outputRejected(String)
    /// 一趟生成撞上了墙钟时限被掐掉。这才是健康度信号：它意味着这一档跑不赢播放。
    case tooSlow(String)

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "TTS 模型未加载"
        case .incompleteModel(let missing):
            return """
            Qwen3-TTS 权重不完整，无法离线合成语音。缺失：\(missing.joined(separator: "、"))。
            到「设置 → 模型下载」里把 Qwen3-TTS 那一套下完（删掉重下也行），这一档就能出声了。
            """
        case .outputRejected(let reason):
            return "语音输出未通过质检: \(reason)"
        case .tooSlow(let reason):
            return "语音合成超时: \(reason)"
        }
    }
}
