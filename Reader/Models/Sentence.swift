//
//  Sentence.swift
//  Reader
//
//  Created by 粟海洋 on 2026/8/26.
//

import Foundation

enum SpeakerType: String, Codable, Sendable {
    case narrator
    case character
}

enum SentenceType: String, Codable, Sendable {
    case narration
    case dialogue
}

enum SentenceAnalysisStatus: String, Codable, Sendable { case pending, running, completed, failed }
enum SentenceAudioStatus: String, Codable, Sendable { case pending, running, completed, failed }

struct Sentence: Identifiable, Codable, Sendable {

    let id: UUID

    var index: Int

    var text: String

    var type: SentenceType

    var speaker: SpeakerType

    var characterID: UUID?

    var characterName: String?

    var emotion: Emotion

    var emotionIntensity: Double

    /// 整句目标声音力度：饱满、有支撑的程度。与 emotionIntensity 独立——
    /// 悲伤/平静只压低语气，不该把声音做成气声。
    var voiceStrength: Double

    var speed: Double

    var pitch: Double

    var audioURL: URL?

    var duration: Double?

    var analysisStatus: SentenceAnalysisStatus
    var audioStatus: SentenceAudioStatus

    init(
        id: UUID = UUID(),
        index: Int,
        text: String,
        type: SentenceType = .narration,
        speaker: SpeakerType = .narrator,
        characterID: UUID? = nil,
        characterName: String? = nil,
        emotion: Emotion = .neutral,
        emotionIntensity: Double = Emotion.neutral.defaultIntensity,
        speed: Double = Emotion.neutral.defaultSpeed,
        pitch: Double = Emotion.neutral.defaultPitch,
        voiceStrength: Double = Emotion.neutral.defaultVoiceStrength
    ) {
        self.id = id
        self.index = index
        self.text = text
        self.type = type
        self.speaker = speaker
        self.characterID = characterID
        self.characterName = characterName
        self.emotion = emotion
        self.emotionIntensity = emotionIntensity
        self.speed = speed
        self.pitch = pitch
        self.voiceStrength = voiceStrength
        self.analysisStatus = .pending
        self.audioStatus = .pending
    }

    init(
        index: Int,
        text: String,
        chapterIndex: Int
    ) {
        self.id = Self.deterministicID(
            chapterIndex: chapterIndex,
            sentenceIndex: index
        )
        self.index = index
        self.text = text
        self.type = .narration
        self.speaker = .narrator
        self.characterID = nil
        self.characterName = nil
        self.emotion = .neutral
        self.emotionIntensity = Emotion.neutral.defaultIntensity
        self.speed = Emotion.neutral.defaultSpeed
        self.pitch = Emotion.neutral.defaultPitch
        self.voiceStrength = Emotion.neutral.defaultVoiceStrength
        self.analysisStatus = .pending
        self.audioStatus = .pending
    }

    enum CodingKeys: String, CodingKey {
        case id, index, text, type, speaker, characterID, characterName, emotion
        case emotionIntensity, speed, pitch, voiceStrength
        case audioURL, duration, analysisStatus, audioStatus
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        index = try c.decode(Int.self, forKey: .index)
        text = try c.decode(String.self, forKey: .text)
        type = try c.decodeIfPresent(SentenceType.self, forKey: .type) ?? .narration
        speaker = try c.decodeIfPresent(SpeakerType.self, forKey: .speaker) ?? .narrator
        characterID = try c.decodeIfPresent(UUID.self, forKey: .characterID)
        characterName = try c.decodeIfPresent(String.self, forKey: .characterName)
        emotion = try c.decodeIfPresent(Emotion.self, forKey: .emotion) ?? .neutral
        emotionIntensity = try c.decodeIfPresent(Double.self, forKey: .emotionIntensity)
            ?? emotion.defaultIntensity
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? emotion.defaultSpeed
        pitch = try c.decodeIfPresent(Double.self, forKey: .pitch) ?? emotion.defaultPitch
        // 旧版 chapter.json 没有这个字段：按情绪给足支撑，别退回虚弱的默认值
        voiceStrength = try c.decodeIfPresent(Double.self, forKey: .voiceStrength)
            ?? emotion.defaultVoiceStrength
        audioURL = try c.decodeIfPresent(URL.self, forKey: .audioURL)
        duration = try c.decodeIfPresent(Double.self, forKey: .duration)
        analysisStatus = try c.decodeIfPresent(SentenceAnalysisStatus.self, forKey: .analysisStatus) ?? .pending
        audioStatus = try c.decodeIfPresent(SentenceAudioStatus.self, forKey: .audioStatus) ?? (audioURL == nil ? .pending : .completed)
    }

    private static func deterministicID(
        chapterIndex: Int,
        sentenceIndex: Int
    ) -> UUID {
        let seed = "\(chapterIndex)-\(sentenceIndex)"
        let hash = seed.utf8.reduce(into: UInt64(0)) {
            $0 = $0 &* 31 &+ UInt64($1)
        }
        return UUID(
            uuid: uuid_t(
                UInt8((hash >> 56) & 0xFF),
                UInt8((hash >> 48) & 0xFF),
                UInt8((hash >> 40) & 0xFF),
                UInt8((hash >> 32) & 0xFF),
                UInt8((hash >> 24) & 0xFF),
                UInt8((hash >> 16) & 0xFF),
                UInt8((hash >> 8) & 0xFF),
                UInt8(hash & 0xFF),
                UInt8((hash >> 56) & 0xFF),
                UInt8((hash >> 48) & 0xFF),
                UInt8((hash >> 40) & 0xFF),
                UInt8((hash >> 32) & 0xFF),
                UInt8((hash >> 24) & 0xFF),
                UInt8((hash >> 16) & 0xFF),
                UInt8((hash >> 8) & 0xFF),
                UInt8(hash & 0xFF)
            )
        )
    }
}
