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
        save(); return jobs.values.filter { $0.state == .pending || $0.state == .failed }
    }
    func upsert(_ proposed: EnhancementJob) -> EnhancementJob {
        guard var old = jobs[proposed.id] else { jobs[proposed.id] = proposed; save(); return proposed }
        guard old.state == .pending || old.state == .failed else { return old }
        old.priority = max(old.priority, proposed.priority); old.mode = proposed.mode == .interactive ? .interactive : old.mode
        old.state = .pending; old.error = nil; jobs[old.id] = old; save(); return old
    }
    func update(_ job: EnhancementJob) { jobs[job.id] = job; save() }
    /// 与内存队列同步降级：持久层里非当前章节的 interactive 也退回 background。
    func demoteInteractive(except chapterID: UUID) {
        var changed = false
        for (key, job) in jobs where job.chapterID != chapterID && job.mode == .interactive && (job.state == .pending || job.state == .failed) {
            var demoted = job; demoted.mode = .background; demoted.priority = Swift.min(demoted.priority, 100); jobs[key] = demoted; changed = true
        }
        if changed { save() }
    }
    /// UI「重试」入口：把该章 failed 任务放回 pending 再入队。
    func resetFailed(chapterID: UUID) -> [EnhancementJob] {
        var revived: [EnhancementJob] = []
        for (key, job) in jobs where job.chapterID == chapterID && job.state == .failed {
            var fresh = job; fresh.state = .pending; fresh.error = nil; fresh.finishedAt = nil; jobs[key] = fresh; revived.append(fresh)
        }
        save(); return revived
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
    private let analyzer: ChapterAnalyzer; private let generator: TTSGenerator; private let chapterStore: ChapterStore
    private let cache = ChapterCache(); private let analysisQueue = PriorityJobQueue(); private let ttsQueue = PriorityJobQueue()
    private let store = EnhancementJobStore(); private let budget: MemoryBudgetManager
    private let analysisWorkers: Int; private let ttsWorkers: Int; private var analysisEstimate: Int64; private var ttsEstimate: Int64
    private let memoryBudgetBytes: Int64
    private var workers: [Task<Void, Never>] = []; private var started = false
    private var watchers: [UUID: [UUID: AsyncThrowingStream<Chapter, Error>.Continuation]] = [:]
    private var readingPositions: [UUID: Int] = [:]
    private var interactiveRequests: [UUID: InteractiveRequest] = [:]  // key: bookID
    // 导入消息箱：submitImport 放入消息后立即返回，由专用消费任务处理
    private var importInbox: [Book] = []
    private var importWaiters: [CheckedContinuation<Book?, Never>] = []
    private var importStopped = false

    init(analyzer: ChapterAnalyzer, generator: TTSGenerator, chapterStore: ChapterStore, analysisWorkerCount: Int = 2, ttsWorkerCount: Int = 1, memoryBudgetBytes: Int64 = 2 * 1024 * 1024 * 1024, analysisEstimate: Int64 = 600 * 1024 * 1024, ttsEstimate: Int64 = 900 * 1024 * 1024) {
        self.analyzer = analyzer; self.generator = generator; self.chapterStore = chapterStore
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

    /// Import persists raw text before scheduling enhancements, so reading stays
    /// possible even if the app is killed while analysis is pending.
    private func processImport(_ book: Book) async {
        for descriptor in book.chapters {
            if Task.isCancelled { return }
            guard let chapter = try? EPUBParser.loadChapter(descriptor) else { continue }
            try? await chapterStore.save(chapter: chapter, bookID: book.id); await cache.set(chapter)
            await enqueueAnalysis(chapter: chapter, bookID: book.id, mode: .background, targetBatch: 0)
        }
        print("[Import] 后台排产完成：\(book.title)（\(book.chapters.count) 章）")
    }

    /// The only chapter-open entry point: parser -> immediate text -> promotion.
    func openChapter(_ descriptor: ChapterDescriptor, bookID: UUID, context _: StoryContext) async throws -> Chapter {
        await start()
        let raw = try EPUBParser.loadChapter(descriptor); let chapter = await hydrate(raw, bookID: bookID)
        try? await chapterStore.save(chapter: chapter, bookID: bookID); await cache.set(chapter)
        await promote(chapter: chapter, bookID: bookID, sentence: 0)
        return chapter
    }
    func resolveNext(_ descriptor: ChapterDescriptor, bookID: UUID, context: StoryContext) async -> Chapter? { try? await openChapter(descriptor, bookID: bookID, context: context) }
    func unloadModel() async { await analyzer.unloadModel(); await generator.unloadModel() }

    func chapterUpdates(_ id: UUID) -> AsyncThrowingStream<Chapter, Error> {
        AsyncThrowingStream { continuation in
            let token = UUID(); Task { await self.addWatcher(id, token: token, continuation: continuation) }
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

    private func promote(chapter: Chapter, bookID: UUID, sentence: Int) async {
        readingPositions[chapter.id] = sentence
        // §19.12 只保留最近一次打开意图：其他章节的 interactive 任务全部降级
        await analysisQueue.demoteInteractive(except: chapter.id)
        await ttsQueue.demoteInteractive(except: chapter.id)
        await store.demoteInteractive(except: chapter.id)
        let t0 = Date()
        let cached = chapter.sentences.indices.contains(sentence) && chapter.sentences[sentence].audioURL != nil
        interactiveRequests[bookID] = InteractiveRequest(
            chapterID: chapter.id, chapterIndex: chapter.index, sentence: sentence, t0: t0, cacheHit: cached
        )
        print("[SLA] T0 用户打开 chapter=\(chapter.index) sentence=\(sentence) cacheHit=\(cached)")
        await enqueueAnalysis(chapter: chapter, bookID: bookID, mode: .interactive, targetBatch: sentence / 10)
        for i in chapter.sentences.indices where chapter.sentences[i].analysisStatus == .completed {
            await enqueueTTS(chapter: chapter, bookID: bookID, sentence: i, priority: priority(i, near: sentence), mode: .interactive, requestedAt: t0)
        }
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
        guard await budget.acquire(job.memoryBytes, priority: job.priority) else {
            job.state = .failed; job.finishedAt = Date(); job.error = "Memory estimate exceeds global budget"
            await store.update(job); return
        }
        if job.mode == .interactive, job.type == .ttsSentence, job.sentenceIndex == interactiveRequests[job.bookID]?.sentence {
            interactiveRequests[job.bookID]?.ttsStartAt = Date()
        }
        let snapshot = await budget.reserved
        let available = await budget.availableBytes
        MemoryProbe.log("Scheduler start \(job.id) pri=\(job.priority) active=\(beforeMemory.active / 1_048_576)MB peak=\(beforeMemory.peak / 1_048_576)MB | budget reserved=\(snapshot / 1_048_576)MB available=\(available / 1_048_576)MB estimate=\(job.memoryBytes / 1_048_576)MB")
        defer { Task { await self.budget.release(job.memoryBytes) } }
        do {
            guard var chapter = await chapterStore.load(bookID: job.bookID, chapterID: job.chapterID) else { throw CocoaError(.fileNoSuchFile) }
            if job.type == .analysisBatch {
                let start = (job.batchIndex ?? 0) * 10; let end = min(chapter.sentences.count, start + 10)
                chapter.analysisStatus = .running
                // §19 interactive 首批拆头：前 2 句先分析、先 emit、先入队 TTS，
                // 剩余 8 句随后补，TTFA 不再等整批 10 句。
                let headEnd = job.mode == .interactive && job.batchIndex == 0 ? min(start + 2, end) : end
                var cursor = start
                while cursor < end {
                    let upper = cursor < headEnd ? headEnd : end
                    let working = try await analyzer.analyzeBatch(chapter: chapter, range: cursor..<upper, context: StoryContext(characters: [], recentCharacters: [], recentEvents: []))
                    // Other workers may complete a different batch while MLX is
                    // awaiting. Merge only this slice into the newest persisted
                    // snapshot instead of overwriting their sentence results.
                    var latest = await chapterStore.load(bookID: job.bookID, chapterID: job.chapterID) ?? working
                    for i in cursor..<upper { latest.sentences[i] = working.sentences[i] }
                    latest.analysisStatus = latest.sentences.allSatisfy { $0.analysisStatus == .completed } ? .completed : .running
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
        MemoryProbe.log("Scheduler finish \(job.id)")
    }
    private func hydrate(_ raw: Chapter, bookID: UUID) async -> Chapter {
        guard let saved = await chapterStore.load(bookID: bookID, chapterID: raw.id) else { return raw }
        var result = raw; result.characters = saved.characters; result.analysisStatus = saved.analysisStatus; result.ttsStatus = saved.ttsStatus; result.audioStatus = saved.audioStatus
        for i in result.sentences.indices where saved.sentences.indices.contains(i) { if saved.sentences[i].text == result.sentences[i].text { result.sentences[i] = saved.sentences[i] } }
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
