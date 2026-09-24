//
//  main.swift
//  KokoroProbe
//
//  两个用途：
//    kokoro-probe voices [--gender male|female|all] [--text "…"] [--save]
//        把模型里的中文声音逐把合成同一句话，量出亮度/沙哑/中气并排序。
//        「更亮、中气更足、别太沙」是能测的：频谱质心、谐波噪声比、>4kHz 噪声占比。
//    kokoro-probe text "<一句话>" [--voice NAME] [--debug] [--save 路径]
//        只合成一句，打印句内停顿位置（每处静音段的时长），必要时打开
//        sherpa-onnx 自己的分词/分句日志。排查「词被断开」在哪一层。
//

import Foundation
import SherpaKokoroKit

// 单进程 CLI，命令顺序执行；主 actor 隔离的全局变量在 async 函数里读写会报警，
// 所以显式声明不安全（这里没有并发访问）。
nonisolated(unsafe) var arguments = Array(CommandLine.arguments.dropFirst())

nonisolated(unsafe) var probeThreadCount = 4

func takeOption(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    let value = arguments[index + 1]
    arguments.removeSubrange(index...(index + 1))
    return value
}

func takeFlag(_ name: String) -> Bool {
    guard let index = arguments.firstIndex(of: name) else { return false }
    arguments.remove(at: index)
    return true
}

func fmt(_ value: Double, _ digits: Int = 2) -> String {
    String(format: "%.\(digits)f", value)
}

/// C 的 `%-9s` 补不上 Swift 字符串的宽度，手写一个（中文列宽本来就对不齐，够用）。
func pad(_ text: String, _ width: Int) -> String {
    text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
}

func rpad(_ text: String, _ width: Int) -> String {
    text.count >= width ? text : String(repeating: " ", count: width - text.count) + text
}

let command = arguments.isEmpty ? "voices" : arguments.removeFirst()

/// ONNX Runtime 线程数。Kokoro 吐 NaN 是否与多线程有关，用 `--threads 1` 对照。
/// 必须在分发前吃掉这个参数，否则 `text` 会把它当成正文的一部分。
probeThreadCount = Int(takeOption("--threads") ?? "") ?? probeThreadCount

let defaultSurveyText = "他把书轻轻放在桌上，望着窗外的雨，忽然想起很多年前那个傍晚。"
let defaultProbeText = "这道题其实很简单，可我还是想了很久，始终没有想明白。"

func makeEngine(debug: Bool) throws -> KokoroTTSEngine {
    let files = try KokoroModelFiles(directory: KokoroModelLocator.resolveKokoroModelDirectory())
    return KokoroTTSEngine(configuration: KokoroConfiguration(
        modelFiles: files,
        language: .zh,
        numThreads: probeThreadCount,
        debug: debug
    ))
}

// MARK: - voices

func surveyVoices() async {
    let gender = takeOption("--gender") ?? "all"
    let save = takeFlag("--save")
    let limit = Int(takeOption("--limit") ?? "") ?? 0
    /// `--sort narration`：按「沉稳/稳/干净」排，选旁白用；默认 `bright` 是旧的选亮嗓口径。
    let sortMode = takeOption("--sort") ?? "bright"

    let files = try! KokoroModelFiles(
        directory: KokoroModelLocator.resolveKokoroModelDirectory())
    let all = KokoroVoice.table(
        from: KokoroSpeakerTable.speakerNames(modelURL: files.model) ?? []).chinese

    let voices: [KokoroVoice]
    switch gender {
    case "male": voices = all.chinese(gender: .male)
    case "female": voices = all.chinese(gender: .female)
    default: voices = all
    }
    let picked = limit > 0 ? Array(voices.prefix(limit)) : voices

    guard let tts = makeRawTts(threads: probeThreadCount) else {
        print("引擎创建失败")
        return
    }

    let outputDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("kokoro-voice-survey", isDirectory: true)
    if save {
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    }

    // 三句一组：坏音频（NaN）是按 (文本, 声音) 出的，只测一句会把一把
    // 「恰好在这句上没事」的声音当成稳健的。
    let texts = [
        "你好，欢迎来到这个世界。",
        "他把书轻轻放在桌上，望着窗外的雨，忽然想起很多年前那个傍晚。",
        "这道题其实很简单，可我还是想了很久，始终没有想明白。"
    ]

    print("模型=\(files.directory.path)")
    print("文本=\(texts.count) 句 样本=\(picked.count) 把 threads=\(probeThreadCount)")
    print("")

    struct Row {
        var voice: KokoroVoice
        var summary: AudioMetrics.Summary
        var good = 0
        var total = 0
        /// 三句之间基频的最大落差（Hz）：旁白要「稳」，忽高忽低听着像播报腔在飘。
        var f0Spread = 0.0
    }

    var rows: [Row] = []
    let started = Date()

    for voice in picked {
        var centroids: [Double] = []
        var hnr: [Double] = []
        var high: [Double] = []
        var rms: [Double] = []
        var f0: [Double] = []
        var voiced: [Int] = []
        var good = 0
        var seconds = 0.0
        for text in texts {
            let samples = rawGenerate(tts, text: text, sid: voice.sid, speed: 1.0, silenceScale: 0.2)
            let stats = AudioMetrics.analyze(samples, sampleRate: 24_000)
            if stats.nonFiniteSamples > 0 {
                seconds += stats.durationSeconds
                continue
            }
            good += 1
            let summary = AudioMetrics.summarize(stats)
            centroids.append(summary.centroidHz)
            hnr.append(summary.hnrDb)
            high.append(summary.highBandRatio)
            rms.append(summary.rms)
            f0.append(summary.f0Hz)
            voiced.append(summary.voicedFrames)
            seconds += stats.durationSeconds
            if save, good == 1 {
                let url = outputDirectory.appendingPathComponent("\(voice.sid)-\(voice.name).wav")
                try? KokoroAudio(samples: samples, sampleRate: 24_000).wavData().write(to: url)
            }
        }
        func mean(_ values: [Double]) -> Double {
            values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
        }
        rows.append(Row(
            voice: voice,
            summary: AudioMetrics.Summary(
                f0Hz: mean(f0),
                hnrDb: mean(hnr),
                centroidHz: mean(centroids),
                highBandRatio: mean(high),
                rms: mean(rms),
                voicedFrames: voiced.isEmpty ? 0 : voiced.reduce(0, +) / voiced.count),
            good: good,
            total: texts.count,
            f0Spread: (f0.max() ?? 0) - (f0.min() ?? 0)))
        print(".", terminator: "")
        if rows.endIndex % 10 == 0 { print("") }
    }
    print("\n")

    func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
    func stdev(_ values: [Double]) -> Double {
        let mean = values.reduce(0, +) / Double(values.count)
        return sqrt(values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(max(1, values.count - 1)))
    }

    let usable = rows.filter { $0.good > 0 }
    let (cMean, cSd) = (median(usable.map(\.summary.centroidHz)), stdev(usable.map(\.summary.centroidHz)))
    let (hMean, hSd) = (median(usable.map(\.summary.hnrDb)), stdev(usable.map(\.summary.hnrDb)))
    let (bMean, bSd) = (median(usable.map(\.summary.highBandRatio)), stdev(usable.map(\.summary.highBandRatio)))
    let (fMean, fSd) = (median(usable.map(\.summary.f0Hz)), stdev(usable.map(\.summary.f0Hz)))
    let (sMean, sSd) = (median(usable.map(\.f0Spread)), stdev(usable.map(\.f0Spread)))

    func z(_ value: Double, _ mean: Double, _ sd: Double) -> Double {
        (value - mean) / max(1, sd)
    }

    // 「亮」= 频谱质心高；「不沙、中气足」= 谐波噪声比高且高频噪声占比低。
    func brightScore(_ row: Row) -> Double {
        z(row.summary.centroidHz, cMean, cSd)
            + z(row.summary.hnrDb, hMean, hSd)
            - z(row.summary.highBandRatio, bMean, bSd)
    }

    /// 「小说旁白」的代理指标，和上面那条不是一回事：旁白要**沉稳、稳、干净**，
    /// 不要亮、不要中气足到发冲 —— 低沉(F0 低)、三句之间不飘(spread 小)、
    /// 谐波干净(hnr 高)、也不发闷尖(质心别太高，权重压低)。
    /// 基频只列出来供判断，不进分：男声里挑最高 F0 会挑到发嗲的，那不是「亮」。
    func narrationScore(_ row: Row) -> Double {
        -z(row.summary.f0Hz, fMean, fSd)
            - z(row.f0Spread, sMean, sSd)
            + z(row.summary.hnrDb, hMean, hSd)
            + 0.3 * z(row.summary.centroidHz, cMean, cSd)
    }
    let score = sortMode == "bright" ? brightScore : narrationScore

    print("参照（本组中位数）：质心 \(fmt(cMean, 0))Hz  HNR \(fmt(hMean, 1))dB  >4k 占比 \(fmt(bMean, 3))  F0 \(fmt(fMean, 0))Hz  抖 \(fmt(sMean, 0))Hz")
    print("排序口径=\(sortMode)  「坏」列 = 三句里吐出 NaN 的次数（同一句同一把会稳定复现）；「抖」= 三句之间基频最大落差")
    print("")
    print(pad("sid", 5) + pad("name", 10) + pad("性别", 4)
        + rpad("质心Hz", 9) + rpad("HNRdB", 8) + rpad(">4k", 8) + rpad("F0Hz", 7)
        + rpad("抖Hz", 7) + rpad("RMS", 8) + rpad("坏", 6) + rpad("分", 7))

    // 稳健性优先于音色：一句里三成概率爆音的声音，音色再好也不能当旁白。
    for row in rows.sorted(by: {
        if $0.good != $1.good { return $0.good > $1.good }
        return score($0) > score($1)
    }) {
        print(pad(String(row.voice.sid), 5) + pad(row.voice.name, 10)
            + pad(row.voice.gender == .male ? "男" : "女", 4)
            + rpad(fmt(row.summary.centroidHz, 0), 9)
            + rpad(fmt(row.summary.hnrDb, 1), 8)
            + rpad(fmt(row.summary.highBandRatio, 3), 8)
            + rpad(fmt(row.summary.f0Hz, 0), 7)
            + rpad(fmt(row.f0Spread, 0), 7)
            + rpad(fmt(row.summary.rms, 3), 8)
            + rpad("\(row.total - row.good)/\(row.total)", 6)
            + rpad(fmt(score(row), 2), 7))
    }

    print("")
    print("耗时 \(fmt(Date().timeIntervalSince(started), 0))s")
    if save { print("WAV 输出目录=\(outputDirectory.path)（每把取第一条干净样本）") }
}

// MARK: - text

func probeText() async {
    let voiceName = takeOption("--voice")
    let debug = takeFlag("--debug")
    let saveTo = takeOption("--save")
    let text = arguments.isEmpty ? defaultProbeText : arguments.joined(separator: " ")

    let engine = try! makeEngine(debug: debug)
    let report = try! await engine.load()
    let table = KokoroVoice.table(from: report.speakerNames)

    guard let voice = (voiceName.flatMap { name in table.first { $0.name == name || String($0.sid) == name } }
        ?? table.chinese.first) else {
        print("没有可用声音")
        return
    }

    print("文本=「\(text)」")
    print("voice=\(voice.name)(sid \(voice.sid))  debug=\(debug)")

    let result: KokoroGenerationResult
    do {
        result = try await engine.generate(text: text, voice: voice)
    } catch {
        // 引擎对 NaN/静音音频直接判失败（听感是爆音或凭空消失），这里把它报出来
        // 而不是 try! 崩掉——`fragments`/`length` 就是靠这个计数算失败率的。
        print("合成失败：\(error)")
        return
    }
    // 分开计时：模型慢还是量测慢，决定了下一步优化哪边。
    print("生成 \(fmt(result.metrics.generationTime * 1000, 0))ms  RTF \(fmt(result.metrics.rtf))")
    let metricStart = CFAbsoluteTimeGetCurrent()
    let stats = AudioMetrics.analyze(result.audio.samples, sampleRate: result.audio.sampleRate, minPauseMs: 80)
    print("量测 \(fmt((CFAbsoluteTimeGetCurrent() - metricStart) * 1000, 0))ms")
    let summary = AudioMetrics.summarize(stats)
    let frameMs = Double(AudioMetrics.hop) / Double(result.audio.sampleRate) * 1000

    print("时长 \(fmt(stats.durationSeconds))s  峰值 \(fmt(stats.peak, 3))  浊帧 \(summary.voicedFrames)/\(stats.frames.count)")
    print("质心 \(fmt(summary.centroidHz, 0))Hz  HNR \(fmt(summary.hnrDb, 1))dB  >4k \(fmt(summary.highBandRatio, 3))  F0 \(fmt(summary.f0Hz, 0))Hz")
    if stats.nonFiniteSamples > 0 {
        print("⚠ 非有限采样 \(stats.nonFiniteSamples)/\(result.audio.samples.count) "
            + "(\(fmt(Double(stats.nonFiniteSamples) / Double(max(1, result.audio.samples.count)) * 100, 1))%) "
            + "—— WAV 编码器会把 NaN 夹成 ±1.0，这句存出来是全刻度方波")
    }

    // 静音段的位置：一句被内部分成几段，看这里被插了几处停顿（含首尾各一处）。
    var runs: [(ms: Double, at: Double)] = []
    var current: (ms: Double, at: Double)?
    var position = 0.0
    for frame in stats.frames {
        if frame.rms < 0.02 {
            if current == nil { current = (0, position) }
            current!.ms += frameMs
        } else if let run = current {
            if run.ms >= 80 { runs.append(run) }
            current = nil
        }
        position += frameMs
    }
    if let run = current, run.ms >= 80 { runs.append(run) }

    print("")
    print("静音段（≥80ms，含首尾）：\(runs.count) 处")
    for run in runs {
        print(String(format: "  位置 %@s  时长 %.0fms", fmt(run.at / 1000, 2), run.ms))
    }

    var map = ""
    for frame in stats.frames {
        if frame.rms < 0.02 {
            map.append(".")
        } else if !frame.pitched {
            map.append("-")   // 抽测没抽到（见 AudioMetrics.maxPitchedFrames）
        } else {
            map.append(frame.voicedCorrelation >= 0.3 ? "#" : "~")
        }
    }
    print("  每字符 \(fmt(frameMs, 0))ms：# 浊音 ~ 清音/擦音 . 静音 - 未抽测")
    print("  \(map)")

    if let saveTo {
        let url = URL(fileURLWithPath: (saveTo as NSString).expandingTildeInPath)
        try? result.audio.wavData().write(to: url)
        print("已存 \(url.path)")
    }
}

// MARK: - fragments

/// 一次加载、连测一批短句，专门找 Kokoro 吐 NaN / 空音频 / 全刻度方波的输入。
/// 断句器会把「他说：」这类只剩标点或引导语的碎片单独切成一句，必须知道哪些碎片不能喂给模型。
func probeFragments() async {
    let voiceName = takeOption("--voice")
    let repeatCount = Int(takeOption("--repeat") ?? "1") ?? 1
    let engine = try! makeEngine(debug: false)
    let report = try! await engine.load()
    let table = KokoroVoice.table(from: report.speakerNames)

    guard let voice = (voiceName.flatMap { name in table.first { $0.name == name || String($0.sid) == name } }
        ?? table.chinese.first) else {
        print("没有可用声音")
        return
    }
    print("voice=\(voice.name)(sid \(voice.sid))  每条重复合成 \(repeatCount) 次")
    print("")
    print(pad("输入", 18) + rpad("坏/总", 8) + rpad("时长s", 7) + rpad("峰值", 8)
        + rpad("NaN", 8) + "结果")

    let samples: [String] = [
        "他说：", "他说:", "他说，", "他说。", "他说", "他说：你好。",
        "说：", "说：你好。", "张三说：", "张三说：你好。",
        "好的。", "好。", "好的，我知道了。",
        "嗯？", "嗯，是吗？", "哦！", "哦，我知道了！", "啊……", "啊，是你啊。",
        "走。", "我们走。", "等等——", "你等一下。", "（笑）", "他笑了笑。",
        "喂？", "喂，是你吗？", "「", "」", "他低声说：", "他低声说：别出声。"
    ]

    for text in samples {
        var bad = 0
        var outcome = ""
        var counted = 0
        var rate = 24_000
        var nan = 0
        var peak = 0.0
        var nanMap = ""
        for _ in 0..<max(1, repeatCount) {
            do {
                let result = try await engine.generate(text: text, voice: voice)
                counted = result.audio.samples.count
                rate = result.audio.sampleRate
                let stats = AudioMetrics.analyze(result.audio.samples, sampleRate: result.audio.sampleRate)
                nan = stats.nonFiniteSamples
                peak = stats.peak
                nanMap = nanRunMap(of: result.audio.samples)
                if stats.nonFiniteSamples > 0 {
                    bad += 1
                    outcome = "NaN 污染"
                } else if stats.frames.contains(where: { $0.rms >= 0.02 && $0.voicedCorrelation >= 0.3 }) {
                    outcome = "正常"
                } else {
                    bad += 1
                    outcome = "无浊音"
                }
            } catch {
                bad += 1
                outcome = "抛出：\(error)"
            }
        }
        let ratio = nan > 0 ? "\(fmt(Double(nan) / Double(max(1, counted)) * 100, 0))%" : "-"
        print(pad(text, 18) + rpad("\(bad)/\(max(1, repeatCount))", 8)
            + rpad(fmt(Double(counted) / Double(rate)), 7)
            + rpad(fmt(peak, 3), 8) + rpad(ratio, 8) + outcome)
        if !nanMap.isEmpty {
            // X = 该 1/60 段里至少有一个 NaN。整段/半段/尾部，形状不同原因也不同。
            print(String(repeating: " ", count: 26) + nanMap)
        }
    }
}

/// 把 NaN 的分布压成 60 格：X = 这一段里有 NaN。
/// 整段/半段/尾部，形状不同原因也不同（截断 vs 解码炸掉）。
func nanRunMap(of samples: [Float]) -> String {
    let buckets = 60
    guard samples.contains(where: { !$0.isFinite }) else { return "" }
    let size = max(1, samples.count / buckets)
    var map = ""
    var start = 0
    while start < samples.count {
        let end = min(start + size, samples.count)
        var hit = false
        for i in start..<end where !samples[i].isFinite {
            hit = true
            break
        }
        map.append(hit ? "X" : ".")
        start = end
    }
    return map
}

// MARK: - length

/// 失败率 / RTF / 语速 vs 句长。用同一段正文裁出不同长度，排除「内容」这个变量，
/// 只留「喂给模型的字符数」——决定要不要靠断句合并来规避 NaN，
/// 以及长句是不是真的会让推理变慢（设备侧 RTF 从 0.8 掉到 3.3 的那条曲线）。
func probeLength() async {
    let voiceName = takeOption("--voice")
    let repeatCount = max(1, Int(takeOption("--repeat") ?? "5") ?? 5)
    let lengthList = (takeOption("--lengths") ?? "4, 8, 16, 24, 32, 48, 64, 96, 128, 160, 200")
        .split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    let engine = try! makeEngine(debug: false)
    let report = try! await engine.load()
    let table = KokoroVoice.table(from: report.speakerNames)

    guard let voice = (voiceName.flatMap { name in table.first { $0.name == name || String($0.sid) == name } }
        ?? table.chinese.first) else {
        print("没有可用声音")
        return
    }
    print("voice=\(voice.name)(sid \(voice.sid))  threads=\(probeThreadCount)  每种长度 \(repeatCount) 次")
    print(rpad("字数", 8) + rpad("音频", 10) + rpad("生成", 10) + rpad("RTF", 8)
        + rpad("并行度", 9) + rpad("秒/字", 10) + "失败")
    print("")

    /// 同一段正文重复拼接，只让「长度」这一个变量变化。
    let unit = "他把书轻轻放在桌上，望着窗外绵绵的雨，忽然想起很多年以前那个闷热的傍晚，院子里的蝉声一直没有停过，母亲在厨房里喊他吃饭，他应了一声却没有动。"
    let base = Array(String(repeating: unit, count: 4))

    /// 长句样本落盘，用于人耳/波形检查句尾是否吐出不属于文本的内容。
    let save = takeFlag("--save")
    let tailDir = FileManager.default.temporaryDirectory.appendingPathComponent("kokoro-length-tail")
    if save {
        try? FileManager.default.createDirectory(at: tailDir, withIntermediateDirectories: true)
    }

    for length in lengthList {
        let text = String(base.prefix(max(0, length - 1))) + "。"
        let spoken = text.filter { $0.isLetter || $0.isNumber }.count
        var bad = 0
        var audio = 0.0
        var generation = 0.0
        var cpu = 0.0
        var okRuns = 0
        var lastSamples: [Float] = []
        for _ in 0..<repeatCount {
            do {
                let result = try await engine.generate(text: text, voice: voice)
                let stats = AudioMetrics.analyze(result.audio.samples, sampleRate: result.audio.sampleRate)
                audio += result.metrics.audioDuration
                generation += result.metrics.generationTime
                cpu += result.metrics.cpuTime
                okRuns += 1
                lastSamples = result.audio.samples
                if stats.nonFiniteSamples > 0
                    || !stats.frames.contains(where: { $0.rms >= 0.02 && $0.voicedCorrelation >= 0.3 }) {
                    bad += 1
                }
            } catch {
                bad += 1
            }
        }
        if save, !lastSamples.isEmpty {
            let url = tailDir.appendingPathComponent("len\(spoken).wav")
            try? KokoroAudio(samples: lastSamples, sampleRate: 24_000).wavData().write(to: url)
        }
        guard okRuns > 0 else {
            print(rpad("\(spoken)字", 8) + "全部失败 (\(bad)/\(repeatCount))")
            continue
        }
        let meanAudio = audio / Double(okRuns)
        let meanGen = generation / Double(okRuns)
        // 并行度 = 进程 CPU 秒 / 墙钟秒：接近 threads 说明真在算（受限于算力），
        // 明显低于 threads 说明线程被饿着（抢核 / 降频）。和设备日志同一口径。
        let parallelism = meanGen > 0 ? (cpu / Double(okRuns)) / meanGen : 0
        print(rpad("\(spoken)字", 8)
            + rpad(fmt(meanAudio, 2) + "s", 10)
            + rpad(fmt(meanGen, 2) + "s", 10)
            + rpad(fmt(meanGen / meanAudio, 2), 8)
            + rpad(fmt(parallelism, 2), 9)
            + rpad(fmt(meanAudio / Double(spoken), 3), 10)
            + "\(fmt(Double(bad) / Double(repeatCount) * 100, 0))% 失败 (\(bad)/\(repeatCount))")
    }
    if save {
        print("\nWAV 输出目录=\(tailDir.path)")
    }
}

// MARK: - sustained

/// 连续合成，把**句序**当自变量：RTF / 并行度 / 驻留 随第几句怎么变。
///
/// 设备现象是「一章里后面的句子 RTF 涨到 3」，而 `length` 测出来的句长→RTF 曲线
/// 在 Mac 上是平的（0.72→0.89，一直到 183 字），所以剩下的嫌疑都是**随时间累积**
/// 的东西：热降频、驻留涨上去后 App bundle 里的权重页被内核回收（再推理就是磁盘
/// 换页）、ORT arena 碎片。三者在表里的形状不一样：热降频＝并行度不变但每秒变慢；
/// 换页＝驻留先爬到某个高度再崩；碎片＝驻留单调上爬不回落。
func probeSustained() async {
    let count = max(1, Int(takeOption("--count") ?? "30") ?? 30)
    let voiceName = takeOption("--voice")
    let engine = try! makeEngine(debug: false)
    _ = try! await engine.load()
    let table = await engine.voices
    guard let voice = (voiceName.flatMap { name in table.first { $0.name == name || String($0.sid) == name } }
        ?? table.chinese.first) else {
        print("没有可用声音")
        return
    }

    let texts = [
        "正激动中，小胖子忽然把手机举到我面前，说要给我看一样东西。",
        "他把书轻轻放在桌上，望着窗外绵绵的雨，没有说话。",
        "这道题其实很简单，可我还是想了很久，始终没有想明白其中关键的这一步。",
        "那天晚上下了很大的雨，院子里的水一直漫到台阶上来。",
    ]

    print("voice=\(voice.name)(sid \(voice.sid))  threads=\(probeThreadCount)  连续 \(count) 句")
    print(rpad("序", 5) + rpad("字数", 7) + rpad("音频", 9) + rpad("生成", 9)
        + rpad("RTF", 7) + rpad("并行度", 9) + "驻留MB")
    print("")

    let startedAt = Date()
    let baseline = processFootprintMB()

    for index in 0..<count {
        let text = texts[index % texts.count]
        let spoken = text.filter { $0.isLetter || $0.isNumber }.count
        do {
            let result = try await engine.generate(text: text, voice: voice)
            let metrics = result.metrics
            let parallelism = metrics.generationTime > 0
                ? metrics.cpuTime / metrics.generationTime : 0
            let footprint = processFootprintMB()
            let delta = footprint - baseline
            print(rpad("\(index + 1)", 5)
                + rpad("\(spoken)字", 7)
                + rpad(fmt(metrics.audioDuration, 2) + "s", 9)
                + rpad(fmt(metrics.generationTime, 2) + "s", 9)
                + rpad(fmt(metrics.rtf, 2), 7)
                + rpad(fmt(parallelism, 2), 9)
                + rpad("\(fmt(footprint, 0))(Δ\(delta >= 0 ? "+" : "")\(fmt(delta, 0)))", 18)
                + "\(fmt(Date().timeIntervalSince(startedAt), 0))s")
        } catch {
            print(rpad("\(index + 1)", 5) + rpad("\(spoken)字", 7) + "抛出：\(error)")
        }
    }
}

switch command {
case "voices": await surveyVoices()
case "text": await probeText()
case "fragments": await probeFragments()
case "length": await probeLength()
case "nan": await probeNaN()
case "rate": await probeRate()
case "sustained": await probeSustained()
default:
    print("用法: kokoro-probe voices [--gender male|female|all] [--sort bright|narration] [--text …] [--save]")
    print("      kokoro-probe text \"<句>\" [--voice NAME|sid] [--debug] [--save 路径]")
    print("      kokoro-probe fragments [--voice NAME|sid] [--repeat N]")
    print("      kokoro-probe length [--voice NAME|sid] [--repeat N] [--threads N]   # 句长 → RTF/失败率")
    print("      kokoro-probe rate [--voices A,B,sid] [--speeds 0.7,1.0,1.3] [--repeat N]  # 声音×语速 的 NaN 矩阵")
    print("      kokoro-probe sustained [--voice NAME|sid] [--count N] [--threads N]  # 句序 → 退化")
    exit(2)
}
