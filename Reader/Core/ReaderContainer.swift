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

        // MLX allocator 默认会把整台设备的内存上限都当成可缓存池，8GB 设备上
        // 光 cached 就能堆到 4G+。在加载任何权重前先把 cacheLimit 压下来。
        MemoryProbe.configureCacheLimit()

        // MARK: - AI Analyzer (Qwen3-0.6B)

        let aiService =
            MLXQwenService()

        let analyzer =
            ChapterAnalyzer(ai: aiService)

        // MARK: - Fast Analyzer（正则，开播即用）

        let fastAnalyzer =
            FastChapterAnalyzer()

        // MARK: - Local Neural TTS (Qwen3-TTS 12Hz / swift-qwen3-tts)

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
                fastAnalyzer: fastAnalyzer,
                generator: generator,
                chapterStore: chapterStore
            )
    }
}
