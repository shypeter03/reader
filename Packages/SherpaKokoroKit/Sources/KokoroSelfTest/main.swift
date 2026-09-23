//
//  main.swift
//  KokoroSelfTest
//
//  最小测试入口：`swift run kokoro-selftest`
//  覆盖：模型加载、中文合成、多 voice、语速、WAV 落盘、耗时/RTF/内存、
//        模型缺失与越界 voice 的错误路径、角色→voice 的稳定性。
//

import Foundation
import SherpaKokoroKit

// MARK: - 内存读数（只为本测试用；不改 Reader 里的 MemoryProbe）

func residentMB() -> Double {
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

func fmt(_ value: Double, _ digits: Int = 2) -> String {
    String(format: "%.\(digits)f", value)
}

func ascii(_ bytes: Data) -> String? {
    String(bytes: bytes, encoding: .ascii)
}

// MARK: - 用例

let text = "你好，欢迎来到这个世界。今天我们一起读一本有趣的小说。"

let outputDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("kokoro-selftest", isDirectory: true)
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

print("=== Kokoro (sherpa-onnx) 自测 ===")
print("CPU 核数=\(ProcessInfo.processInfo.activeProcessorCount) "
    + "residentMB(加载前)=\(fmt(residentMB(), 1))")

// 1) 环境变量指向不存在的目录：不能崩。要么回落到别的有效候选，要么干净抛错。
let bogusEnv = ["SHERPA_KOKORO_MODEL_DIR": "/definitely/not/here/kokoro"]
do {
    let fallback = try KokoroModelLocator.resolveKokoroModelDirectory(env: bogusEnv)
    print("[OK] 坏目录被跳过，回落到 \(fallback.path)")
    print("     共查过 \(KokoroModelLocator.candidateDirectories(env: bogusEnv).count) 个候选目录")
} catch {
    print("[OK] 模型缺失被拒绝（无可用回落）：\(String(describing: error).prefix(80))")
}

// 1b) 环境变量指向有效目录时必须被采纳（路径逐字返回）
if let defaultDir = try? KokoroModelLocator.resolveKokoroModelDirectory(env: [:]) {
    let envOverride = ["KOKORO_MODEL_DIR": defaultDir.path]
    if let override = try? KokoroModelLocator.resolveKokoroModelDirectory(env: envOverride),
       override.path == defaultDir.path {
        print("[OK] 环境变量覆盖生效：\(override.path)")
    } else {
        print("[FAIL] 环境变量覆盖没生效")
    }
}

// 2) 加载（只加载一次，后面所有用例复用同一个实例）
let configuration: KokoroConfiguration
do {
    configuration = try KokoroConfiguration.automatic()
} catch {
    // 模型没装好时这就是 Reader 里 Kokoro 后端应该给出的提示，而不是崩溃。
    print("[FAIL] Kokoro TTS 模型未安装或不可读：\(error)")
    print("       （Qwen3-TTS 不受影响；把模型放到 \(KokoroModelLocator.defaultDirectoryNames[0]) 后重试）")
    exit(1)
}
let engine = KokoroTTSEngine(configuration: configuration)

let memoryBeforeLoad = residentMB()
let report = try await engine.load()
let memoryAfterLoad = residentMB()

print("""
[加载] 目录=\(report.modelDirectory)
       sherpa-onnx=\(report.sherpaOnnxVersion) onnxruntime=\(report.onnxruntimeVersion)
       loadTime=\(fmt(report.loadTime * 1000, 0))ms sampleRate=\(report.sampleRate)Hz \
voices=\(report.speakerCount) threads=\(report.numThreads) lang=\(report.language)
       lexicon=\(report.lexiconFiles.joined(separator: "+")) ruleFST=\(report.ruleFSTCount) 个
       residentMB: \(fmt(memoryBeforeLoad, 1)) -> \(fmt(memoryAfterLoad, 1)) \
(+\(fmt(memoryAfterLoad - memoryBeforeLoad, 1)))
""")

// 3) 多 voice / 语速 / 时长 / RTF
struct Case {
    let label: String
    let voice: KokoroVoice
    let speed: Double?
    let emotion: KokoroEmotion?
}

/// sid 表来自模型 metadata，不是代码常量：下面全部声音都从这张表里取。
let voices = KokoroVoice.table(from: report.speakerNames)
let zhMale = voices.chinese(gender: .male)
let zhFemale = voices.chinese(gender: .female)
print("""
[声音表] 由 model metadata 解析：\(voices.count) 条（引擎报 \(report.speakerCount)）\
 中文男 \(zhMale.count) / 中文女 \(zhFemale.count)
        sid 0=\(voices.first?.name ?? "?") … sid \(voices.count - 1)=\(voices.last?.name ?? "?")
        旁白取 \(zhMale.first?.name ?? "?")(sid \(zhMale.first?.sid ?? -1))，\
 女声取 \(zhFemale.first?.name ?? "?")(sid \(zhFemale.first?.sid ?? -1))
""")

guard let narrator = zhMale.first, let female = zhFemale.first,
      let secondMale = zhMale.dropFirst().first ?? zhMale.last else {
    print("[FAIL] 模型里没有中文男/女声，无法测 voice 切换")
    exit(1)
}

let cases: [Case] = [
    Case(label: "旁白-默认速", voice: narrator, speed: nil, emotion: nil),
    Case(label: "女声-默认速", voice: female, speed: nil, emotion: nil),
    Case(label: "男声备选-默认速", voice: secondMale, speed: nil, emotion: nil),
    Case(label: "旁白-慢0.85", voice: narrator, speed: 0.85, emotion: nil),
    Case(label: "旁白-快1.15", voice: narrator, speed: 1.15, emotion: nil),
    Case(label: "旁白-sad映射", voice: narrator, speed: 1.0, emotion: .sad),
    Case(label: "越界夹取3.0", voice: narrator, speed: 3.0, emotion: nil),
]

var totalGeneration = 0.0
var totalAudio = 0.0
var failures = 0
var firstGeneration = 0.0

for (offset, testCase) in cases.enumerated() {
    let wallStart = CFAbsoluteTimeGetCurrent()
    do {
        let speed: Double?
        if let emotion = testCase.emotion {
            speed = emotion.applySpeed(testCase.speed ?? 1.0)
        } else {
            speed = testCase.speed
        }

        let result = try await engine.generate(text: text, voice: testCase.voice, speed: speed)
        let wall = CFAbsoluteTimeGetCurrent() - wallStart
        let metrics = result.metrics
        let wav = result.audio.wavData()

        if offset == 0 { firstGeneration = metrics.generationTime }
        totalGeneration += metrics.generationTime
        totalAudio += metrics.audioDuration

        let name = String(format: "%02d-%@-%@.wav", offset, testCase.voice.name, testCase.label)
        let url = outputDirectory.appendingPathComponent(name)
        try wav.write(to: url)

        let riff = ascii(wav.prefix(4)) == "RIFF"
        let audible = result.audio.peakAmplitude > 0.01
        let sane = riff && audible
        if !sane { failures += 1 }

        print("""
        [\(sane ? "OK" : "FAIL")] \(testCase.label) voice=\(testCase.voice.name)(sid \(metrics.voice.sid)) \
        speed=\(fmt(metrics.requestedSpeed))→\(fmt(metrics.appliedSpeed)) \
        audio=\(fmt(metrics.audioDuration))s gen=\(fmt(metrics.generationTime * 1000, 0))ms \
        墙钟=\(fmt(wall * 1000, 0))ms RTF=\(fmt(metrics.rtf)) \
        peak=\(fmt(Double(result.audio.peakAmplitude), 3)) bytes=\(wav.count) \
        RIFF=\(riff ? "✓" : "✗")
        """)
    } catch {
        failures += 1
        print("[FAIL] \(testCase.label): \(error)")
    }
}

// 4) 角色 → voice 的稳定分配（池子 = 当前模型的中文声音）
let pool = voices.chinese
let key = "5B1C0E3F-0000-0000-0000-00000000000A"
let first = pool.stableVoice(for: key)?.sid ?? -1
let second = pool.stableVoice(for: key)?.sid ?? -2
let other = pool.stableVoice(for: "5B1C0E3F-0000-0000-0000-00000000000B")?.sid ?? -3
print("[\(first == second && first >= 0 ? "OK" : "FAIL")] 角色→voice 稳定：A=\(first) A'=\(second) B=\(other) "
    + "（中文池 \(pool.count) 个）")
if first != second || first < 0 { failures += 1 }

// 4b) sid 合法但名字不属于这个模型 —— 必须拒绝，否则换模型会静默换嗓
do {
    let impostor = KokoroVoice(sid: narrator.sid, name: narrator.name + "_not_in_model")
    _ = try await engine.generate(text: text, voice: impostor)
    print("[FAIL] 名字对不上的 voice 没有被拒绝")
    failures += 1
} catch let error as KokoroTTSError {
    if case .speakerNameMismatch = error {
        print("[OK] sid 合法但名字错位被拒绝")
    } else {
        print("[FAIL] 抛了别的错误：\(error)")
        failures += 1
    }
} catch {
    print("[FAIL] 抛了非预期错误：\(error)")
    failures += 1
}

// 5) 越界 sid 必须被 Swift 侧拒绝，不能让 C 层越界读 voices.bin
do {
    _ = try await engine.generate(
        text: text,
        voice: KokoroVoice(sid: report.speakerCount + 500, name: "bogus")
    )
    print("[FAIL] 越界 sid 没有被拒绝")
    failures += 1
} catch let error as KokoroTTSError {
    if case .invalidVoice = error {
        print("[OK] 越界 sid 被拒绝")
    } else {
        print("[FAIL] 越界 sid 抛了别的错误：\(error)")
        failures += 1
    }
} catch {
    print("[FAIL] 越界 sid 抛了非预期错误：\(error)")
    failures += 1
}

print("""
[汇总] 用例=\(cases.count) 失败=\(failures)
       模型加载=\(fmt(report.loadTime * 1000, 0))ms 首次生成=\(fmt(firstGeneration * 1000, 0))ms
       总音频=\(fmt(totalAudio))s 总生成=\(fmt(totalGeneration))s \
平均 RTF=\(fmt(totalGeneration / max(totalAudio, 0.001)))
       输出目录=\(outputDirectory.path)
       residentMB 结束=\(fmt(residentMB(), 1))
""")

await engine.unload()
let loadedAfterUnload = await engine.isLoaded
print("[卸载] unload() 后 isLoaded=\(loadedAfterUnload) residentMB=\(fmt(residentMB(), 1))")
exit(failures == 0 && !loadedAfterUnload ? 0 : 1)
