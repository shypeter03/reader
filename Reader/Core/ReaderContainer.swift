//
//  ReadContainer.swift
//  Reader
//

import Foundation
import SherpaKokoroKit

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

        // MARK: - Local Neural TTS（两套后端并列；默认 Kokoro）

        var engineType = TTSEngineType.current

        // 默认后端换了，但 Kokoro 的权重在 App 之外：没装就退回 Qwen3-TTS，
        // 否则整本书一句音频都出不来。
        if engineType.usesKokoro,
           SherpaKokoroTTSService.modelDirectoryIfAvailable() == nil {
            print("⚠️ [TTS] 选择了 Kokoro，但未找到模型目录，本次退回 Qwen3-TTS。")
            print("        正常打包时权重由 folder reference 在 build 阶段拷进 App；"
                  + "没打进来就把 \(KokoroModelLocator.preferredDirectoryName) 放到"
                  + "\(KokoroModelLocator.externalDirectoryNameHint)，重启生效。")
            engineType = .qwen3
        }

        let ttsService: TTSService
        let audioNamespace: String?

        switch engineType {

        case .sherpaKokoro:
            // 降级链：Kokoro 优先，它抛错才轮到 Edge。Kokoro 的权重在 App 之外，
            // 可能没拷进来 / 内存不足建不起引擎 / 单句推理出问题，任何一种都不该
            // 让整章一句都读不出来。
            ttsService = FallbackTTSService(
                primary: SherpaKokoroTTSService(),
                backup: EdgeTTSService()
            )
            audioNamespace = SherpaKokoroTTSService.audioNamespace

        case .qwen3:
            // 不传命名空间 → 磁盘缓存路径与以前逐字节一致。
            ttsService = Qwen3TTSService()
            audioNamespace = nil
        }

        let namespaceLabel = audioNamespace ?? "(默认)"
        print("[TTS] 后端=\(engineType.rawValue) 缓存子目录=\(namespaceLabel)")

        let audioStore =
            AudioStore()

        let chapterStore =
            ChapterStore()

        let generator =
            TTSGenerator(
                tts: ttsService,
                audioStore: audioStore,
                audioNamespace: audioNamespace
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
