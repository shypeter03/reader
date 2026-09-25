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

        // 旧布局的生成物在新路径下一条都读不到，启动时删一次再往下建 store。
        ReaderCache.migrateLegacyLayoutOnce()

        // 「每次部署都丢内容」的现场取证：三棵树谁在谁不在、是谁刚刚才建的。
        // 要遍历几棵目录树，所以甩到后台，不占启动路径。
        Task.detached(priority: .utility) {
            ReaderCache.logPersistenceDiagnostics()
        }
        // MARK: - AI Analyzer (Qwen3-0.6B)

        let aiService =
            MLXQwenService()

        let analyzer =
            ChapterAnalyzer(ai: aiService)

        // MARK: - Fast Analyzer（正则，开播即用）

        let fastAnalyzer =
            FastChapterAnalyzer()

        // MARK: - TTS 后端（三套并列；默认 Edge 在线合成）

        var engineType = TTSEngineType.current

        // 只有把 Kokoro 摆在主位时，权重缺失才是致命的（整章一句都出不来）。
        // Edge 在主位时 Kokoro 只是兜底，缺了不影响出声，所以这里不动它。
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

        case .edge:
            // 降级链：Edge 优先，它抛错才轮到 Kokoro。Edge 是网络后端，可能没网、
            // 可能被服务端拒（这条链反过来正是 Kokoro 权重缺失时的出路），
            // 所以本地后端留在兜底位，任何一种后端单独坏掉都不该让整章静音。
            ttsService = FallbackTTSService(
                primary: EdgeTTSService(),
                backup: SherpaKokoroTTSService()
            )
            audioNamespace = EdgeTTSService.audioNamespace

        case .sherpaKokoro:
            // 同一条链的反序：Kokoro 优先，Edge 兜底。
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
