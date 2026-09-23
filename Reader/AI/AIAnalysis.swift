//
//  AIAnalysis.swift
//  Reader
//
//  Created by 粟海洋 on 2026/8/26.
//

import Foundation

struct ChapterAnalysis: Codable, Sendable {

    var characters: [AnalyzedCharacter]

    var sentences: [AnalyzedSentence]
}

struct AnalyzedCharacter: Codable, Sendable {

    var name: String

    var gender: Gender

    var age: AgeType

    var description: String?
}

struct AnalyzedSentence: Codable, Sendable {

    var index: Int

    var type: SentenceType

    var speaker: String?

    var emotion: Emotion

    var intensity: Double

    var speed: Double

    var pitch: Double
}
