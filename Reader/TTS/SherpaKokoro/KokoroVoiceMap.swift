//
//  KokoroVoiceMap.swift
//  Reader
//
//  上游的 voiceID 是 **Qwen3-TTS 的 speaker 名**（Uncle_Fu / Ryan / Vivian…）。
//  Kokoro 不认这些名字：它只认 voices.bin 里的整数 sid。所以这里做一层独立映射，
//  不改动 VoiceManager，也不假设两边同名。
//
//  映射一律发生在「当前模型的声音表」上（``KokoroTTSEngine/voices``），因为
//  v1_0（54 把，`zm_yunyang` 这类名字）和 v1_1（103 把，中文是 `zf_001`…`zm_100`
//  编号名）之间 sid 与名字都不通用。表里没有preferred名字时，退化到「同一性别的
//  第一把声音」，保证性别不会错，音色则可能换人——换模型本来就要重听一遍。
//

import Foundation
import SherpaKokoroKit

enum KokoroVoiceMap {

    /// Qwen3 speaker → 想要的 Kokoro 声音名，按优先级排列。
    ///
    /// 旁白这一档的口径是**小说旁白**，不是「亮 / 中气足」：先要三句不吐 NaN，
    /// 再要低沉（基频低）、稳（句间基频落差小）、不沙（谐波噪声比高），
    /// 由 `kokoro-probe voices --sort narration` 全量测出来；
    /// 最后还得过一遍语速轴——`kokoro-probe rate --speeds 0.7,1.0,1.3`，
    /// 因为 App 能把语速拉到 1.3，而 int8 在 1.3 最容易把整句推成 NaN（从第 0 个采样起坏，
    /// 也就是整句报废、只能降级到 Edge）。
    /// 上一版按「更亮、中气足」选的 zm_020(sid 66) 基频 191Hz（本组中位数 131），
    /// 干净（HNR 6.7）但偏尖偏冲，念旁白不像旁白；它后面那版 zm_029 低沉达标
    /// （F0 103Hz、RMS 0.123），却在 1.3 下把「你好，欢迎来到这个世界。」整句推成 NaN，
    /// 所以再退。
    /// 后面的 v1_0 旧名和「同性别兜底」是为了换模型时不至于掉回英文声音或变性，
    /// 音色则可能换人——换模型本来就要重听一遍。
    private static let preferences: [String: [String]] = [
        // 旁白：zm_098 基频 98Hz（全组最低）、质心 772Hz（沉但不糊）、RMS 0.089、抖 7Hz，
        // 三档语速 × 五句全干净。备选 zm_033 最低最厚（质心仅 584Hz，有发闷风险）。
        // zm_034 全组最稳（抖 1Hz）但同样在 1.3 吐 NaN，只作名字缺失时的兜底。
        "Uncle_Fu": ["zm_098", "zm_033", "zm_034", "zm_yunyang"],
        "Ryan": ["zm_054", "zm_yunjian"],       // 无角色男声：标准普通话、清晰
        "Aiden": ["zm_065", "zm_yunxi"],
        "Dylan": ["zm_091", "zm_yunxi"],        // 年轻男声（Qwen3 里带京腔，Kokoro 无对应口音）
        "Eric": ["zm_052", "zm_yunxia"],        // 成年男声（Qwen3 里带川腔，同上）
        "Vivian": ["zf_042", "zf_xiaoxiao"],    // 年轻女声
        "Serena": ["zf_044", "zf_xiaobei"],     // 成熟女声：RMS 最高，最"中气足"
    ]

    /// 这些 Qwen3 speaker 是男是女——只用于「preferred 名字不存在时别选错性别」。
    private static let genderHint: [String: KokoroVoiceGender] = [
        "Uncle_Fu": .male,
        "Ryan": .male,
        "Aiden": .male,
        "Dylan": .male,
        "Eric": .male,
        "Vivian": .female,
        "Serena": .female,
    ]

    /// 当前表里可用的中文男声/女声。
    private static func chinesePool(_ voices: [KokoroVoice], gender: KokoroVoiceGender)
        -> [KokoroVoice] {
        let pool = voices.chinese(gender: gender)
        return pool.isEmpty ? voices.chinese : pool
    }

    /// 未登记的角色名按 key 稳定散列进中文池：同一个角色整本书同一把声音。
    static func voice(for voiceID: String, in voices: [KokoroVoice]) -> KokoroVoice? {
        guard !voices.isEmpty else { return nil }

        let trimmed = voiceID.trimmingCharacters(in: .whitespacesAndNewlines)
        let preferred = preferences[trimmed] ?? []

        if let hit = voices.first(named: preferred) { return hit }

        let gender = genderHint[trimmed] ?? .male
        let pool = chinesePool(voices, gender: gender)
        if preferred.isEmpty {
            // 没登记过的角色名（多半是上层直接给了 character 名）：稳定散列分配。
            return pool.stableVoice(for: trimmed) ?? pool.first
        }
        // 登记过但当前模型没有那把声音：同性别里取固定一把，保持身份稳定。
        return pool.first
    }

    /// 设置页/诊断用：当前模型下每个 Qwen3 speaker 实际落到哪把声音。
    static func resolvedSidSummary(for voices: [KokoroVoice]) -> String {
        preferences.keys.sorted().map { name in
            guard let voice = voice(for: name, in: voices) else {
                return "\(name)→(无可用声音)"
            }
            let wanted = preferences[name] ?? []
            let mark = wanted.contains(voice.name) ? "" : "≈"   // ≈ = 首选不在该模型里
            return "\(name)→\(mark)\(voice.name)(sid \(voice.sid))"
        }.joined(separator: " ")
    }
}
