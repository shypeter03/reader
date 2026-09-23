//
//  AIAnalysisResult.swift
//  Reader
//
//  Created by 粟海洋 on 2026/8/27.
//

import Foundation

struct AIAnalysisResult: Codable, Sendable {

    let sentences: [AIAnalyzedSentence]
}

struct AIAnalyzedSentence: Codable, Sendable {

    let id: UUID?

    let index: Int

    /// narration / dialogue
    let type: SentenceType

    /// narrator / character
    let speaker: SpeakerType

    /// 如果 speaker == character
    /// 这里保存人物名称
    let characterName: String?

    let emotion: Emotion

    let emotionIntensity: Double

    /// 整句目标声音力度（饱满/有支撑），与 emotionIntensity 独立
    let voiceStrength: Double

    let speed: Double

    let pitch: Double

    init(
        id: UUID? = nil,
        index: Int,
        type: SentenceType,
        speaker: SpeakerType,
        characterName: String?,
        emotion: Emotion,
        emotionIntensity: Double,
        speed: Double,
        pitch: Double,
        voiceStrength: Double
    ) {
        self.id = id
        self.index = index
        self.type = type
        self.speaker = speaker
        self.characterName = characterName
        self.emotion = emotion
        self.emotionIntensity = emotionIntensity
        self.speed = speed
        self.pitch = pitch
        self.voiceStrength = voiceStrength
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decodeIfPresent(UUID.self, forKey: .id)
        index = try container.decode(Int.self, forKey: .index)
        type = try container.decode(SentenceType.self, forKey: .type)

        if let speakerValue = try container.decodeIfPresent(SpeakerType.self, forKey: .speaker) {
            speaker = speakerValue
        } else {
            speaker = .narrator
        }

        characterName = try container.decodeIfPresent(String.self, forKey: .characterName)
        emotion = try container.decode(Emotion.self, forKey: .emotion)
        emotionIntensity = try container.decodeIfPresent(
            Double.self, forKey: .emotionIntensity
        ) ?? emotion.defaultIntensity
        speed = try container.decodeIfPresent(Double.self, forKey: .speed)
            ?? emotion.defaultSpeed
        pitch = try container.decodeIfPresent(Double.self, forKey: .pitch)
            ?? emotion.defaultPitch
        voiceStrength = try container.decodeIfPresent(Double.self, forKey: .voiceStrength)
            ?? emotion.defaultVoiceStrength
    }
}
