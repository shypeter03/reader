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

/// 模型的一次逐句输出。只有朗读参数：type / speaker 不在这里——「这句是谁说的」
/// 由 `FastChapterAnalyzer` 的规则决定，模型那 0.6B 会凭空造人名（真机上把整批
/// 都标成对白、说话人写成「灵」「人体」），而说话人直接决定用哪把声音，错了比不填更糟。
/// speed / pitch 也不在：它们由 `Emotion` 查表得到。
struct AIAnalyzedSentence: Codable, Sendable {

    let index: Int

    let emotion: Emotion

    let emotionIntensity: Double

    /// 整句目标声音力度（饱满/有支撑），与 emotionIntensity 独立
    let voiceStrength: Double

    init(
        index: Int,
        emotion: Emotion,
        emotionIntensity: Double,
        voiceStrength: Double
    ) {
        self.index = index
        self.emotion = emotion
        self.emotionIntensity = emotionIntensity
        self.voiceStrength = voiceStrength
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        index = try container.decode(Int.self, forKey: .index)
        emotion = try container.decode(Emotion.self, forKey: .emotion)
        emotionIntensity = try container.decodeIfPresent(
            Double.self, forKey: .emotionIntensity
        ) ?? emotion.defaultIntensity
        voiceStrength = try container.decodeIfPresent(Double.self, forKey: .voiceStrength)
            ?? emotion.defaultVoiceStrength
    }
}
