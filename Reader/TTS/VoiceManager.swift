//
//  VoiceManager.swift
//  Reader
//

import Foundation

/// 为 Qwen3-TTS CustomVoice 挑选说话人（speaker）与风格提示（instruction）。
///
/// CustomVoice 通过 `voice = "speaker, instruction"` 控制：
/// - speaker 必须是模型 config.json 里 spk_id 表中的名字（大小写不敏感）；
/// - instruction 用自然语言描述情绪 / 语速。
///
/// 这些 speaker 名同时是**全 App 的声音身份**：``CharacterRoster`` 存它、
/// Edge 用 `speakerAlias` 翻译成神经语音、Kokoro 用 `KokoroVoiceMap.preferences` 翻译成
/// sid。所以「某个人用哪把声音」只在这里定一次，三个后端各自翻译，不许再分叉。
enum VoiceManager {

    // MARK: - CustomVoice Speakers

    // 中文说话人（需与模型 spk_id 表一致）。
    // 注意模型的 spk_is_dialect：Dylan=北京话、Eric=四川话；Uncle_Fu/Ryan/Aiden
    // 才是标准普通话，所以「无口音、吐字清晰」的固定声音只能从后者里挑。
    private static let femaleSpeakers = [
        "Vivian",   // 年轻女声
        "Serena",   // 成熟女声
    ]

    private static let maleSpeakers = [
        "Dylan",      // 年轻男声（北京腔）
        "Eric",       // 成年男声（四川腔）
        "Uncle_Fu",   // 年长男声
    ]

    private static let narratorSpeaker = "Uncle_Fu"

    /// 无具体角色的说话人用的固定声音。**只剩系统合成还在用它当「没有角色可选」的标识**：
    /// 朗读侧的无名句一律归到旁白那把嗓（见 ``voiceForCharacter`` 的 `.unknown` 分支），
    /// 因为「这一句旁白 A、下一句旁白 B」正是这条需求禁止的听感，而老数据里那把无名嗓
    /// 就是这一现象的主要来源（真书实测占正文 8~9% 的句子）。
    private static let unnamedSpeaker = "Ryan"

    // MARK: - Named Character Pools

    /// 有名有姓的人物按性别分池，同性别的人可以共用（用户要的只是「别男女不分、
    /// 别同一个人两个嗓」）。旁白的 Uncle_Fu 不在池子里：他要一直当旁白，
    /// 而「判不出性别的人」也归他（见 ``voiceForCharacter`` 的 `.unknown`）。
    /// 池子里的次序一旦定了就别动：换序等于整本书同名人物换嗓，音频全部作废。
    private static let malePool = ["Dylan", "Eric"]
    private static let femalePool = ["Vivian", "Serena"]

    // MARK: - Voice Selection

    /// 这个名字的人在这本书里用哪把声音。
    ///
    /// 纯函数：只由（名字、性别）决定，不看章序、不看档案里还有谁。所以「第 30 章
    /// 才出场的人物」不会把第 1 章那位挤到另一把嗓上——那正是「同一个人两句对话
    /// 两个声音」的来路。
    static func voiceForCharacter(name: String, gender: Gender) -> String {
        switch gender {
        case .male: return stablePick(name, from: malePool)
        case .female: return stablePick(name, from: femalePool)
        // 判不出性别的人**不给一把新嗓**：由旁白念。
        //
        // 原来这里落到无名嗓 Ryan，那是「旁白换人」最大的一处来源——真书实测有一到两成的
        // 句子落在「有引号、认不出是谁说的」这一桶里（绍宋 1129/6447、赘婿 998、庆余年 538），
        // 每一句都是一次 Uncle_Fu → Ryan → Uncle_Fu 的来回换人，听感正是「这一句旁白 A 说、
        // 下一句旁白 B 说」。需求里「应该区分出男女」的反面读法就是**分不清男女就不分**：
        // 宁可由旁白念，也不在叙述中间插一把来路不明的嗓。
        // 认得出男女的人照旧各钉一把、全书不变（那条要求没动）。
        case .unknown: return narratorSpeaker
        }
    }

    static func narratorVoice() -> String {
        narratorSpeaker
    }

    /// 无具体角色的说话人用的固定声音。
    static func unnamedVoice() -> String {
        unnamedSpeaker
    }

    /// 这句话是不是由「无角色固定声音」来读——决定要不要额外要求吐字清晰。
    static func isUnnamedVoice(_ voiceID: String) -> Bool {
        voiceID == unnamedSpeaker
    }

    /// 名字 → 池内一把，FNV-1a 取模：同一个名字永远落在同一个下标。
    private static func stablePick(_ name: String, from pool: [String]) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in name.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return pool[Int(hash % UInt64(pool.count))]
    }

    /// 一句话最终由哪个说话人朗读。调度器也比它：换了说话人就必须重录。
    static func resolvedVoice(for sentence: Sentence, in chapter: Chapter, bookID: UUID) -> String {
        VoiceResolution.resolve(
            sentence: sentence,
            chapter: chapter,
            bookID: bookID
        )
    }

    // MARK: - Style Prompt (emotion / speed / pitch / voiceStrength)

    /// 依据语音规划参数生成 CustomVoice 的 instruction 文本。
    ///
    /// voiceStrength / speed / pitch 不是模型的原生参数，只能作为「规划值」，
    /// 在这里翻译成自然语言。措辞必须带上「整句一致」，否则「语速放慢」会被
    /// 理解成越读越慢、「低沉」会被读成越读越轻——就是句尾泄气的直接来源。
    static func stylePrompt(
        emotion: Emotion,
        intensity: Double,
        speed: Double,
        pitch: Double,
        voiceStrength: Double
    ) -> String {

        var parts: [String] = []

        let emotionPhrase = emotionInstruction(emotion)

        if emotion == .neutral {
            parts.append(emotionPhrase)
        } else if intensity >= 0.7 {
            parts.append("情绪强烈，\(emotionPhrase)")
        } else if intensity <= 0.3 {
            parts.append("情绪轻微，\(emotionPhrase)")
        } else {
            parts.append(emotionPhrase)
        }

        if speed >= 1.06 {
            parts.append("整句语速稍快、全程均匀")
        } else if speed <= 0.94 {
            parts.append("整句语速稍慢、全程均匀，不要越读越慢")
        }

        if pitch >= 0.05 {
            parts.append("整句音调略高")
        } else if pitch <= -0.04 {
            parts.append("整句音调略低，但音量不随之变小")
        }

        parts.append(
            voiceStrength >= 0.9
                ? "声音饱满有力、中气充足"
                : "声音饱满、有支撑、中气充足"
        )

        parts.append(stabilityRule)

        return parts.joined(separator: "；")
    }

    /// 每句必带的稳定约束。
    private static let stabilityRule =
        "整句话保持统一稳定的语气、音量、气息、语速和音调，句首到句尾力度一致；不要中途突然降低音量、压低声音、放慢语速或改变音调；不要因悲伤、紧张、低沉等情绪让声音变得虚弱、发虚或气若游丝；句尾不要泄气、变轻、变慢；情绪自然表达但整句情绪强度保持连贯"

    /// 只加给「无角色固定声音」：它充当全书的默认讲述声，咬字必须交代清楚。
    static let clarityRule =
        "吐字清晰、字正腔圆，每个字都发音完整到位，不含糊、不吞字、不带方言腔调"

    /// 每档只描述「这一档最容易读错的地方」。饱满、有支撑、句尾不泄气由
    /// voiceStrength 子句与 stabilityRule 统一负责，不在这里重复。
    private static func emotionInstruction(_ emotion: Emotion) -> String {

        switch emotion {

        case .neutral:
            return "自然、平稳、清晰"
        case .happy:
            return "开心、明亮、有感染力"
        case .excited:
            return "兴奋、明亮、有活力"
        case .sad:
            return "悲伤而克制，低沉来自语气而不是音量变小"
        case .angry:
            return "愤怒、有压迫感、语气坚定"
        case .surprised:
            return "惊讶、语气明亮"
        case .fearful:
            return "恐惧、不安，但声音清晰稳定、不失支撑"
        case .calm:
            return "平静、稳定，不用气声"
        case .tense:
            return "紧张、有紧迫感，但声音不发虚"
        }
    }
}
