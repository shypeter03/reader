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
    private static let femaleSpeakers = [
        "Vivian",   // 年轻女声
        "Serena",   // 成熟女声
    ]

    private static let maleSpeakers = [
        "Dylan",      // 年轻男声
        "Eric",       // 成年男声
        "Uncle_Fu",   // 年长男声
    ]

    private static let narratorSpeaker = "Uncle_Fu"

    private static let fallbackSpeaker = "Dylan"

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
            return fallbackSpeaker
        }
    }

    static func narratorVoice() -> String {
        narratorSpeaker
    }

    static func fallbackVoice() -> String {
        fallbackSpeaker
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

    // MARK: - Style Prompt (emotion / speed)

    /// 依据情感与语速生成 CustomVoice 的 instruction 文本；
    /// 无特殊风格时返回空串（只保留 speaker）。
    static func stylePrompt(
        emotion: Emotion,
        intensity: Double,
        speed: Double
    ) -> String {

        var parts: [String] = []

        let emotionPhrase = emotionInstruction(emotion)

        if !emotionPhrase.isEmpty {
            // 高强度加程度副词
            if intensity >= 0.7 {
                parts.append("非常\(emotionPhrase)")
            } else {
                parts.append(emotionPhrase)
            }
        }

        if speed <= 0.9 {
            parts.append("语速放慢")
        } else if speed >= 1.1 {
            parts.append("语速加快")
        }

        return parts.joined(separator: "，")
    }

    private static func emotionInstruction(_ emotion: Emotion) -> String {

        switch emotion {

        case .neutral:
            return ""
        case .happy:
            return "开心愉快"
        case .excited:
            return "兴奋激动"
        case .sad:
            return "悲伤低沉"
        case .angry:
            return "愤怒激动"
        case .surprised:
            return "惊讶意外"
        case .fearful:
            return "害怕紧张"
        case .calm:
            return "平静舒缓"
        case .tense:
            return "紧张急促"
        }
    }
}
