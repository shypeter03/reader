//
//  AIService.swift
//  Reader
//
//  Created by 粟海洋 on 2026/8/26.
//

import Foundation

protocol AIService: Sendable {

    func analyzeChapter(
        _ chapter: Chapter,
        context: StoryContext?
    ) async throws -> ChapterAnalysis

    func generate(
            prompt: String
        ) async throws -> String

    func unload() async
}

struct StoryContext: Sendable {

    var characters: [Character]

    var recentCharacters: [String]

    var recentEvents: [String]
}
