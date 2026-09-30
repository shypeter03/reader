//
//  ReadContainer.swift
//  Reader
//

import Foundation
import SherpaKokoroKit
import UIKit

/// 进程级的「现在在后台吗」。
///
/// 为什么要单独记一份，而不是信 SwiftUI 的 `scenePhase`：MLX 在后台提交 Metal command
/// buffer 时，驱动回调抛的是 C++ `std::runtime_error`
/// （"Insufficient Permission (to submit GPU work from background)"），Swift 的
/// `catch` 抓不住它，进程直接 `std::terminate`。唯一的活路是**提交之前就不提交**，
/// 于是每个会跑 GPU 的入口都要就地问一句。
///
/// 状态是一个加锁的 Bool，读它不需要 `await`：守卫一旦让出线程，该提交推理的照样提交了。
/// 初始值直接问 `applicationState`，所以「被系统直接拉进后台」（后台音频、推送拉起）
/// 那一类冷启动也是对的。
final class AppBackgroundGate: @unchecked Sendable {

    static let shared = AppBackgroundGate()

    var isBackground: Bool {
        lock.lock()
        defer { lock.unlock() }
        return background
    }

    private let lock = NSLock()
    private var background = false
    private var observers: [NSObjectProtocol] = []
    private var observing = false

    private init() {}

    /// 由组合根在启动时调一次。通知回调跑在主队列上，但写的是这把锁保护的 Bool，
    /// 不依赖任何 actor，所以赋值在回调返回前就完成了。
    func startObserving() {
        lock.lock()
        guard !observing else { lock.unlock(); return }
        observing = true
        background = UIApplication.shared.applicationState == .background
        lock.unlock()

        let center = NotificationCenter.default
        observers = [
            (UIApplication.didEnterBackgroundNotification, true),
            (UIApplication.willEnterForegroundNotification, false),
        ].map { name, isBackground in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.set(isBackground)
            }
        }
    }

    private func set(_ background: Bool) {
        lock.lock()
        self.background = background
        lock.unlock()
    }

    /// GPU 入口的统一守卫：在后台就抛一个 **Swift 能抓住**的错误，绝不让 MLX 摸到 Metal。
    static func ensureForeground() throws {
        guard !shared.isBackground else {
            throw AIError.backgroundHalted
        }
    }
}

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

        // 后台门禁的状态源，必须在任何一次推理之前装好。
        AppBackgroundGate.shared.startObserving()

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

        // MARK: - TTS 外层（三后端 + 顺位降级 + 热加载/卸载）

        // 这里不再按后端挑实现：外层自己读设置、自己排顺位、每句复核一次「用户是不是换了」。
        // 所以换后端不需要 ⌘R 重来，缺哪一家的权重也只是那条链上少一格。
        let ttsService = FallbackTTSService()

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
                chapterStore: chapterStore,
                // 一次只喂一个分析批次：两个 worker 会把 KV 峰值叠成两份，
                // 而解析已经排在整个后台跑，多一倍并发换不来用户能感知的速度。
                analysisWorkerCount: 1
            )
    }
}
