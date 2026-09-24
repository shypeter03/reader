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
            sentenceIndex: index,
            text: text
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

    /// 音频缓存的键。**文本必须进种子**：
    /// 只按 (章节, 序号) 算的话，断句规则一改，同一个序号就变成了另一句话，
    /// 旧音频会被原样端上来——表现是「听到的和看到的不是一句」。
    private static func deterministicID(
        chapterIndex: Int,
        sentenceIndex: Int,
        text: String
    ) -> UUID {
        let seed = "\(chapterIndex)-\(sentenceIndex)-\(text)"
        // 两轮不同初值的 FNV-1a 拼出 128 位：截断到 64 位的话，
        // 撞车的两句话会共用一段音频，而且没有任何迹象。
        let low = fnv1a(seed, state: 0xcbf2_9ce4_8422_2325)
        let high = fnv1a(seed, state: 0x9e37_79b9_7f4a_7c15)

        func bytes(_ value: UInt64) -> [UInt8] {
            (0..<8).reversed().map { UInt8((value >> (8 * $0)) & 0xFF) }
        }
        let all = bytes(high) + bytes(low)
        var uuid = uuid_t(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        withUnsafeMutableBytes(of: &uuid) { $0.copyBytes(from: all) }
        // 顶上 version/variant 位，让它是个合法 UUID（导出到别处也不会被判成非法值）
        uuid.6 = (uuid.6 & 0x0F) | 0x50
        uuid.8 = (uuid.8 & 0x3F) | 0x80
        return UUID(uuid: uuid)
    }

    private static func fnv1a(_ text: String, state: UInt64) -> UInt64 {
        var hash = state
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }
}
