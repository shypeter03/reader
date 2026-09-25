import Foundation

enum EnhancementJobType: String, Codable, Sendable { case analysisBatch, ttsSentence }
enum EnhancementJobState: String, Codable, Sendable { case pending, running, completed, failed }
enum JobPriorityMode: String, Codable, Sendable { case background, interactive }

struct EnhancementJob: Codable, Sendable, Identifiable {
    let id: String; let bookID: UUID; let chapterID: UUID; let type: EnhancementJobType
    let batchIndex: Int?; let sentenceIndex: Int?
    var state: EnhancementJobState; var priority: Int; var mode: JobPriorityMode; var memoryBytes: Int64
    var attempts: Int; let createdAt: Date; var startedAt: Date?; var finishedAt: Date?; var error: String?
}

/// JSON persistence makes pending work survive app termination. Running work is
/// reset to pending on startup because no MLX inference survives process death.
actor EnhancementJobStore {
    private let url: URL; private var jobs: [String: EnhancementJob] = [:]
    init() {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AIReader", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        url = root.appendingPathComponent("enhancement-jobs.json")
        if let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode([String: EnhancementJob].self, from: data) { jobs = decoded }
    }
    func recover() -> [EnhancementJob] {
        for id in jobs.keys where jobs[id]?.state == .running { jobs[id]?.state = .pending; jobs[id]?.startedAt = nil; jobs[id]?.error = "Interrupted by previous app exit" }
        // 旧版本导入时把整本书的分析批次全压进了队列。它们若原样恢复，队列永远非空：
        // 分析 worker 一直有活，LLM 也就永远卸不掉。打开章节时会重新排产，直接丢弃安全。
        var droppedAnalysis = 0
        for (key, job) in jobs where job.type == .analysisBatch && (job.state == .pending || job.state == .failed) {
            jobs[key] = nil; droppedAnalysis += 1
        }
        // 同理，逐句 TTS 任务也是重开的：promote/updateReadingPosition 会按当前播放
        // 位置重新排产。留着它们，worker 会被上次会话留下的别的书的后台音频占满
        // ——单 worker 不能打断在跑的任务，一句被内存压力拖到几十秒时，用户这一章
        // 就在队尾等好几分钟，看起来就是「点开没声音」。
        var droppedTTS = 0
        for (key, job) in jobs where job.type == .ttsSentence && (job.state == .pending || job.state == .failed) {
            jobs[key] = nil; droppedTTS += 1
        }
        if droppedAnalysis > 0 || droppedTTS > 0 {
            print("[Scheduler] 丢弃 \(droppedAnalysis) 个整书预热分析批次、\(droppedTTS) 个遗留逐句音频任务（改为打开章节时按需排产）")
        }
        save(); return jobs.values.filter { $0.state == .pending || $0.state == .failed }
    }
    /// 一句最多自动重录这么多次。没有上限的话，模型稳定合成不了的长句会在每次
    /// 进出章节时再烧掉几十秒 GPU，永远出不来声音——失败必须会停下来。
    static let maxTTSAutoRetries = 3
    func upsert(_ proposed: EnhancementJob) -> EnhancementJob {
        guard var old = jobs[proposed.id] else { jobs[proposed.id] = proposed; save(); return proposed }
        guard old.state == .pending || (old.state == .failed && old.attempts < Self.maxTTSAutoRetries) else { return old }
        old.priority = max(old.priority, proposed.priority); old.mode = proposed.mode == .interactive ? .interactive : old.mode
        old.state = .pending; old.error = nil; jobs[old.id] = old; save(); return old
    }
    func update(_ job: EnhancementJob) { jobs[job.id] = job; save() }
    /// 清完磁盘音频后必须丢掉任务记录：留着 .completed 的话 upsert 认为做过，
    /// 句子永远不会再排产生成音频。
    func dropBook(bookID: UUID) -> Int {
        let before = jobs.count
        for (key, job) in jobs where job.bookID == bookID { jobs[key] = nil }
        let dropped = before - jobs.count
        if dropped > 0 { save() }
        return dropped
    }
    /// 重录：某句音频作废（LLM 改了参数）。已完成的 TTS 任务必须退回 pending，
    /// 否则 upsert 认定它做过，这一句从此静音。
    func reopenTTS(chapterID: UUID, sentenceIndex: Int) {
        var changed = false
        for (key, job) in jobs where job.type == .ttsSentence && job.chapterID == chapterID && job.sentenceIndex == sentenceIndex && job.state == .completed {
            var fresh = job; fresh.state = .pending; fresh.finishedAt = nil; fresh.error = nil; jobs[key] = fresh; changed = true
        }
        if changed { save() }
    }
    /// 与内存队列同步降级：持久层里非当前章节的 interactive 也退回 background。
    func demoteInteractive(except chapterID: UUID) {
        var changed = false
        for (key, job) in jobs where job.chapterID != chapterID && job.mode == .interactive && (job.state == .pending || job.state == .failed) {
            var demoted = job; demoted.mode = .background; demoted.priority = Swift.min(demoted.priority, 100); jobs[key] = demoted; changed = true
        }
        if changed { save() }
    }
    /// 进入章节时把「上次失败但还有自动重试额度」的逐句任务退回 pending，返回这些
    /// 句子的序号：调用方要据此复位句子的 audioStatus，否则播放器看到 .failed 会
    /// 直接跳过，重录成功也听不见。
    func reopenFailedTTS(chapterID: UUID) -> Set<Int> {
        var reopened: Set<Int> = []
        for (key, job) in jobs where job.type == .ttsSentence && job.chapterID == chapterID && job.state == .failed && job.attempts < Self.maxTTSAutoRetries {
            var fresh = job; fresh.state = .pending; fresh.error = nil; fresh.finishedAt = nil; jobs[key] = fresh
            if let i = job.sentenceIndex { reopened.insert(i) }
        }
        if !reopened.isEmpty { save() }
        return reopened
    }
    /// UI「重试」入口：把该章 failed 任务放回 pending 再入队。手动重试重新给满额度。
    func resetFailed(chapterID: UUID) -> [EnhancementJob] {
        var revived: [EnhancementJob] = []
        for (key, job) in jobs where job.chapterID == chapterID && job.state == .failed {
            var fresh = job; fresh.state = .pending; fresh.error = nil; fresh.finishedAt = nil; fresh.attempts = 0; jobs[key] = fresh; revived.append(fresh)
        }
        save(); return revived
    }
    /// 该章 LLM 分析还剩多少批次。快分析只保证「有参数能开播」，
    /// 章级 analysisStatus 必须以真实批次为准，不能用「句子是否都有参数」判断。
    func analysisBatchSummary(chapterID: UUID, excluding jobID: String? = nil) -> (pending: Int, failed: Int) {
        var pending = 0; var failed = 0
        for job in jobs.values where job.chapterID == chapterID && job.type == .analysisBatch && job.id != jobID {
            switch job.state {
            case .pending, .running: pending += 1
            case .failed: failed += 1
            case .completed: break
            }
        }
        return (pending, failed)
    }
    private func save() { guard let data = try? JSONEncoder().encode(jobs) else { return }; try? data.write(to: url, options: .atomic) }
}

/// One admission gate shared by Analysis and TTS. The budget covers expected
/// incremental inference working-set, not immutable model baseline memory.
/// Waiters wake in strict priority order: an interactive job blocked on
/// memory outranks smaller background jobs that could otherwise sneak in.
actor MemoryBudgetManager {
    let budgetBytes: Int64; private var reservedBytes: Int64 = 0
    private var waiters: [(bytes: Int64, priority: Int, cont: CheckedContinuation<Void, Never>)] = []
    init(budgetBytes: Int64 = 2 * 1024 * 1024 * 1024) { self.budgetBytes = budgetBytes }
    var availableBytes: Int64 { max(0, budgetBytes - reservedBytes) }
    var reserved: Int64 { reservedBytes }
    func acquire(_ requested: Int64, priority: Int = 0) async -> Bool {
        // Never silently shrink an oversized estimate: that would admit work
        // known to exceed the configured global budget.
        guard requested > 0, requested <= budgetBytes else { return false }
        if reservedBytes + requested <= budgetBytes { reservedBytes += requested; return true }
        await withCheckedContinuation { waiters.append((requested, priority, $0)) }
        return true
    }
    func release(_ requested: Int64) {
        reservedBytes = max(0, reservedBytes - requested)
        waiters.sort { $0.priority > $1.priority }
        // 队首等不到就全体等待：这就是「内存不足时高优先任务先过」的语义
        while let first = waiters.first, reservedBytes + first.bytes <= budgetBytes {
            waiters.removeFirst()
            reservedBytes += first.bytes
            first.cont.resume()
        }
    }
}

/// No busy loop: sleeping workers suspend through continuations. Re-enqueueing
/// the same key promotes the existing pending job instead of duplicating it.
actor PriorityJobQueue {
    private var pending: [String: EnhancementJob] = [:]
    private var waiters: [CheckedContinuation<EnhancementJob?, Never>] = []
    private var stopped = false
    func enqueue(_ job: EnhancementJob) { guard !stopped else { return }; if var old = pending[job.id] { old.priority = max(old.priority, job.priority); old.mode = job.mode == .interactive ? .interactive : old.mode; pending[job.id] = old } else { pending[job.id] = job }; wake() }
    /// 用户切走后，其他章节遗留的 interactive 任务全部降回后台档，
    /// 不再挤占当前章节的 worker 与内存预算。running 中的任务不动。
    func demoteInteractive(except chapterID: UUID) {
        for (key, job) in pending where job.chapterID != chapterID && job.mode == .interactive {
            var demoted = job; demoted.mode = .background; demoted.priority = Swift.min(demoted.priority, 100); pending[key] = demoted
        }
    }
    func next() async -> EnhancementJob? { if let job = take() { return job }; guard !stopped else { return nil }; return await withCheckedContinuation { waiters.append($0) } }
    /// 还没被 worker 取走的任务数：0 表示分析队列真的空了。
    var pendingCount: Int { pending.count }
    func stop() { stopped = true; waiters.forEach { $0.resume(returning: nil) }; waiters.removeAll() }
    private func wake() { while !waiters.isEmpty, let job = take() { waiters.removeFirst().resume(returning: job) } }
    private func take() -> EnhancementJob? {
        guard let job = pending.values.max(by: { $0.priority == $1.priority ? $0.createdAt > $1.createdAt : $0.priority < $1.priority }) else { return nil }
        pending[job.id] = nil; return job
    }
}

/// 一次「用户打开章节」的实时性追踪（§19.3/§19.15）：T0 点击、
/// T2 该句分析就绪、T3 TTS 开始、T4 音频就绪、T5 播放器起播。
private struct InteractiveRequest {
    let chapterID: UUID
    let chapterIndex: Int
    let sentence: Int
    let t0: Date
    let cacheHit: Bool
    var analysisDoneAt: Date?
    var ttsStartAt: Date?
    var audioReadyAt: Date?
    var playLogged = false
}

actor ReaderPipeline {
    private let analyzer: ChapterAnalyzer; private let fastAnalyzer: FastChapterAnalyzer; private let generator: TTSGenerator; private let chapterStore: ChapterStore
    private let cache = ChapterCache(); private let analysisQueue = PriorityJobQueue(); private let ttsQueue = PriorityJobQueue()
    private let store = EnhancementJobStore(); private let budget: MemoryBudgetManager
    private let analysisWorkers: Int; private let ttsWorkers: Int; private var analysisEstimate: Int64; private var ttsEstimate: Int64
    private let memoryBudgetBytes: Int64
    private var workers: [Task<Void, Never>] = []; private var started = false
    private var watchers: [UUID: [UUID: AsyncThrowingStream<Chapter, Error>.Continuation]] = [:]
    private var readingPositions: [UUID: Int] = [:]
    private var interactiveRequests: [UUID: InteractiveRequest] = [:]  // key: bookID
    // 正在实时收听的章节：LLM 分析批次要为它的 TTS 让路，校准完即卸载腾内存
    private var liveRead: (bookID: UUID, chapterID: UUID)?
    /// 已被 worker 取走、尚未跑完的分析批次数（含在缓冲闸口上等待的那些）
    private var analysisJobsActive = 0
    /// 真正在与 TTS 同抢 GPU 的分析批次数：收听期间只放行 1 个
    private var runningAnalysisJobs = 0
    // 导入消息箱：submitImport 放入消息后立即返回，由专用消费任务处理
    private var importInbox: [Book] = []
    private var importWaiters: [CheckedContinuation<Book?, Never>] = []
    private var importStopped = false

    /// P0：播放位置之后已备好这么多句音频才放行 LLM 分析，避免两者同抢 GPU。
    private static let analysisPrefetchDepth = 5
    /// 规则标注只覆盖「正在听的这句 + 往后这么多句」。再远的句子等 LLM 标定：
    /// 正则把单个「！」就推成 0.7 强度（"非常紧张急促，语速加快"），而强指令 +
    /// temperature 0.9 正是这模型输出跑偏音频的条件。
    private static let fastPrimeLookahead = 8
    /// 等待音频缓冲的上限；超时后照常分析，防止 TTS 长期失败时任务永远饿死。
    /// 取 60s：让路只推迟「后台校准」，绝不推迟播放本身。
    private static let analysisGateTimeout: TimeInterval = 60

    init(analyzer: ChapterAnalyzer, fastAnalyzer: FastChapterAnalyzer, generator: TTSGenerator, chapterStore: ChapterStore, analysisWorkerCount: Int = 2, ttsWorkerCount: Int = 1, memoryBudgetBytes: Int64 = 2 * 1024 * 1024 * 1024, analysisEstimate: Int64 = 600 * 1024 * 1024, ttsEstimate: Int64 = 900 * 1024 * 1024) {
        self.analyzer = analyzer; self.fastAnalyzer = fastAnalyzer; self.generator = generator; self.chapterStore = chapterStore
        analysisWorkers = max(1, analysisWorkerCount); ttsWorkers = max(1, ttsWorkerCount)
        budget = MemoryBudgetManager(budgetBytes: memoryBudgetBytes); self.analysisEstimate = analysisEstimate; self.ttsEstimate = ttsEstimate
        self.memoryBudgetBytes = memoryBudgetBytes
    }

    func start() async {
        guard !started else { return }; started = true; importStopped = false
        for job in await store.recover() { await queue(job) }
        for _ in 0..<analysisWorkers { workers.append(Task { await self.worker(for: .analysisBatch) }) }
        for _ in 0..<ttsWorkers { workers.append(Task { await self.worker(for: .ttsSentence) }) }
        workers.append(Task { await self.importConsumer() })
    }
    func stop() async {
        workers.forEach { $0.cancel() }; workers.removeAll()
        await analysisQueue.stop(); await ttsQueue.stop()
        importStopped = true
        importWaiters.forEach { $0.resume(returning: nil) }; importWaiters.removeAll()
        started = false
    }

    /// 导入的唯一入口：小说本体此刻已经落库（调用方完成），这里只把
    /// 「请为这本书排产」的消息放进信箱就返回——UI 不会有任何等待。
    func submitImport(_ book: Book) async {
        await start()
        if !importWaiters.isEmpty {
            importWaiters.removeFirst().resume(returning: book)
        } else {
            importInbox.append(book)
        }
    }

    /// 专用消费任务：串行消化导入消息，逐章持久化并排产分析 Job。
    private func importConsumer() async {
        while !Task.isCancelled {
            guard let book = await nextImport() else { return }
            await processImport(book)
        }
    }

    private func nextImport() async -> Book? {
        if !importInbox.isEmpty { return importInbox.removeFirst() }
        guard !importStopped else { return nil }
        return await withCheckedContinuation { importWaiters.append($0) }
    }

    /// Import persists raw text only. Analysis is scheduled per chapter when the
    /// user opens it (plus its neighbours), never as a book-wide eager pass: an
    /// always-non-empty analysis queue keeps the LLM loaded and stealing the GPU
    /// from the TTS that the user is actually waiting on.
    private func processImport(_ book: Book) async {
        var parsed = 0
        for descriptor in book.chapters {
            if Task.isCancelled { return }
            // 导入会重复提交（清完音频与标注后要重新铺正文）：口径没变的章节直接跳过，
            // 否则一次重复提交就把这本书已完成的标注全冲掉了。
            if let saved = await chapterStore.load(bookID: book.id, chapterID: descriptor.id),
               saved.textVersion == SentenceSplitter.textVersion { continue }
            guard let chapter = try? EPUBParser.loadChapter(descriptor) else { continue }
            try? await chapterStore.save(chapter: chapter, bookID: book.id); await cache.set(chapter)
            parsed += 1
        }
        print("[Import] 正文落库完成：\(book.title)（\(parsed)/\(book.chapters.count) 章新解析，分析按章节打开时排产）")
    }

    /// The only chapter-open entry point: parsed text -> promotion.
    func openChapter(_ descriptor: ChapterDescriptor, bookID: UUID, context _: StoryContext) async throws -> Chapter {
        await start()
        let chapter = try await loadParsedChapter(descriptor, bookID: bookID)
        return await promote(chapter: chapter, bookID: bookID, sentence: 0)
    }

    /// 正文取导入时后台解析落库的那一份，点开章节不再跑 XML 解析。
    /// 只有落库缺失（后台还没排到、清过缓存）或断句口径对不上（规则改过）才回落解析器。
    private func loadParsedChapter(_ descriptor: ChapterDescriptor, bookID: UUID) async throws -> Chapter {
        if let saved = await chapterStore.load(bookID: bookID, chapterID: descriptor.id),
           saved.textVersion == SentenceSplitter.textVersion {
            return await purgeReclaimedAudio(saved, bookID: bookID)
        }
        let raw = try EPUBParser.loadChapter(descriptor)
        let chapter = await hydrate(raw, bookID: bookID)
        try? await chapterStore.save(chapter: chapter, bookID: bookID); await cache.set(chapter)
        return chapter
    }

    /// 走落库这条路就没有 parser 兜着了，而音频住在 `Library/Caches` 下——系统随时
    /// 能回收它。留着指向空气的 `audioURL`，播放器会直接跳过这一句，而 ``enqueueTTS``
    /// 见 audioURL 非空也不排产，句子就永久静音。排产记录同样要退回 pending：
    /// 任务还是 .completed 的话 `upsert` 认为做过，重排不进去。
    private func purgeReclaimedAudio(_ chapter: Chapter, bookID: UUID) async -> Chapter {
        var chapter = chapter
        var reclaimed: [Int] = []
        for i in chapter.sentences.indices {
            guard let url = chapter.sentences[i].audioURL,
                  !FileManager.default.fileExists(atPath: url.path) else { continue }
            chapter.sentences[i].audioURL = nil
            chapter.sentences[i].duration = nil
            chapter.sentences[i].audioStatus = .pending
            reclaimed.append(i)
        }
        guard !reclaimed.isEmpty else { return chapter }
        for i in reclaimed { await store.reopenTTS(chapterID: chapter.id, sentenceIndex: i) }
        chapter.ttsStatus = .partial
        chapter.audioStatus = .generating
        try? await chapterStore.save(chapter: chapter, bookID: bookID)
        await cache.set(chapter)
        emit(chapter)
        print("[Cache] chapter=\(chapter.index) 有 \(reclaimed.count) 句音频已被系统回收，退回待合成重排")
        return chapter
    }
    func resolveNext(_ descriptor: ChapterDescriptor, bookID: UUID, context: StoryContext) async -> Chapter? { try? await openChapter(descriptor, bookID: bookID, context: context) }
    func unloadModel() async { await analyzer.unloadModel(); await generator.unloadModel() }

    /// 清理入口：丢掉一本书的音频与标注结果，让它重新走一遍流水线。
    /// 正文（AIReader/Books/ 下的解压产物）与书单不动，不需要重新导入。
    func clearMediaCache(bookID: UUID) async {
        // 两棵树都要删：音频在 Library/Caches/novel/，解析在 Application Support
        // 的 cache/novel/。只删一边的话，另一边会留下指向已消失文件的 audioURL
        // 或者带着旧标注的句子，那种句子再也不会被重新排产生成。
        await generator.discardBookAudio(bookID: bookID)
        await chapterStore.deleteBook(bookID: bookID)
        let dropped = await store.dropBook(bookID: bookID)
        await cache.removeAll()
        interactiveRequests[bookID] = nil
        liveRead = nil
        print("[Cache] 已清空 book=\(bookID) 的音频与标注：丢弃 \(dropped) 个排队/已完成任务，"
            + "剩余缓存 \(ReaderCache.format(ReaderCache.totalSize()))")
    }

    func chapterUpdates(_ id: UUID) -> AsyncThrowingStream<Chapter, Error> {
        AsyncThrowingStream { continuation in
            // 这个闭包继承了本 actor 的隔离（非 Sendable、非逃逸），Task 也在同一隔离域里，
            // 所以再加 await 是空转——编译器会报「await 里没有异步操作」。
            let token = UUID(); Task { self.addWatcher(id, token: token, continuation: continuation) }
            continuation.onTermination = { _ in Task { await self.removeWatcher(id, token: token) } }
        }
    }
    func updateReadingPosition(bookID: UUID, chapterID: UUID, sentenceIndex: Int, nextChapterID: UUID? = nil, prevChapterID: UUID? = nil) async {
        guard let chapter = await chapterStore.load(bookID: bookID, chapterID: chapterID) else { return }
        await promote(chapter: chapter, bookID: bookID, sentence: sentenceIndex)
        // §5 相邻章节档位：下一章 > 上一章 > 远处后台（100）
        await promoteNeighbor(nextChapterID, bookID: bookID, base: 500)
        await promoteNeighbor(prevChapterID, bookID: bookID, base: 400)
    }

    /// UI「重试」入口（§14 情况5）：该章 failed 任务复位并立即做 interactive 提升。
    func retryChapter(bookID: UUID, chapterID: UUID) async {
        await start()
        for job in await store.resetFailed(chapterID: chapterID) { await queue(job) }
        guard let stored = await chapterStore.load(bookID: bookID, chapterID: chapterID) else { return }
        var chapter = stored
        for i in chapter.sentences.indices {
            if chapter.sentences[i].analysisStatus == .failed { chapter.sentences[i].analysisStatus = .pending }
            if chapter.sentences[i].audioStatus == .failed { chapter.sentences[i].audioStatus = .pending }
        }
        chapter.analysisStatus = .pending
        chapter.ttsStatus = chapter.sentences.contains(where: { $0.audioURL != nil }) ? .partial : .pending
        try? await chapterStore.save(chapter: chapter, bookID: bookID); await cache.set(chapter); emit(chapter)
        await promote(chapter: chapter, bookID: bookID, sentence: readingPositions[chapterID] ?? 0)
    }

    func recordPlaybackStarted(bookID: UUID, chapterID: UUID, sentenceIndex: Int) {
        let now = Date()
        print("[SLA] T5 AVPlayer.play book=\(bookID) chapter=\(chapterID) sentence=\(sentenceIndex) at=\(now.timeIntervalSince1970)")
        guard var rec = interactiveRequests[bookID], rec.chapterID == chapterID, !rec.playLogged else { return }
        rec.playLogged = true
        interactiveRequests[bookID] = rec
        let t = now.timeIntervalSince(rec.t0)
        // §19.15 MISS 时给出可归因的阶段：分析等 / TTS 等 / 起播等待
        var reason = "-"
        if t > 5 {
            if rec.analysisDoneAt == nil { reason = "analysis_wait" }
            else if rec.audioReadyAt == nil { reason = "tts_wait/worker_busy/memory_wait" }
            else if let ready = rec.audioReadyAt { reason = ready.timeIntervalSince(rec.t0) > 4.5 ? "tts_wait" : "playback_start" }
        }
        let stage = { (d: Date?) -> String in d.map { String(format: "%.2f", $0.timeIntervalSince(rec.t0)) } ?? "-" }
        print("[InteractivePlayback] chapter=\(rec.chapterIndex) sentence=\(rec.sentence) cacheHit=\(rec.cacheHit) timeToPlay=\(String(format: "%.2f", t))s SLA=\(t <= 5 ? "PASS" : "MISS") reason=\(reason) stages(analysis=\(stage(rec.analysisDoneAt))s audioReady=\(stage(rec.audioReadyAt))s)")
    }

    private func promoteNeighbor(_ id: UUID?, bookID: UUID, base: Int) async {
        guard let id, let chapter = await chapterStore.load(bookID: bookID, chapterID: id) else { return }
        await enqueueAnalysis(chapter: chapter, bookID: bookID, mode: .background, targetBatch: 0, priorityBase: base)
        for i in chapter.sentences.indices where chapter.sentences[i].analysisStatus == .completed {
            await enqueueTTS(chapter: chapter, bookID: bookID, sentence: i, priority: base, mode: .background)
        }
    }

    @discardableResult
    private func promote(chapter: Chapter, bookID: UUID, sentence: Int) async -> Chapter {
        readingPositions[chapter.id] = sentence
        liveRead = (bookID, chapter.id)
        // P0：规则先把播放位置附近这一窗填满（无 GPU、毫秒级），本窗立刻可播；
        // 窗外的句子保持 pending，由后台 LLM 定参数后再排 TTS。
        var ready = await prime(chapter: chapter, bookID: bookID, from: sentence)
        // §19.12 只保留最近一次打开意图：其他章节的 interactive 任务全部降级
        await analysisQueue.demoteInteractive(except: ready.id)
        await ttsQueue.demoteInteractive(except: ready.id)
        await store.demoteInteractive(except: ready.id)
        let t0 = Date()
        let cached = ready.sentences.indices.contains(sentence) && ready.sentences[sentence].audioURL != nil
        interactiveRequests[bookID] = InteractiveRequest(
            chapterID: ready.id, chapterIndex: ready.index, sentence: sentence, t0: t0, cacheHit: cached
        )
        print("[SLA] T0 用户打开 chapter=\(ready.index) sentence=\(sentence) sentences=\(ready.sentences.count) cacheHit=\(cached)")
        // 图片章/版权页切不出句子：不排产是对的，但章级状态必须落到 completed，
        // 否则 UI 会永远挂着「AI 分析中 / 语音准备中」，页面一片空白，
        // 队列里却一个任务都没有——看起来就是卡死。
        if ready.sentences.isEmpty {
            var empty = ready
            empty.analysisStatus = .completed
            empty.ttsStatus = .completed
            empty.audioStatus = .completed
            try? await chapterStore.save(chapter: empty, bookID: bookID)
            await cache.set(empty)
            emit(empty)
            print("[SLA] chapter=\(empty.index) 正文为空（图片章/空白页）→ 不排产")
            return empty
        }
        // 上次合成失败、还有自动重试额度的句子：任务退回 pending（下面排产循环
        // 会重新入队），句子的 audioStatus 也必须一起复位——播放器看到 .failed
        // 会直接跳过，那样重录成功也听不见，句子就成了永久静音。
        let retryable = await store.reopenFailedTTS(chapterID: ready.id)
        var revived = false
        for i in ready.sentences.indices where retryable.contains(i) && ready.sentences[i].audioURL == nil {
            ready.sentences[i].audioStatus = .pending
            revived = true
        }
        if revived {
            ready.ttsStatus = .partial
            try? await chapterStore.save(chapter: ready, bookID: bookID)
            await cache.set(ready)
            emit(ready)
            print("[TTS] 复位 \(retryable.count) 个上次失败的句子，准备重录")
        }
        if ready.sentences.indices.contains(sentence), ready.sentences[sentence].analysisStatus == .completed {
            // 规则标注已给出参数：T2 与 T0 同刻，TTFA 从此只由 TTS 决定
            interactiveRequests[bookID]?.analysisDoneAt = t0
            print("[SLA] T2 分析就绪(规则) chapter=\(ready.index) sentence=\(sentence) elapsed=0.00s")
        }
        // 700 高于邻章排产的 500/400：正在读的这本先校准，再轮到预取邻居
        await enqueueAnalysis(chapter: ready, bookID: bookID, mode: .background, targetBatch: sentence / 10, priorityBase: 700)
        // 只为「参数已就绪」的句子排 TTS：本窗（规则）+ 往轮 LLM 已标定过的。
        // 窗外 pending 句子由 run() 分析批次合并后自己排，参数作者是 LLM。
        for i in ready.sentences.indices where ready.sentences[i].analysisStatus == .completed {
            await enqueueTTS(chapter: ready, bookID: bookID, sentence: i, priority: priority(i, near: sentence), mode: .interactive, requestedAt: t0)
        }
        return ready
    }

    /// 把播放位置附近「还没标注」的句子交给人工规则补上，写盘并广播，让开播不等 LLM。
    /// 窗外句子仍是 pending，所以 promote 的 TTS 排产天然只覆盖本窗。
    private func prime(chapter: Chapter, bookID: UUID, from sentence: Int) async -> Chapter {
        let lower = max(0, min(sentence, chapter.sentences.count))
        let upper = min(chapter.sentences.count, lower + Self.fastPrimeLookahead)
        let window = lower..<upper
        guard upper > lower else { return chapter }

        let missing = chapter.sentences[window].lazy.filter { $0.analysisStatus != .completed }.count
        guard missing > 0 else { return chapter }

        let start = CFAbsoluteTimeGetCurrent()
        var primed = await fastAnalyzer.prime(chapter, in: window)
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000

        primed.audioStatus = .generating
        primed.analysisStatus = .running
        try? await chapterStore.save(chapter: primed, bookID: bookID)
        await cache.set(primed)
        emit(primed)
        print("[Fast] 规则标注窗口 [\(lower),\(upper)) 内 \(missing)/\(window.count) 句耗时 \(String(format: "%.1f", ms))ms → 本窗直接开播，远处句子等 LLM 定参数")
        return primed
    }
    private func enqueueAnalysis(chapter: Chapter, bookID: UUID, mode: JobPriorityMode, targetBatch: Int, priorityBase: Int? = nil) async {
        for batch in 0..<((chapter.sentences.count + 9) / 10) {
            let key = "analysis:\(bookID.uuidString):\(chapter.id.uuidString):\(batch)"
            let decay = abs(batch - targetBatch) * 20
            let p = priorityBase.map { Swift.max(100, $0 - decay) } ?? (mode == .interactive ? 8_000 - decay : 100)
            let job = EnhancementJob(id: key, bookID: bookID, chapterID: chapter.id, type: .analysisBatch, batchIndex: batch, sentenceIndex: nil, state: .pending, priority: p, mode: mode, memoryBytes: analysisEstimate, attempts: 0, createdAt: Date(), startedAt: nil, finishedAt: nil, error: nil)
            let saved = await store.upsert(job); if saved.state == .pending { await analysisQueue.enqueue(saved) }
        }
    }
    private func enqueueTTS(chapter: Chapter, bookID: UUID, sentence: Int, priority: Int, mode: JobPriorityMode, requestedAt: Date = Date()) async {
        guard chapter.sentences.indices.contains(sentence), chapter.sentences[sentence].audioURL == nil else { return }
        let key = "tts:\(bookID.uuidString):\(chapter.id.uuidString):\(sentence)"
        let job = EnhancementJob(id: key, bookID: bookID, chapterID: chapter.id, type: .ttsSentence, batchIndex: nil, sentenceIndex: sentence, state: .pending, priority: priority, mode: mode, memoryBytes: ttsEstimate, attempts: 0, createdAt: requestedAt, startedAt: nil, finishedAt: nil, error: nil)
        let saved = await store.upsert(job); if saved.state == .pending { await ttsQueue.enqueue(saved) }
    }
    private func queue(_ job: EnhancementJob) async { if job.type == .analysisBatch { await analysisQueue.enqueue(job) } else { await ttsQueue.enqueue(job) } }
    private func worker(for type: EnhancementJobType) async { while !Task.isCancelled, let job = await (type == .analysisBatch ? analysisQueue : ttsQueue).next() { await run(job) } }

    private func run(_ original: EnhancementJob) async {
        var job = original; job.state = .running; job.startedAt = Date(); job.attempts += 1; await store.update(job)
        let beforeMemory = MemoryProbe.snapshot()
        var analysisJobPicked = false
        var analysisSlotTaken = false
        defer {
            if analysisJobPicked {
                if analysisSlotTaken { runningAnalysisJobs = max(0, runningAnalysisJobs - 1) }
                analysisJobsActive = max(0, analysisJobsActive - 1)
                Task { await self.unloadAnalyzerIfIdle() }
            }
        }
        if job.type == .analysisBatch {
            analysisJobPicked = true
            analysisJobsActive += 1
            guard await waitForAudioHeadroom(job: job) else {
                job.state = .pending; job.startedAt = nil; job.error = "等待音频缓冲时被取消"
                await store.update(job); await analysisQueue.enqueue(job); return
            }
            analysisSlotTaken = true
            runningAnalysisJobs += 1
        }
        guard await budget.acquire(job.memoryBytes, priority: job.priority) else {
            job.state = .failed; job.finishedAt = Date(); job.error = "Memory estimate exceeds global budget"
            await store.update(job); return
        }
        if job.mode == .interactive, job.type == .ttsSentence, job.sentenceIndex == interactiveRequests[job.bookID]?.sentence {
            interactiveRequests[job.bookID]?.ttsStartAt = Date()
        }
        let snapshot = await budget.reserved
        let available = await budget.availableBytes
        // 只有 LLM 批次值得报内存：TTS 任务一句一个，逐句打会把这段日志冲成噪声。
        // 预估和实际对不上时另有 [Memory] estimate mismatch 那行兜底。
        if job.type == .analysisBatch {
            MemoryProbe.log("Scheduler start \(job.id) pri=\(job.priority) active=\(beforeMemory.active / 1_048_576)MB peak=\(beforeMemory.peak / 1_048_576)MB | budget reserved=\(snapshot / 1_048_576)MB available=\(available / 1_048_576)MB estimate=\(job.memoryBytes / 1_048_576)MB")
        }
        defer { Task { await self.budget.release(job.memoryBytes) } }
        do {
            guard var chapter = await chapterStore.load(bookID: job.bookID, chapterID: job.chapterID) else { throw CocoaError(.fileNoSuchFile) }
            if job.type == .analysisBatch {
                let start = (job.batchIndex ?? 0) * 10; let end = min(chapter.sentences.count, start + 10)
                chapter.analysisStatus = .running
                // §19 interactive 首批拆头：前 2 句先分析、先 emit、先入队 TTS，
                // 剩余 8 句随后补，TTFA 不再等整批 10 句。
                let headEnd = job.mode == .interactive && job.batchIndex == 0 ? min(start + 2, end) : end
                // 「这句是谁说的」由规则定，LLM 只报朗读参数（见 AITools.buildPrompt）。
                // 窗外句子到这一刻才补上说话人：只在局部副本上做，不写盘、不排 TTS，
                // 所以不会回到「正则抢先定整章听感」那个坑——本批参数要等下面 LLM
                // 合并完才落盘排产。
                let base = await fastAnalyzer.prime(chapter, in: start..<end)
                var cursor = start
                while cursor < end {
                    let upper = cursor < headEnd ? headEnd : end
                    let working = try await analyzer.analyzeBatch(chapter: base, range: cursor..<upper, context: StoryContext(characters: [], recentCharacters: [], recentEvents: []))
                    // Other workers may complete a different batch while MLX is
                    // awaiting. Merge only this slice into the newest persisted
                    // snapshot instead of overwriting their sentence results.
                    var latest = await chapterStore.load(bookID: job.bookID, chapterID: job.chapterID) ?? working
                    // 规则补说话人时可能顺手新建了角色：characterID 必须在章节里查得到，
                    // 否则 resolveVoiceID 认不出这个人，那句会退化成无名男声。
                    for character in working.characters
                    where !latest.characters.contains(where: { $0.id == character.id }) {
                        latest.characters.append(character)
                    }
                    // +1 余量：readingPositions 是 UI 在句子切换后才回写的，可能落后
                    // 正在播的那一句一句，少了这个余量会把正在播的音频删掉。
                    let heard = (readingPositions[job.chapterID] ?? 0) + 1
                    for i in cursor..<upper {
                        let old = latest.sentences[i]
                        // 播放头之前的句子已经听过：参数和音频都保持原样。
                        if i <= heard, old.audioURL != nil {
                            latest.sentences[i].analysisStatus = .completed
                            continue
                        }
                        var updated = working.sentences[i]
                        // 音频状态以最新持久化为准，working 只是批次开始时的旧快照。
                        updated.audioURL = old.audioURL
                        updated.duration = old.duration
                        updated.audioStatus = old.audioStatus
                        // 播放头之后 LLM 说了算。规则版音频若参数被改，删文件重录：
                        // 不删的话 produce 的磁盘命中会把旧 WAV 原样取回来。
                        if old.audioURL != nil, Self.affectsAudio(old, updated, chapter: latest, bookID: job.bookID) {
                            await generator.discardAudio(bookID: job.bookID, chapterID: job.chapterID, sentenceID: old.id)
                            await store.reopenTTS(chapterID: job.chapterID, sentenceIndex: i)
                            updated.audioURL = nil
                            updated.duration = nil
                            updated.audioStatus = .pending
                        }
                        latest.sentences[i] = updated
                    }
                    latest.analysisStatus = await analysisStatus(chapterID: job.chapterID, excluding: job.id)
                    chapter = latest
                    try? await chapterStore.save(chapter: latest, bookID: job.bookID); await cache.set(latest); emit(latest)
                    if var rec = interactiveRequests[job.bookID], rec.chapterID == job.chapterID, rec.analysisDoneAt == nil,
                       latest.sentences.indices.contains(rec.sentence), latest.sentences[rec.sentence].analysisStatus == .completed {
                        rec.analysisDoneAt = Date(); interactiveRequests[job.bookID] = rec
                        print("[SLA] T2 分析就绪 chapter=\(latest.index) sentence=\(rec.sentence) elapsed=\(String(format: "%.2f", Date().timeIntervalSince(rec.t0)))s")
                    }
                    let current = readingPositions[chapter.id] ?? start
                    for i in cursor..<upper { await enqueueTTS(chapter: latest, bookID: job.bookID, sentence: i, priority: job.mode == .interactive ? priority(i, near: current) : 100, mode: job.mode) }
                    cursor = upper
                }
            } else {
                let i = job.sentenceIndex ?? 0; chapter.ttsStatus = .running; chapter = try await generator.synthesizeSentence(chapter: chapter, sentenceIndex: i, bookID: job.bookID)
                // TTS is usually one worker, but this merge also keeps the
                // sentence cache correct if that limit is raised later.
                var latest = await chapterStore.load(bookID: job.bookID, chapterID: job.chapterID) ?? chapter
                if latest.sentences.indices.contains(i) { latest.sentences[i] = chapter.sentences[i] }
                chapter = latest
                let ready = chapter.sentences.filter { $0.audioURL != nil }.count; chapter.ttsStatus = ready == chapter.sentences.count ? .completed : .partial; chapter.audioStatus = chapter.ttsStatus == .completed ? .completed : .generating
                try? await chapterStore.save(chapter: chapter, bookID: job.bookID); await cache.set(chapter); emit(chapter)
                // §19.15 首播 SLA 锚点：请求句（而非固定句 0）音频就绪
                if var rec = interactiveRequests[job.bookID], rec.chapterID == job.chapterID, i == rec.sentence, rec.audioReadyAt == nil {
                    rec.audioReadyAt = Date(); interactiveRequests[job.bookID] = rec
                    print("[SLA] T4 音频就绪 chapter=\(chapter.index) sentence=\(i) elapsed=\(String(format: "%.2f", Date().timeIntervalSince(rec.t0)))s")
                }
            }
            job.state = .completed; job.finishedAt = Date(); job.error = nil; await store.update(job)
        } catch {
            job.state = .failed; job.finishedAt = Date(); job.error = error.localizedDescription; await store.update(job)
            print("[Scheduler] failed \(job.id): \(error)")
            // §14 情况5：失败状态落到句级/章级，UI 可显示「分析失败 [重试]」；正文阅读不受影响
            if var chapter = await chapterStore.load(bookID: job.bookID, chapterID: job.chapterID) {
                if job.type == .analysisBatch, let batch = job.batchIndex {
                    for i in (batch * 10)..<min(batch * 10 + 10, chapter.sentences.count) { chapter.sentences[i].analysisStatus = .failed }
                    chapter.analysisStatus = .failed
                } else if job.type == .ttsSentence, let i = job.sentenceIndex, chapter.sentences.indices.contains(i) {
                    chapter.sentences[i].audioStatus = .failed
                    chapter.ttsStatus = .failed
                }
                try? await chapterStore.save(chapter: chapter, bookID: job.bookID); emit(chapter)
            }
        }
        let afterMemory = MemoryProbe.snapshot()
        updateEstimate(for: job.type, reserved: job.memoryBytes, before: beforeMemory, after: afterMemory)
    }
    /// 标注改动是否会影响合成出来的声音。没影响就别重录：一句要几十秒 GPU
    /// 时间，无谓重录还会让听感中途换人。speed / pitch / voiceStrength 现在
    /// 都会进 CustomVoice 的 instruct，所以都要比。
    private static func affectsAudio(
        _ old: Sentence,
        _ updated: Sentence,
        chapter: Chapter,
        bookID: UUID
    ) -> Bool {
        old.speaker != updated.speaker
            || old.characterID != updated.characterID
            || old.emotion != updated.emotion
            || abs(old.emotionIntensity - updated.emotionIntensity) > 0.05
            || abs(old.speed - updated.speed) > 0.01
            || abs(old.pitch - updated.pitch) > 0.03
            || abs(old.voiceStrength - updated.voiceStrength) > 0.05
            // 说话人也可能换：无名对白走固定男声，命名人物走各自的声音
            || VoiceManager.resolvedVoice(for: old, in: chapter, bookID: bookID)
                != VoiceManager.resolvedVoice(for: updated, in: chapter, bookID: bookID)
    }

    /// P0：LLM 分析与 TTS 共用同一块 GPU，并发时两边耗时一起恶化。规则标注已经
    /// 保证「有参数就能播」，所以分析批次要为正在收听的章节让路：等播放位置之后
    /// 已备好足够深的音频缓冲（或该章已无待合成句子）、且没有别的分析批次在跑，
    /// 再开始。超时仍放行，避免 TTS 长期失败时分析永远饿死。
    /// 返回 false 表示等待中被取消，调用方需把批次退回 pending。
    private func waitForAudioHeadroom(job: EnhancementJob) async -> Bool {
        guard let live = liveRead else { return true }
        let deadline = Date().addingTimeInterval(Self.analysisGateTimeout)
        var announced = false

        while true {
            if Task.isCancelled { return false }

            let state = await audioBufferState(bookID: live.bookID, chapterID: live.chapterID)
            let bufferDeepEnough = state.readyAhead >= Self.analysisPrefetchDepth || state.pendingTTS == 0
            if bufferDeepEnough && runningAnalysisJobs == 0 { return true }

            if Date() >= deadline {
                print("[Gate] 等待音频缓冲超时 \(Int(Self.analysisGateTimeout))s（就绪 \(state.readyAhead)/需 \(Self.analysisPrefetchDepth)，仍待合成 \(state.pendingTTS) 句，在跑分析 \(runningAnalysisJobs) 个），照常分析 \(job.id)")
                return true
            }

            if !announced {
                announced = true
                print("[Gate] LLM 分析让路给 TTS：chapter=\(live.chapterID) 就绪 \(state.readyAhead)/\(Self.analysisPrefetchDepth) 句，在跑分析 \(runningAnalysisJobs) 个")
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    /// 播放位置之后的音频缓冲深度。章节读不到时视为「无需让路」。
    private func audioBufferState(bookID: UUID, chapterID: UUID) async -> (readyAhead: Int, pendingTTS: Int) {
        var chapter = await cache.get(chapterID)
        if chapter == nil { chapter = await chapterStore.load(bookID: bookID, chapterID: chapterID) }
        guard let chapter else {
            return (Self.analysisPrefetchDepth, 0)
        }
        let position = min(max(0, readingPositions[chapterID] ?? 0), chapter.sentences.count)
        var ready = 0; var pending = 0
        for i in position..<chapter.sentences.count {
            if chapter.sentences[i].audioURL == nil { pending += 1 } else { ready += 1 }
        }
        return (ready, pending)
    }

    /// 章级分析状态以持久层的批次为准：快分析会把句子全填满参数，
    /// 「所有句子都有参数」不再等价于「LLM 校准完成」。
    private func analysisStatus(chapterID: UUID, excluding jobID: String) async -> AnalysisStatus {
        let summary = await store.analysisBatchSummary(chapterID: chapterID, excluding: jobID)
        if summary.pending > 0 { return .running }
        return summary.failed > 0 ? .failed : .completed
    }

    /// P0：分析队列排空后 Qwen3-0.6B 就再无用途，却仍占着 ~1.2GB 权重，而这块
    /// 内存正是 TTS 缓存与预取需要的。后续章节的后台批次会按需重新加载它。
    /// 取任务后被缓冲闸口挂起的批次算 active，避免刚卸载又立刻重载。
    private func unloadAnalyzerIfIdle() async {
        guard analysisJobsActive == 0, runningAnalysisJobs == 0 else { return }
        guard await analysisQueue.pendingCount == 0 else { return }
        await analyzer.unloadModel()
        print("[Memory] 分析队列排空 → 卸载 Qwen3-0.6B，权重内存让给 TTS 缓存与预取")
    }

    private func hydrate(_ raw: Chapter, bookID: UUID) async -> Chapter {
        guard let saved = await chapterStore.load(bookID: bookID, chapterID: raw.id) else { return raw }
        var result = raw; result.characters = saved.characters; result.analysisStatus = saved.analysisStatus; result.ttsStatus = saved.ttsStatus; result.audioStatus = saved.audioStatus
        for i in result.sentences.indices where saved.sentences.indices.contains(i) {
            // 音频现在在 Library/Caches 下，系统可能已经把它回收了：这种句子要退回未合成的
            // 原样，让排产重新看见它，否则播放器拿到一个指向空气的 URL。
            let audioStillThere = saved.sentences[i].audioURL.map {
                FileManager.default.fileExists(atPath: $0.path)
            } ?? true
            if saved.sentences[i].text == result.sentences[i].text, audioStillThere {
                // 段落结构来自正文本身，必须留新解析的那份：旧 chapter.json 里
                // 这个字段可能是缺省值 true，整句覆盖会把排版打回逐句缩进。
                var merged = saved.sentences[i]
                merged.startsParagraph = result.sentences[i].startsParagraph
                result.sentences[i] = merged
            } else if !audioStillThere {
                // 音频文件已被回收：这一句保留解析出来的原样（没音频），但排产记录
                // 还停在 .completed，`upsert` 会认为做过而不重排——不退回 pending 就永远静音。
                await store.reopenTTS(chapterID: raw.id, sentenceIndex: i)
            }
        }
        return result
    }
    private func priority(_ index: Int, near current: Int) -> Int { 10_000 - min(1_000, abs(index - current) * 10) }
    /// MLX reports allocator values rather than an exact per-job RSS. We retain
    /// the largest observed incremental peak with a configurable 1.2 safety
    /// factor, so later work is admitted more conservatively after a mismatch.
    private func updateEstimate(for type: EnhancementJobType, reserved: Int64, before: (active: Int, cached: Int, peak: Int), after: (active: Int, cached: Int, peak: Int)) {
        let observed = Int64(max(0, after.peak - before.active))
        let adjusted = Int64(Double(observed) * 1.2)
        // 上限：单个 Job 的预估不允许超过全局预算的一半，否则永远无法准入
        guard adjusted > reserved, adjusted <= memoryBudgetBytes / 2 else { return }
        print("[Memory] estimate mismatch jobType=\(type.rawValue) reserved=\(reserved / 1_048_576)MB observedPeak=\(observed / 1_048_576)MB next=\(adjusted / 1_048_576)MB")
        if type == .analysisBatch { analysisEstimate = adjusted } else { ttsEstimate = adjusted }
    }
    private func addWatcher(_ id: UUID, token: UUID, continuation: AsyncThrowingStream<Chapter, Error>.Continuation) { watchers[id, default: [:]][token] = continuation }
    private func removeWatcher(_ id: UUID, token: UUID) { watchers[id]?[token] = nil }
    private func emit(_ chapter: Chapter) { watchers[chapter.id]?.values.forEach { $0.yield(chapter) } }
}
