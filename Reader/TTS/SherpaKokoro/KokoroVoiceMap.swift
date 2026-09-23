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
    /// 第一项是 v1_0 上人工试听选出来的；后面的项和「同性别兜底」是为了换模型时
    /// 不至于掉回英文声音或变性。
    private static let preferences: [String: [String]] = [
        "Uncle_Fu": ["zm_yunyang"],    // 旁白：年长、稳
        "Ryan": ["zm_yunjian"],        // 无角色男声：标准普通话、清晰
        "Aiden": ["zm_yunxi"],
        "Dylan": ["zm_yunxi"],         // 年轻男声（Qwen3 里带京腔，Kokoro 无对应口音）
        "Eric": ["zm_yunxia"],         // 成年男声（Qwen3 里带川腔，同上）
        "Vivian": ["zf_xiaoxiao"],     // 年轻女声
        "Serena": ["zf_xiaobei"],      // 成熟女声
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
