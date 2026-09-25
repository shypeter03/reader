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

    /// `maxTokens` 由调用方按批量大小给：让模型自己决定什么时候停，等于允许它
    /// 在一批十句上跑进重复循环，KV 一路涨、几十秒才回来。
    func generate(
            prompt: String,
            maxTokens: Int
        ) async throws -> String

    func unload() async
}

struct StoryContext: Sendable {

    var characters: [Character]

    var recentCharacters: [String]

    var recentEvents: [String]
}
