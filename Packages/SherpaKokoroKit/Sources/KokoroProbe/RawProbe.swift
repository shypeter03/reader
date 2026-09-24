//
//  RawProbe.swift
//  KokoroProbe
//
//  绕开 KokoroTTSEngine 的健康检查，直接用 sherpa-onnx 的 C 接口拿**原始**采样。
//  目的只有一个：看清 NaN 到底长在哪、由什么触发。引擎的 guard 会把坏音频抛掉，
//  在修复方案定下来之前不能为了诊断去改生产代码。
//

import Foundation
import SherpaKokoroKit
import SherpaOnnx

/// 进程真实驻留（phys_footprint，和 Xcode Memory Gauge 同口径），单位 MB。
/// App 侧那份在 `KokoroProcessMemory`，这里不能依赖 target 外的代码。
func processFootprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
        MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
    )
    let kr = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { ints in
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), ints, &count)
        }
    }
    guard kr == KERN_SUCCESS else { return -1 }
    return Double(info.phys_footprint) / 1_048_576
}

/// 与 KokoroTTSEngine.load() 等价的配置，只是不经过 actor。
func makeRawTts(threads: Int) -> SherpaOnnxOfflineTtsWrapper? {
    let files = try! KokoroModelFiles(
        directory: KokoroModelLocator.resolveKokoroModelDirectory())
    let configuration = KokoroConfiguration(
        modelFiles: files, language: .zh, numThreads: threads)

    let kokoro = sherpaOnnxOfflineTtsKokoroModelConfig(
        model: files.model.path,
        voices: files.voices.path,
        tokens: files.tokens.path,
        dataDir: files.espeakData.path,
        lengthScale: 1.0,
        dictDir: "",
        lexicon: configuration.lexiconArgument,
        lang: ""
    )
    let modelConfig = sherpaOnnxOfflineTtsModelConfig(
        kokoro: kokoro,
        numThreads: configuration.numThreads,
        debug: 0,
        provider: "cpu"
    )
    var ttsConfig = sherpaOnnxOfflineTtsConfig(
        model: modelConfig,
        ruleFsts: configuration.ruleFSTArgument,
        ruleFars: "",
        maxNumSentences: 1,
        silenceScale: configuration.silenceScale
    )
    let wrapper = SherpaOnnxOfflineTtsWrapper(config: &ttsConfig)
    guard wrapper.tts != nil else { return nil }
    return wrapper
}

struct RawRun {
    var count: Int
    var nanCount: Int
    var infCount: Int
    /// 连续非有限段：(起点采样, 长度)
    var runs: [(start: Int, length: Int)]
    var total: Int { count }
}

func inspect(_ samples: [Float]) -> RawRun {
    var nan = 0
    var inf = 0
    var runs: [(Int, Int)] = []
    var start = -1
    for (index, sample) in samples.enumerated() {
        let bad = !sample.isFinite
        if bad {
            if sample.isNaN { nan += 1 } else { inf += 1 }
            if start == -1 { start = index }
        } else if start != -1 {
            runs.append((start, index - start))
            start = -1
        }
    }
    if start != -1 { runs.append((start, samples.count - start)) }
    return RawRun(count: samples.count, nanCount: nan, infCount: inf, runs: runs)
}

/// 时间轴上的 NaN 分布：X = 该格至少一个非有限采样。
func badMap(count: Int, runs: [(start: Int, length: Int)], buckets: Int = 60) -> String {
    guard !runs.isEmpty else { return "" }
    var map = Array(repeating: Character("."), count: buckets)
    for run in runs {
        let first = run.start * buckets / max(1, count)
        let last = min(buckets - 1, (run.start + run.length) * buckets / max(1, count))
        for i in max(0, first)...max(0, last) { map[i] = "X" }
    }
    return String(map)
}

func rawGenerate(
    _ tts: SherpaOnnxOfflineTtsWrapper,
    text: String,
    sid: Int,
    speed: Double,
    silenceScale: Float
) -> [Float] {
    let config = SherpaOnnxGenerationConfigSwift(
        silenceScale: silenceScale,
        speed: Float(speed),
        sid: sid
    )
    let audio = tts.generateWithConfig(text: text, config: config, callback: nil, arg: nil)
    return audio.samples
}

func report(_ label: String, _ samples: [Float], sampleRate: Int = 24_000) {
    let run = inspect(samples)
    let seconds = Double(run.count) / Double(sampleRate)
    let bad = run.nanCount + run.infCount
    let runs = run.runs.map { "\($0.start / 24)ms+\($0.length / 24)ms" }.joined(separator: " ")
    print("\(pad(label, 34)) 总\(pad("\(run.count)", 8)) 坏\(rpad("\(bad)", 7))"
        + "(\(fmt(Double(bad) / Double(max(1, run.count)) * 100, 1))%) 时长\(fmt(seconds, 2))s \(runs)")
    let map = badMap(count: run.count, runs: run.runs)
    if !map.isEmpty {
        print(String(repeating: " ", count: 34) + "时间轴: " + map)
    }
}

func probeNaN() async {
    let voiceName = takeOption("--voice") ?? "zm_009"
    let files = try! KokoroModelFiles(
        directory: KokoroModelLocator.resolveKokoroModelDirectory())
    let table = KokoroVoice.table(
        from: KokoroSpeakerTable.speakerNames(modelURL: files.model) ?? [])
    guard let voice = table.first(where: { $0.name == voiceName || String($0.sid) == voiceName }) else {
        print("找不到声音 \(voiceName)")
        return
    }
    guard let tts = makeRawTts(threads: probeThreadCount) else {
        print("引擎创建失败")
        return
    }
    print("原始采样诊断 voice=\(voice.name)(sid \(voice.sid)) threads=\(probeThreadCount)")
    print("（「ms+ms」= 非有限段的起点与长度；坏采样在原张量里，ScaleSilence 只会拷贝/补零，不会造 NaN）")
    print("")

    let text = "你好，欢迎来到这个世界。"

    print("### 1) 同参数重复 3 次：NaN 是否确定")
    for i in 1...3 {
        report("第\(i)次 speed=1.0", rawGenerate(tts, text: text, sid: voice.sid, speed: 1.0, silenceScale: 0.2))
    }

    print("")
    print("### 2) 只改语速（同一文本/声音）")
    for speed in [0.7, 0.85, 0.95, 1.0, 1.05, 1.1, 1.15, 1.2, 1.3] {
        report("speed=\(speed)", rawGenerate(tts, text: text, sid: voice.sid, speed: speed, silenceScale: 0.2))
    }

    print("")
    print("### 3) 只改 silence_scale（1.0 = 完全跳过 ScaleSilence）")
    for scale in [1.0, 0.5, 0.2, 0.01] {
        report("silence_scale=\(scale)", rawGenerate(tts, text: text, sid: voice.sid, speed: 1.0, silenceScale: Float(scale)))
    }

    print("")
    print("### 4) 换声音（同文本同语速）")
    for candidate in table.chinese.prefix(12) {
        report("\(candidate.name)(\(candidate.sid))", rawGenerate(tts, text: text, sid: candidate.sid, speed: 1.0, silenceScale: 0.2))
    }

    print("")
    print("### 5) 同句换「字数」：只在句首加填充字，看 NaN 是否跟着 token 数走")
    for filler in ["", "嗯", "嗯嗯", "那么", "那么说，", "其实呢，"] {
        let variant = filler + text
        report("「\(variant)」", rawGenerate(tts, text: variant, sid: voice.sid, speed: 1.0, silenceScale: 0.2))
    }
}

// MARK: - rate

/// 「同一个输入重复 N 次，有多少次是好的」。
/// NaN 是随机出现的，所以重试值不值得做、几次够，只有这张表能回答。
func probeRate() async {
    let repeatCount = max(1, Int(takeOption("--repeat") ?? "10") ?? 10)
    let names = (takeOption("--voices") ?? "58,3,14").split(separator: ",")
        .map { String($0.trimmingCharacters(in: .whitespaces)) }

    guard let tts = makeRawTts(threads: probeThreadCount) else {
        print("引擎创建失败")
        return
    }
    let files = try! KokoroModelFiles(
        directory: KokoroModelLocator.resolveKokoroModelDirectory())
    let table = KokoroVoice.table(
        from: KokoroSpeakerTable.speakerNames(modelURL: files.model) ?? [])

    let texts = [
        "你好，欢迎来到这个世界。",
        "他把书轻轻放在桌上，望着窗外的雨。",
        "这道题其实很简单，可我还是想了很久。",
        "今天我们一起读一本有趣的小说。",
        // 自测里「越界夹取3.0」实际合成的那两句，语速被夹到 1.3 时出过 NaN，所以一起扫。
        "你好，欢迎来到这个世界。今天我们一起读一本有趣的小说。"
    ]

    /// 语速也是一根轴：夹取后的上下界（0.7 / 1.3）最容易把 int8 推出 NaN。
    /// 换旁白声音必须在三档语速上一起看，否则「不沙」可能换来「一拉快就爆音」。
    let speeds = (takeOption("--speeds") ?? "1.0")
        .split(separator: ",")
        .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }

    print("threads=\(probeThreadCount)  每个输入重复 \(repeatCount) 次  语速=\(speeds.map { fmt($0, 2) })")
    print(pad("voice", 12) + pad("语速", 8) + pad("输入", 40) + "好/总   NaN起点    NaN长度")
    for name in names {
        guard let voice = table.first(where: { $0.name == name || String($0.sid) == name }) else {
            print("跳过 \(name)（表里没有）")
            continue
        }
        // 声音 × 语速 × 文本 一次扫完，选旁白时只看一张表。
        let combos = speeds.flatMap { speed in texts.map { (speed, $0) } }
        for (speed, text) in combos {
            var good = 0
            var starts: [Int] = []
            var lengths: [Int] = []
            for _ in 0..<repeatCount {
                let samples = rawGenerate(tts, text: text, sid: voice.sid, speed: speed, silenceScale: 0.2)
                let run = inspect(samples)
                if run.nanCount + run.infCount == 0 {
                    good += 1
                } else if let first = run.runs.first {
                    starts.append(first.start)
                    lengths.append(first.length)
                }
            }
            let startText = starts.isEmpty ? "-" : "\(Set(starts).sorted().first ?? 0)..\(Set(starts).sorted().last ?? 0)"
            let lengthText = lengths.isEmpty
                ? "-"
                : "\(fmt(Double(Set(lengths).sorted().first ?? 0) / 24, 0))-\(fmt(Double(Set(lengths).sorted().last ?? 0) / 24, 0))ms"
            print(pad(voice.name, 12) + pad("@\(fmt(speed, 2))", 8) + pad(text, 40)
                + rpad("\(good)/\(repeatCount)", 7) + pad(startText, 11) + lengthText)
        }
    }
}
