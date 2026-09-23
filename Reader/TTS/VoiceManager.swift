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

    /// 所有「没有具体角色」的说话人（对白没写出说话人、人物性别未知）共用这把
    /// 固定声音：磁性成年男声、标准普通话。同一个声音 = 同一个身份，
    /// 用户不必每句重新适应「这人是谁」。
    private static let unnamedSpeaker = "Ryan"

    // MARK: - Voice Selection

    static func voiceForCharacter(
        gender: Gender,
        age: AgeType,
        bookID: UUID
    ) -> String {

        switch gender {

        case .male:
            return selectMaleSpeaker(age: age)

        case .female:
            return selectFemaleSpeaker(age: age)

        case .unknown:
            return unnamedSpeaker
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

    // MARK: - Speaker Selection by Age

    private static func selectMaleSpeaker(age: AgeType) -> String {

        switch age {

        case .child, .young:
            return "Dylan"

        case .adult, .middleAged:
            return "Eric"

        case .old:
            return "Uncle_Fu"

        case .unknown:
            return "Dylan"
        }
    }

    private static func selectFemaleSpeaker(age: AgeType) -> String {

        switch age {

        case .child, .young:
            return "Vivian"

        case .adult, .middleAged, .old:
            return "Serena"

        case .unknown:
            return "Vivian"
        }
    }

    /// 一句话最终由哪个说话人朗读。调度器也比它：换了说话人就必须重录。
    static func resolvedVoice(for sentence: Sentence, in chapter: Chapter, bookID: UUID) -> String {
        TTSGenerator.resolveVoiceID(
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
