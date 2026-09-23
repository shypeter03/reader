//
//  ReadContainer.swift
//  Reader
//

import Foundation

@MainActor
final class ReaderContainer {

    static let shared =
        ReaderContainer()

    let pipeline:
        ReaderPipeline

    private init() {

        // MARK: - AI Analyzer (Qwen3-0.6B)

        let aiService =
            MLXQwenService()

        let analyzer =
            ChapterAnalyzer(ai: aiService)

        // MARK: - Local Neural TTS (Qwen3-TTS lite / swift-qwen3-tts)

        let ttsService =
            Qwen3TTSService()

        let audioStore =
            AudioStore()

        let chapterStore =
            ChapterStore()

        let generator =
            TTSGenerator(
                tts: ttsService,
                audioStore: audioStore
            )

        // MARK: - Pipeline

        pipeline =
            ReaderPipeline(
                analyzer: analyzer,
                generator: generator,
                chapterStore: chapterStore
            )
    }
}
