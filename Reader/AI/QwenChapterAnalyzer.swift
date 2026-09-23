//
//  QwenChapterAnalyzer.swift
//  Reader
//
//  Created by 粟海洋 on 2026/8/27.
//

//import Foundation
//
//actor QwenChapterAnalyzer: ChapterAnalyzer {
//
//    private let qwen: MLXQwenService
//
//    init(
//        qwen: MLXQwenService
//    ) {
//        self.qwen = qwen
//    }
//
//    override func analyze(
//        chapter: Chapter,
//        context: StoryContext
//    ) async throws -> Chapter {
//
//        let analysis =
//            try await qwen.analyzeChapter(
//                chapter,
//                context: context
//            )
//
//        var result = chapter
//
//        // 后面这里负责把：
//        //
//        // ChapterAnalysis
//        //
//        // 转换成：
//        //
//        // Chapter
//        //
//        // 包括：
//        // characters
//        // speaker
//        // emotion
//        // speed
//        // pitch
//
//        result.characters =
//            analysis.characters.map {
//                Character(
//                    name: $0.name,
//                    gender: $0.gender,
//                    age: $0.age,
//                    description: $0.description
//                )
//            }
//
//        for index in result.sentences.indices {
//
//            guard
//                let analyzed =
//                    analysis.sentences.first(
//                        where: {
//                            $0.index ==
//                            result.sentences[index].index
//                        }
//                    )
//            else {
//                continue
//            }
//
//            result.sentences[index].type =
//                analyzed.type
//
//            result.sentences[index].emotion =
//                analyzed.emotion
//
//            result.sentences[index].emotionIntensity =
//                analyzed.intensity
//
//            result.sentences[index].speed =
//                analyzed.speed
//
//            result.sentences[index].pitch =
//                analyzed.pitch
//
//            if let speaker =
//                analyzed.speaker {
//
//                result.sentences[index]
//                    .characterName = speaker
//
//                if let character =
//                    result.characters.first(
//                        where: {
//                            $0.name == speaker
//                        }
//                    ) {
//
//                    result.sentences[index]
//                        .characterID =
//                        character.id
//
//                    result.sentences[index]
//                        .speaker =
//                        .character
//                }
//            }
//        }
//
//        return result
//    }
//}
