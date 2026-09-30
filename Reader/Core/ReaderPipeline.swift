import Foundation
import UIKit

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
    /// 冷启动恢复任务表。`windowBatches` 是每本书允许的「在队未完成解析批次」上限，
    /// 由调用方（调度器）给：窗口口径只有一份，别在这里另写一个数。
    func recover(windowBatches: Int) -> [EnhancementJob] {
        for id in jobs.keys where jobs[id]?.state == .running { jobs[id]?.state = .pending; jobs[id]?.startedAt = nil; jobs[id]?.error = "Interrupted by previous app exit" }
        // 整书解析批次原样恢复：它们就是这本书的后台解析进度，杀进程不该从头再来。
        // 播放路径已经不排解析了（promote 只排音频），丢了就再也没人补。
        // 逐句 TTS 任务相反，一律丢弃重排：留着 worker 会被上次会话留下的别的书的
        // 后台音频占满——单 worker 不能打断在跑的任务，一句被内存压力拖到几十秒时，
        // 用户这一章就在队尾等好几分钟，看起来就是「点开没声音」。
        var droppedTTS = 0
        for (key, job) in jobs where job.type == .ttsSentence && (job.state == .pending || job.state == .failed) {
            jobs[key] = nil; droppedTTS += 1
        }
        // 收敛旧账：在「一次排完整本」那个年代排出来的上万个批次，一个 worker 一晚上
        // 也吃不完，而它们占着任务表的规模与内存闸口的 waiter 列表。窗口之外的部分直接从
        // 账上删掉——那些批次一次都没跑过，窗口滚到时会由补产重新提议，代价是重读一次章目录。
        // 留下的按优先级取：解析的优先级就是章序（越靠前数越大），所以删掉的必然是前沿之后那段。
        var trimmed = 0
        if windowBatches > 0 {
            var byBook: [UUID: [EnhancementJob]] = [:]
            for job in jobs.values where job.type == .analysisBatch && job.state == .pending {
                byBook[job.bookID, default: []].append(job)
            }
            for (bookID, list) in byBook where list.count > windowBatches {
                let keep = Set(list.sorted { $0.priority > $1.priority }.prefix(windowBatches).map(\.id))
                for job in list where !keep.contains(job.id) { jobs[job.id] = nil; trimmed += 1 }
                print("[Scheduler] 《\(bookID.uuidString.prefix(8))》窗口收敛：\(list.count) 个在队批次 → 保留前沿 \(keep.count) 个，丢弃 \(list.count - keep.count) 个（窗口滚到时重排）")
            }
        }
        // 失败到顶的是终态：不外放、也不计进「待跑」。记录留在表里挡住重复排产
        // （`upsertAll` 对这种记录不动），要再跑只能走 UI 的「重试」，那里会把 attempts 清 0。
        // 以前这里把 failed 一并外放，冷启动一次就是一次整书重排——日志上「恢复 13,116」
        // 和「排产 6,559」看着像在抢同一批活，其实抢的就是这些该停下来的。
        var restored: [EnhancementJob] = []
        var revivedFailed = 0
        var terminalFailed = 0
        for job in jobs.values {
            switch job.state {
            case .pending: restored.append(job)
            case .failed where job.attempts < Self.maxAutoRetries: restored.append(job); revivedFailed += 1
            case .failed: terminalFailed += 1
            case .running, .completed: break
            }
        }
        let restoredAnalysis = restored.filter { $0.type == .analysisBatch }.count
        if !restored.isEmpty || droppedTTS > 0 || terminalFailed > 0 || trimmed > 0 {
            // 四个数字各管一件事：待跑的总量、里面有多少是「失败但还有额度」捞回来的、
            // 有多少已经钉死、以及被丢掉的逐句音频。排产那条日志会报「与恢复重叠多少」，
            // 两边对上才知道有没有重复排产。
            print("[Scheduler] 恢复 \(restored.count) 个待跑任务（解析 \(restoredAnalysis) / 音频 \(restored.count - restoredAnalysis)，含失败退回 \(revivedFailed)），"
                + "丢弃 \(droppedTTS) 个遗留逐句音频任务（改为打开章节时按需排产），"
                + "终态失败 \(terminalFailed) 个不再排队"
                + (trimmed > 0 ? "，窗口收敛 \(trimmed) 个超前批次" : ""))
        }
        // 去抖落盘：这一步挂在「第一次开章」上，整份任务表重编码 + 原子写是几十 MB
        // 的写量。就算这一窗内被杀，下次 recover 会把 .running 再翻回 pending、
        // 把遗留的逐句任务再丢一遍——两件事都是幂等的。
        markDirty(); return restored
    }
    /// 一句/一批最多自动重试这么多次。两种任务共用一个数：没有上限的话，模型稳定
    /// 合成不了的长句会在每次进出章节时再烧掉几十秒 GPU，永远出不来声音——失败必须
    /// 会停下来。名字以前带 TTS，其实解析批次一样走这条闸。
    static let maxAutoRetries = 3
    func update(_ job: EnhancementJob) { jobs[job.id] = job; markDirty() }
    /// `upsertAll` 的账面：光报「排了 N 个」看不出这 N 个里有几个本来就挂在队列里。
    struct UpsertReport {
        /// 真正要入队的（新建 + pending 抬优先级 + 失败捞回）
        let fresh: [EnhancementJob]
        /// 表里新建的键
        let created: Int
        /// 撞上已有 pending/可重试 failed 的：这批与「恢复出来的任务」是同一份活
        let overlapped: Int
        /// .completed 或终态失败，提议被原样丢掉
        let skipped: Int
    }
    /// 排产用：一次吃进一批任务，只在最后置一次脏。
    /// 已存在的任务只抬优先级/抬 mode，.completed 不动（重排会被 worker 当成有效工作），
    /// 还有重试额度的 failed 退回 pending；返回真正需要入队的那些。
    func upsertAll(_ proposed: [EnhancementJob]) -> UpsertReport {
        var fresh: [EnhancementJob] = []
        var created = 0
        var overlapped = 0
        var skipped = 0
        for job in proposed {
            guard var old = jobs[job.id] else {
                jobs[job.id] = job
                fresh.append(job)
                created += 1
                continue
            }
            guard old.state == .pending || (old.state == .failed && old.attempts < Self.maxAutoRetries) else {
                skipped += 1
                continue
            }
            old.priority = max(old.priority, job.priority); old.state = .pending; old.error = nil
            old.mode = job.mode == .interactive ? .interactive : old.mode
            jobs[old.id] = old
            fresh.append(old)
            overlapped += 1
        }
        if !fresh.isEmpty { markDirty() }
        return UpsertReport(fresh: fresh, created: created, overlapped: overlapped, skipped: skipped)
    }
    /// 这本书还有多少批次属于「没做完的活」：在队、在跑、失败但还有重试额度。
    /// 窗口补产按这个数决定补多少，所以它必须算持久层而不是内存队列——
    /// worker 取走的那一批已经不在队列里了，只看队列会在几秒内把窗口撑成两倍。
    func analysisOpenCount(bookID: UUID) -> Int {
        var open = 0
        for job in jobs.values where job.type == .analysisBatch && job.bookID == bookID {
            switch job.state {
            case .pending, .running: open += 1
            case .failed where job.attempts < Self.maxAutoRetries: open += 1
            case .failed, .completed: break
            }
        }
        return open
    }
    /// 已经全部做完的章：有批次记录，且一章都没剩（没有 pending/running/可重试 failed）。
    /// 窗口扫描靠它跳过做过的章，不用再为「这一章做没做过」解一次落库正文——
    /// 那是整本书 25 秒磁盘活的来源。终态失败的章也算做完：它不会再自己爬起来，
    /// 只有 UI 的「重试」能把它捞回，那条路会把这本书的游标重置。
    func analyzedChapters(bookID: UUID) -> Set<UUID> {
        var seen: Set<UUID> = []
        var open: Set<UUID> = []
        for job in jobs.values where job.type == .analysisBatch && job.bookID == bookID {
            seen.insert(job.chapterID)
            switch job.state {
            case .pending, .running: open.insert(job.chapterID)
            case .failed where job.attempts < Self.maxAutoRetries: open.insert(job.chapterID)
            case .failed, .completed: break
            }
        }
        return seen.subtracting(open)
    }
    /// 清完磁盘音频后必须丢掉任务记录：留着 .completed 的话 upsert 认为做过，
    /// 句子永远不会再排产生成音频。
    func dropBook(bookID: UUID) -> Int {
        let before = jobs.count
        for (key, job) in jobs where job.bookID == bookID { jobs[key] = nil }
        let dropped = before - jobs.count
        if dropped > 0 { markDirty() }
        return dropped
    }
    /// 重录：某句音频作废（LLM 改了参数）。已完成的 TTS 任务必须退回 pending，
    /// 否则 upsert 认定它做过，这一句从此静音。
    func reopenTTS(chapterID: UUID, sentenceIndex: Int) {
        var changed = false
        for (key, job) in jobs where job.type == .ttsSentence && job.chapterID == chapterID && job.sentenceIndex == sentenceIndex && job.state == .completed {
            var fresh = job; fresh.state = .pending; fresh.finishedAt = nil; fresh.error = nil; jobs[key] = fresh; changed = true
        }
        if changed { markDirty() }
    }
    /// 与内存队列同步降级：持久层里非当前章节的 interactive 也退回 background。
    func demoteInteractive(except chapterID: UUID) {
        var changed = false
        for (key, job) in jobs where job.chapterID != chapterID && job.mode == .interactive && (job.state == .pending || job.state == .failed) {
            var demoted = job; demoted.mode = .background; demoted.priority = Swift.min(demoted.priority, 100); jobs[key] = demoted; changed = true
        }
        if changed { markDirty() }
    }
    /// 进入章节时把「上次失败但还有自动重试额度」的逐句任务退回 pending，返回这些
    /// 句子的序号：调用方要据此复位句子的 audioStatus，否则播放器看到 .failed 会
    /// 直接跳过，重录成功也听不见。
    func reopenFailedTTS(chapterID: UUID) -> Set<Int> {
        var reopened: Set<Int> = []
        for (key, job) in jobs where job.type == .ttsSentence && job.chapterID == chapterID && job.state == .failed && job.attempts < Self.maxAutoRetries {
            var fresh = job; fresh.state = .pending; fresh.error = nil; fresh.finishedAt = nil; jobs[key] = fresh
            if let i = job.sentenceIndex { reopened.insert(i) }
        }
        if !reopened.isEmpty { markDirty() }
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
    /// 真正的落盘只有一个口径，`save` 只置脏：改一次表就整份重编码写一遍的话，
    /// 整书排产（几千批次）加上每句播放推进的状态更新会把这笔账全压在
    /// 「点开章节的那 1 秒」里。去抖取 2 秒：任务表一秒内会改好几回（worker 一批接
    /// 一批收尾），250ms 根本合不成一次，等于每次改动都重写一遍全表。
    /// 丢掉的只有这一窗内刚完成的任务（下次会重跑那几个批次，白烧一点 GPU，
    /// 不丢正文也不丢音频文件），进后台时另外同步 flush 一次。
    private var dirty = false
    private var flusher: Task<Void, Never>?
    private static let flushDebounce: UInt64 = 2_000_000_000
    private func markDirty() {
        dirty = true
        guard flusher == nil else { return }
        flusher = Task { await self.flushDelayed() }
    }
    private func flushDelayed() async {
        try? await Task.sleep(nanoseconds: Self.flushDebounce)
        flusher = nil
        if dirty { save() }
    }
    /// 拆队列/清缓存前同步落一次盘。
    func flushNow() {
        flusher?.cancel(); flusher = nil
        if dirty { save() }
    }
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
    /// 挂起 = worker 取不到新任务，但**已经在跑的那一批不会被杀**。
    /// 这是「用户在听时把 GPU 整块让出去」唯一的实现方式：闸口只在批次开始前
    /// 看一眼是不够的，一批 10 句要跑几十秒，期间 TTS 全在跟它抢。
    private var suspended = false
    func enqueue(_ job: EnhancementJob) { guard !stopped else { return }; insert(job); wake() }
    /// 一次排入一批。`enqueue` 每条都要 wake→take 把 pending 全扫一遍找最高优先级，
    /// 几千条就是 O(n²)：整本排产和恢复任务表都是这个形状。末尾统一 wake 一次，
    ///  worker 仍按最高优先级取，语义不变。
    func enqueueAll(_ jobs: [EnhancementJob]) {
        guard !stopped, !jobs.isEmpty else { return }
        for job in jobs { insert(job) }
        wake()
    }
    private func insert(_ job: EnhancementJob) {
        if var old = pending[job.id] { old.priority = max(old.priority, job.priority); old.mode = job.mode == .interactive ? .interactive : old.mode; pending[job.id] = old } else { pending[job.id] = job }
    }
    func setSuspended(_ value: Bool) {
        guard suspended != value else { return }
        suspended = value
        if !value { wake() }
    }
    var isSuspended: Bool { suspended }
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
        guard !suspended else { return nil }
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

/// 在飞任务体的登记表。用一把锁而不是 actor 状态，是因为进后台那一瞬必须能在
/// 通知回调里**同步**掐掉它们：绕回 actor 排队就晚了一个 token，而多提交的那一次
/// Metal 命令就够让进程 terminate（见 `AppBackgroundGate`）。
/// 最多只有 worker 数那么几条，锁的开销可以忽略。
private final class InFlightRegistry: @unchecked Sendable {

    private let lock = NSLock()
    private var entries: [String: (task: Task<Void, Never>, type: EnhancementJobType)] = [:]

    func set(_ id: String, task: Task<Void, Never>, type: EnhancementJobType) {
        lock.lock(); entries[id] = (task, type); lock.unlock()
    }

    func clear(_ id: String) {
        lock.lock(); entries[id] = nil; lock.unlock()
    }

    var tasks: [Task<Void, Never>] {
        lock.lock(); defer { lock.unlock() }; return entries.values.map(\.task)
    }

    /// 分析批次一律掐；句子只在「后端真的往 Metal 提交」时掐（Edge / Kokoro-CPU 不该被掐）。
    func cancelGPUWork(haltingTTS: Bool) {
        lock.lock()
        let victims = entries.filter { $0.value.type == .analysisBatch || haltingTTS }.map(\.value.task)
        lock.unlock()
        victims.forEach { $0.cancel() }
    }
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
    /// 最近一次「用户正在收听」的证据：播放位置更新、起播，都在刷新它。
    /// 分析批次看它是否还在新鲜窗口内决定让不让路——只靠显式的暂停/停止信号不可靠
    /// （从阅读页退走并不会停播放器），而心跳每句都会来一次。
    private var lastListeningBeat: Date?
    /// 每本书的解析窗口游标（排到第几章）。窗口是滚动的：在队未完成的批次低于上限就往前
    /// 补一段，补到书尾就停。旧口径「导入时一次排整本」把几千个批次连同它们的内存预估
    /// 一起压进任务表和 `MemoryBudgetManager` 的 waiter 列表，而读者会走到的只有前沿那一小段。
    private struct AnalysisFrontier {
        /// 下一次扫描从这一章开始（`book.chapters` 的下标）
        var chapter = 0
        /// 优先级累计，保证章序越靠前数越大
        var rank = 0
        /// 已读过的章数，只进 [Roster] 日志的「累计 N 章」
        var chaptersRead = 0
        /// 扫到过书尾：没有新章、没有人工重试就不要再扫一遍这本书
        var exhausted = false
    }
    private var analysisFrontiers: [UUID: AnalysisFrontier] = [:]
    /// 正在补产的书。同一本书的触发点很密（每完成一批、每次换章），叠两份扫描就是
    /// 两倍磁盘活，还会把同一批批次排两次进 `upsertAll`。
    private var analysisFills: [UUID: Task<Int, Never>] = [:]
    /// 最近在读哪一章：只有换章那一下才值得惊动排产，逐句推进不用。
    private var readingChapters: [UUID: UUID] = [:]
    /// 手上出现过哪些书：建人物档案要按章扫，而队列任务里只有 bookID。
    private var knownBooks: [UUID: Book] = [:]
    private typealias RosterBuild = Task<Void, Never>
    /// 正在补档的书。同一本书的多个任务会同时问到，各扫一遍整本书就是白白多倍磁盘活。
    private var rosterBuilds: [UUID: RosterBuild] = [:]
    /// 已经为哪些章补过档（窗口扫描不去重做的话，每句合成都要读那几章的盘）。
    private var rosterScanned: [UUID: Set<UUID>] = [:]
    /// 已被 worker 取走、尚未跑完的分析批次数（含在缓冲闸口上等待的那些）
    private var analysisJobsActive = 0
    /// 真正在与 TTS 同抢 GPU 的分析批次数：收听期间只放行 1 个
    private var runningAnalysisJobs = 0
    /// 收听期间分析队列被挂起：worker 取不到新批次，但已经在跑的那一批不杀。
    /// 闸口必须放在队列上而不是让每批次自己问——真机日志里 `[Gate]` 一次都没出现，
    /// 因为启动后 `recover()` 立刻把批次交给 worker，那会儿还没有心跳可问。
    private var analysisSuspended = false
    /// 盯心跳过期的任务，队列恢复后作废；同一时间只允许一个。
    private var resumeWatch: Task<Void, Never>?

    // MARK: - 后台门禁

    /// 「后台继续朗读」那一行的键（设置页的 `@AppStorage` 用同一个字符串）。
    /// 只管语音：解析那一侧没有开关，见 `applyBackground`。
    static let continueTTSInBackgroundKey = "continueTTSInBackground"

    /// 后台门禁的两道闸。和 `analysisSuspended`（正在收听）**分开记**：合并成一个
    /// 布尔会出现「心跳一过期把后台那道闸也一起开了」。
    private var analysisHeldByBackground = false
    private var ttsHeldByBackground = false
    /// 「语音播报」被用户关掉：这不只是不出声，而是这台机器不该再为声音做任何事——
    /// 两条队列都挂住、在飞的推理掐掉、两边权重全部交还。
    /// 和上面两道闸**分开记**：合成一道闸的话，回前台会把用户已经关掉的语音又放回来。
    private var speechHeld = false
    /// 在飞的任务体。进后台时掐掉会提交 GPU 的那些：队列的闸只挡得住后面的新任务，
    /// 正在推理的这一批/这一句还会一帧帧往 Metal 里塞 command buffer，而那正是崩溃现场。
    /// 每个任务体跑在独立子 Task 里，就是为了能掐它而不连 worker 循环一起取消
    /// （worker 一死，回前台就再没有取任务的人了）。
    private let inFlight = InFlightRegistry()
    private var backgroundObservers: [NSObjectProtocol] = []
    /// worker 取走、还没跑完的句子数。权重不能在合成中途释放（在飞的推理正在用它，
    /// 那是崩溃路径），所以卸载前必须先问这个。
    private var ttsJobsActive = 0
    // 导入消息箱：submitImport 放入消息后立即返回，由专用消费任务处理
    private var importInbox: [Book] = []
    private var importWaiters: [CheckedContinuation<Book?, Never>] = []
    private var importStopped = false

    /// 规则标注只覆盖「正在听的这句 + 往后这么多句」。再远的句子等 LLM 标定：
    /// 正则把单个「！」就推成 0.7 强度（"非常紧张急促，语速加快"），而强指令 +
    /// temperature 0.9 正是这模型输出跑偏音频的条件。
    private static let fastPrimeLookahead = 8
    /// 收听的让路上限。真机上门槛是「用户得先把听到的这本放下」，正常几分钟就放行；
    /// 这个数只在「播放器挂着不动、TTS 又一直失败」时兜底，防止解析永远饿死。
    private static let analysisStarvationTimeout: TimeInterval = 600
    /// 心跳多久之内还算「正在收听」。播放位置每句刷一次，暂停/退走后再没人刷，
    /// 过了这个窗口就认为用户把这本放下了，放行后台解析。取 20s：比一句音频的
    /// 长度宽得多，也不会让解析在用户只是去倒杯水时饿上半个小时。
    private static let listeningGrace: TimeInterval = 20

    /// 一本书在队未完成的解析批次上限。一个 worker 一批几十秒，200 批就是二十几分钟的活，
    /// 够读者一路走下去都有的补；再往前排只是把账摊在任务表里，换不来更早的听感。
    private static let analysisWindowBatches = 200
    /// 一次补产最多读多少章的落库正文。批次数那道闸按批算，这道按章算：一章动辄几十个
    /// 批次，连着几章超长就会一次读进太多正文。
    private static let analysisWindowChapters = 40

    init(analyzer: ChapterAnalyzer, fastAnalyzer: FastChapterAnalyzer, generator: TTSGenerator, chapterStore: ChapterStore, analysisWorkerCount: Int = 2, ttsWorkerCount: Int = 1, memoryBudgetBytes: Int64 = 2 * 1024 * 1024 * 1024, analysisEstimate: Int64 = 600 * 1024 * 1024, ttsEstimate: Int64 = 900 * 1024 * 1024) {
        self.analyzer = analyzer; self.fastAnalyzer = fastAnalyzer; self.generator = generator; self.chapterStore = chapterStore
        analysisWorkers = max(1, analysisWorkerCount); ttsWorkers = max(1, ttsWorkerCount)
        budget = MemoryBudgetManager(budgetBytes: memoryBudgetBytes); self.analysisEstimate = analysisEstimate; self.ttsEstimate = ttsEstimate
        self.memoryBudgetBytes = memoryBudgetBytes
    }

    func start() async {
        guard !started else { return }; started = true; importStopped = false
        // 恢复出来的任务一次入队。逐条 enqueue 是 O(n²)（每条都要扫一遍 pending
        // 找最高优先级），几千个批次就是几秒——而第一次开章正在等它。
        var restoredAnalysis: [EnhancementJob] = []
        var restoredTTS: [EnhancementJob] = []
        for job in await store.recover(windowBatches: Self.analysisWindowBatches) {
            if job.type == .analysisBatch { restoredAnalysis.append(job) } else { restoredTTS.append(job) }
        }
        await analysisQueue.enqueueAll(restoredAnalysis)
        await ttsQueue.enqueueAll(restoredTTS)
        // 起 worker 之前先按「此刻在不在后台」挂一次闸：应用可能就是这样冷启动的
        // （后台音频、推送拉起），那一回不会有通知来告诉这里，而 worker 一跑起来
        // 就是提交 GPU。
        if AppBackgroundGate.shared.isBackground {
            await applyBackground(true, continueTTS: Self.continuesTTSInBackground())
        }
        // 「语音播报」也可能是关着的（用户上次出门前关的）：不起闸就等于答应了一件不做的事——
        // worker 一跑起来就是几百批 LLM 推理，而这一刻没有任何人需要声音。
        await applySpeechEnabled(Self.speechEnabledByUser())
        for _ in 0..<analysisWorkers { workers.append(Task { await self.worker(for: .analysisBatch) }) }
        for _ in 0..<ttsWorkers { workers.append(Task { await self.worker(for: .ttsSentence) }) }
        workers.append(Task { await self.importConsumer() })
        installBackgroundObservers()
    }
    func stop() async {
        workers.forEach { $0.cancel() }; workers.removeAll()
        // 子任务本来就会跟着 `await task.value` 一起被取消，这里再明掐一次：
        // 停队列时留一个还在提交推理的任务在跑，等于把崩溃留给下一次启动。
        inFlight.tasks.forEach { $0.cancel() }
        // 挂起状态必须跟着复位：队列是长命的 actor，留着 suspended=true 的话，
        // 下次 start() 后 worker 一个批次也取不到，后台解析就永远醒不过来了。
        resumeWatch?.cancel(); resumeWatch = nil; analysisSuspended = false
        // 后台门禁的理由位也一样复位：stop/start 之间应用可能已经在前台跑了好久，
        // 留着 true 会让两条队列再也取不到任务。
        analysisHeldByBackground = false; ttsHeldByBackground = false
        // 同理复位「用户关掉语音」：队列上的挂起布尔在 stop() 里被清成了 false，
        // 这里不复位的话，下次 start() 的 applySpeechEnabled 会因为「状态没变」跳过，
        // 于是关着语音却照样跑 GPU。
        speechHeld = false
        removeBackgroundObservers()
        await analysisQueue.setSuspended(false)
        await analysisQueue.stop(); await ttsQueue.stop()
        importStopped = true
        importWaiters.forEach { $0.resume(returning: nil) }; importWaiters.removeAll()
        await store.flushNow()
        started = false
    }

    /// 导入的唯一入口：小说本体此刻已经落库（调用方完成），这里只把
    /// 「请为这本书排产」的消息放进信箱就返回——UI 不会有任何等待。
    func submitImport(_ book: Book) async {
        knownBooks[book.id] = book
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

    /// 导入 = 正文落库 + 解析排产。解析是这本书的后台作业，与「打开哪一章」无关：
    /// 播放路径上只剩 TTS，两边不再同抢 GPU。批次按章序单调排产，所以进度是
    /// 「解析到第几章」，中断（杀进程、切走）后从断点续，不重跑已完成的部分。
    /// 排产量封顶在一个窗口上（`analysisWindowBatches`），跑完一批补一批。
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
        // 重复提交可能带来新章、也可能把正文换了口径：游标回到开头重走一遍。
        // 做过 LLM 的章由任务记录认出来，重走不读盘。
        analysisFrontiers[book.id] = AnalysisFrontier()
        let queued = await fillAnalysisWindow(book)
        print("[Import] 正文落库完成：\(book.title)（\(parsed)/\(book.chapters.count) 章新解析，首批解析窗口已排产 \(queued) 个批次）")
    }

    /// 打开一本旧书时的补排：这本书可能是在「整书排产」之前导入的，队列里没有它的
    /// 分析批次，而播放路径已经不排析了——不在这里补，它就永远不会有 LLM 校准。
    func registerBook(_ book: Book) async {
        // 先记下这本书：人物档案可能要靠章列表去扫，而那一步常常发生在 openChapter 的
        // 并发后台任务里，晚一步就没人知道这本书有哪些章了。
        knownBooks[book.id] = book
        await start()
        _ = await fillAnalysisWindow(book)
    }

    /// 用户停下（暂停/停止）：心跳立即作废，后台解析不用等新鲜窗口过期。
    func reportListeningStopped(bookID: UUID) {
        lastListeningBeat = nil
        Task { await self.resumeAnalysis(reason: "收听结束 book=\(bookID)") }
    }

    /// 用户是否还在收听：最近有没有播放心跳。
    private var isListening: Bool {
        guard let beat = lastListeningBeat else { return false }
        return Date().timeIntervalSince(beat) < Self.listeningGrace
    }

    /// 收听中把分析队列挂起。挂起只是「不再取新批次」，所以权重不能在这里直接卸：
    /// 在飞的那一批正在用 MLX，生成中途释放权重是崩溃路径。队列没被排空时
    /// 由那一批结束后的 `unloadAnalyzerIfIdle`（它有挂起分支）来卸。
    /// `promote`（每句播放心跳都走）与 `recordPlaybackStarted` 都调它，幂等。
    private func suspendAnalysisForListening() async {
        guard isListening, !analysisSuspended else { return }
        analysisSuspended = true
        await syncSuspension()
        print("[Gate] 用户正在收听 → 挂起分析队列，在跑的批次结束后不再取新任务")
        if analysisJobsActive == 0, runningAnalysisJobs == 0 {
            await analyzer.unloadModel()
            print("[Memory] 挂起且无批次在跑 → 卸载 Qwen3-0.6B，权重内存让给 TTS")
        }
        startResumeWatch()
    }

    /// 队列上只有一个布尔，三个理由（收听 / 后台 / 用户关掉语音）都往它上面折算。
    private func syncSuspension() async {
        await analysisQueue.setSuspended(analysisSuspended || analysisHeldByBackground || speechHeld)
        await ttsQueue.setSuspended(ttsHeldByBackground || speechHeld)
    }

    // MARK: - 用户关掉语音

    /// 「语音播报」那个键的当前值。和 UI 同一个默认：没有记录算开（老用户升级后行为不变）。
    private nonisolated static func speechEnabledByUser() -> Bool {
        UserDefaults.standard.object(forKey: PlayerManager.speechEnabledKey) as? Bool ?? true
    }

    /// 关掉语音的唯一落点：UI 拨开关走这里，`start()` 也走这里（冷启动时可能就是关着的，
    /// 而那一刻不会有通知来告诉这里）。
    ///
    /// 关的是「为声音做的所有事」：合成与解析两条队列一起挂住，在飞的那一批/那一句掐掉，
    /// 两边权重全部交还。掐是协作式的（token 边界自查取消），被掐的任务在 `run` 的 catch
    /// 里退回队列等开回来——记成失败的话，用户一开语音就看到满屏「分析失败」。
    /// 队列只是不再取新任务，排产记录一条不丢，所以开回来是接着跑，不是重跑。
    func applySpeechEnabled(_ on: Bool) async {
        guard speechHeld != !on else { return }
        speechHeld = !on

        if speechHeld {
            inFlight.cancelGPUWork(haltingTTS: true)
            await syncSuspension()
            // 在飞的还在用权重，这里只处理「已经没人用了」的那种情形；
            // 有任务在跑则由它结束时的 unloadAnalyzerIfIdle / unloadTTSIfHeld 补上。
            await unloadAnalyzerIfIdle()
            await unloadTTSIfHeld()
            print("[Gate] 语音播报已关闭 → 停止合成与整书解析，模型全部卸载（排队中 "
                + "\(await analysisQueue.pendingCount) 个批次、\(await ttsQueue.pendingCount) 句，开回来接着跑）")
            return
        }

        await syncSuspension()
        print("[Gate] 语音播报已开启 → 恢复合成与解析（排队中 \(await analysisQueue.pendingCount) 个批次、"
            + "\(await ttsQueue.pendingCount) 句）" + (AppBackgroundGate.shared.isBackground ? "｜后台门禁还挂着，实际未放行" : ""))
    }

    /// 进/出后台。由 App 的生命周期通知直接驱动，不靠 SwiftUI 的 `scenePhase`：
    /// 冷启动就落在后台（被后台音频或推送拉起）时 `onChange` 压根不触发，而那一刻的
    /// GPU 提交照样崩。
    ///
    /// **解析这一侧没有开关**：在后台提交 Metal 命令是崩溃，不是偏好。MLX 抛的是
    /// C++ `std::runtime_error`，Swift 的 `catch` 抓不住，进程直接 terminate，所以
    /// 挂起队列（挡新任务）之外还要掐掉在飞的那一批（挡后续 token）——掐是协作式的：
    /// 生成循环每个 token 自查一次 `Task.isCancelled`，被掐的那一步是**停止提交**，
    /// 不是把权重从推理手里抢走（那才是崩溃路径）。卸载仍然等在飞的任务真跑完，
    /// 见 defer 里的 `unloadAnalyzerIfIdle`。
    ///
    /// TTS 那一侧看的是「顺位链上还有没有能在后台出声的一格」，不是「用户选了哪个后端」：
    /// Edge 走网络、Kokoro 走 CPU，都不碰 Metal，选了 Qwen3（MLX）时外层会自己跳过那一格
    /// 用前两个顶上（见 `FallbackTTSService.canTake`）。整条队列挂起等于把退路一起关掉，
    /// 表现就是「一熄屏，放完手上这几句就再也没声，解锁也不回来」。
    /// 在飞的那一句该掐还是掐——那是崩溃防护，不是取舍。
    func applyBackground(_ background: Bool, continueTTS: Bool) async {
        guard background else {
            let wasHeld = analysisHeldByBackground || ttsHeldByBackground
            analysisHeldByBackground = false
            ttsHeldByBackground = false
            await syncSuspension()
            if wasHeld {
                print("[Gate] 回到前台 → 解除后台门禁（解析 \(await analysisQueue.pendingCount) 个批次、"
                    + "合成 \(await ttsQueue.pendingCount) 句继续排队）")
            }
            return
        }

        if !analysisHeldByBackground {
            analysisHeldByBackground = true
            print("[Gate] 进入后台 → 挂起整书解析（后台跑 GPU 必崩，这不是开关）")
        }

        // 先问再&&：Swift 5 模式不允许 await 出现在 && 右边。
        let backendCanRunInBackground = await generator.canSynthesizeInBackground()
        let canKeepSynthesizing = continueTTS && backendCanRunInBackground
        let haltTTS = !canKeepSynthesizing
        if haltTTS, !ttsHeldByBackground {
            ttsHeldByBackground = true
            print("[Gate] 进入后台 → 停止新的语音合成（"
                + "\(continueTTS ? "顺位链上没有能在后台出声的后端：选中的是本地 GPU 模型，而 Edge/Kokoro 或没权重、或已连坏 \(FallbackTTSService.failureThreshold) 句被跳过" : "设置「后台继续朗读」已关闭")"
                + "；已合成的句子照常放完，队列里那些等回前台)")
        }

        // 权重在飞任务还在用，这里只处理「已经没人用了」的那种情形；
        // 有任务在跑则由它结束时的 unloadAnalyzerIfIdle / unloadTTSIfHeld 补上。
        if analysisJobsActive == 0, runningAnalysisJobs == 0 {
            await analyzer.unloadModel()
            print("[Memory] 后台且无批次在跑 → 卸载 Qwen3-0.6B 权重")
        }
        if ttsHeldByBackground, ttsJobsActive == 0 {
            await generator.unloadModel()
            print("[Memory] 后台且无句子在合成 → 卸载 TTS 权重")
        }

        await syncSuspension()
        // 挂闸这一刻是任务表最安静的时刻，也是进程最可能被收掉的前一秒：把去抖里攒下的
        // 改动同步落一次，别让「刚跑完的那几批」在下一次冷启时重烧一遍 GPU。
        await store.flushNow()
    }

    /// 「后台继续朗读」的当前值。直接在通知回调里读 UserDefaults（而不是等 UI 传进来）：
    /// 挂闸的时机由系统决定，不能排在一次 SwiftUI 更新后面。默认开——后台朗读是
    /// 用户预期的功能，只有本地 GPU 后端会被硬性停下。
    private nonisolated static func continuesTTSInBackground() -> Bool {
        UserDefaults.standard.object(forKey: continueTTSInBackgroundKey) as? Bool ?? true
    }

    /// 通知回调里先把在飞的推理**同步**掐掉，再排队挂闸：绕回 actor 改状态要等一次
    /// 调度，而那时候生成循环又多半已经多提交了一帧 Metal 命令——一次就够 terminate。
    /// 挂闸本身（挡掉后面的新任务）留在 actor 里做，见 `applyBackground`。
    private func installBackgroundObservers() {
        guard backgroundObservers.isEmpty else { return }
        let center = NotificationCenter.default
        backgroundObservers = [
            (UIApplication.didEnterBackgroundNotification, true),
            (UIApplication.willEnterForegroundNotification, false),
        ].map { name, isBackground in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                let continueTTS = Self.continuesTTSInBackground()
                if isBackground {
                    self?.inFlight.cancelGPUWork(
                        haltingTTS: TTSEngineType.current.submitsToGPU || !continueTTS
                    )
                }
                Task { await self?.applyBackground(isBackground, continueTTS: continueTTS) }
            }
        }
    }

    private func removeBackgroundObservers() {
        let center = NotificationCenter.default
        backgroundObservers.forEach { center.removeObserver($0) }
        backgroundObservers.removeAll()
    }

    /// 进后台那一刻可能正好有一句在合成，闸只能挡后面的。最后一句跑完再补一次卸载。
    /// 关掉语音同理：那一刻在飞的那一句同样不能中途卸权重。
    private func unloadTTSIfHeld() async {
        guard ttsHeldByBackground || speechHeld, ttsJobsActive == 0 else { return }
        await generator.unloadModel()
        print("[Memory] \(speechHeld ? "语音播报已关闭" : "后台门禁")：在飞的那句合成完 → 卸载 TTS 权重")
    }

    private func startResumeWatch() {
        guard resumeWatch == nil else { return }
        resumeWatch = Task { await self.waitForBeatToExpire() }
    }

    private func waitForBeatToExpire() async {
        while isListening {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        await resumeAnalysis(reason: "心跳过期")
    }

    private func resumeAnalysis(reason: String) async {
        resumeWatch = nil
        guard analysisSuspended else { return }
        // 放开前再看一眼心跳：从「发现过期」到执行这段之间用户可能已经开播，
        // 那时放开就是白烧一批 GPU。继续盯着，下一轮过期再放。
        if isListening {
            startResumeWatch()
            return
        }
        analysisSuspended = false
        await syncSuspension()
        let pending = await analysisQueue.pendingCount
        // 带着 TTS 的现场一起打：放开闸口时若还有音频在排队，这一批 LLM 就是在
        // 和用户耳朵抢同一台机器——「放一半卡住」的正反馈环节就长在这里。
        let ttsPending = await ttsQueue.pendingCount
        let beatAge = lastListeningBeat.map { String(format: "%.0f", Date().timeIntervalSince($0)) } ?? "无"
        print("[Gate] \(reason) → 恢复分析队列（排队中 \(pending) 个批次，TTS 仍在排队 \(ttsPending) 句，距上次播放心跳 \(beatAge)s）"
            + (analysisHeldByBackground ? "｜后台门禁还挂着，实际未放行" : ""))
    }

    /// 把这本书的在队解析批次补到窗口上限，返回本次真正入队的数量。
    ///
    /// 幂等且不叠两份：同一本书正在扫的时候再来一次触发（每完成一批、每次换章、每次开书）
    /// 都等同一份结果。做完的章由任务记录认出来（`analyzedChapters`），不读盘，所以反复
    /// 补产不会把整本书的正文再解一遍——那是旧「整书排产」那条路 25 秒磁盘活的来源。
    @discardableResult
    private func fillAnalysisWindow(_ book: Book) async -> Int {
        if let running = analysisFills[book.id] { return await running.value }
        guard analysisFrontiers[book.id]?.exhausted != true else { return 0 }
        let task = Task { await self.scanAnalysisWindow(book) }
        analysisFills[book.id] = task
        let queued = await task.value
        analysisFills[book.id] = nil
        return queued
    }

    /// 窗口空出一格就补一格。先看在队数：还满着就连章列表都不碰，所以这条可以挂在
    /// 「每批完成」和「每次换章」这种高频触发上。
    private func refillAnalysisWindow(bookID: UUID) async {
        guard analysisFrontiers[bookID]?.exhausted != true, let book = knownBooks[bookID] else { return }
        let open = await store.analysisOpenCount(bookID: bookID)
        guard open < Self.analysisWindowBatches else { return }
        _ = await fillAnalysisWindow(book)
    }

    private func scanAnalysisWindow(_ book: Book) async -> Int {
        let started = CFAbsoluteTimeGetCurrent()
        let open = await store.analysisOpenCount(bookID: book.id)
        guard open < Self.analysisWindowBatches else { return 0 }
        let done = await store.analyzedChapters(bookID: book.id)
        var frontier = analysisFrontiers[book.id] ?? AnalysisFrontier()
        // 档案没建好才顺手把正文攒着：这一轮本来就要读落库正文，人物分析再读一遍
        // 就是两倍的磁盘活。已建好（绝大多数情况）就一行都不攒。
        // 段落标记跟着一起攒：只有引号配对那一条判定用得到它（按段落数才数得对，
        // 见 `CharacterAnalysis.quotePairing`），别的扫描都不看它。
        var texts: [[String]]? = CharacterRoster.shared.isBuilt(bookID: book.id) ? nil : []
        var paragraphStarts: [[Bool]]? = texts == nil ? nil : []
        var planned: [EnhancementJob] = []
        var rank = frontier.rank
        var cursor = frontier.chapter
        var scanned = 0
        var missing = 0
        while cursor < book.chapters.count,
              open + planned.count < Self.analysisWindowBatches,
              scanned < Self.analysisWindowChapters {
            // 「清空音频与标注」会掐掉这一轮：它手上的章列表已经作废，扫下去只会把游标
            // 推到书尾，把重新排产的路堵死。
            if Task.isCancelled { return 0 }
            let descriptor = book.chapters[cursor]
            cursor += 1
            if done.contains(descriptor.id) { continue }
            // 每章都要解一次落库正文才知道有几句：这是纯后台的磁盘活，
            // 但它现在跑在点击之后的后台 Task 上，不节流就会跟开章抢盘。
            guard let chapter = await chapterStore.load(bookID: book.id, chapterID: descriptor.id) else {
                // 正文还没落库（刚清完缓存、或导入还没铺到这一章）。不能把这种章当成做完。
                missing += 1
                continue
            }
            let jobs = analysisJobs(chapter: chapter, bookID: book.id, rank: rank)
            planned.append(contentsOf: jobs)
            rank += jobs.count
            scanned += 1
            texts?.append(chapter.sentences.map(\.text))
            paragraphStarts?.append(chapter.sentences.map(\.startsParagraph))
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        frontier.chapter = cursor
        frontier.rank = rank
        frontier.chaptersRead += scanned
        // 扫到书尾、且没有读不到的章，才算排产到头：剩下的批次都已经在账上，往后只等它们跑完。
        // 有章没正文就留着不结论，等导入把正文铺下来（那条路和换章都会再触发一次补产）。
        // 清缓存、人工重试会把游标整个重置。
        frontier.exhausted = cursor >= book.chapters.count && missing == 0
        analysisFrontiers[book.id] = frontier
        // 档案必须排在批次入队之前：入队之后 worker 立刻就能合成出第一句音频，
        // 而「谁用哪把声音」一旦定过就钉在缓存里了——先扫书，后面的每一句才都用同一套口径。
        // 但这里只扫了窗口那几十章，不能钉 `complete`：整本扫完是后台补档那条路的结论
        // （`backfillRoster` 扫到章尾才钉），在这里钉死会把后半本的人物留在默认嗓上。
        if let texts, !texts.isEmpty {
            await scanRoster(
                bookID: book.id,
                texts: texts,
                paragraphStarts: paragraphStarts ?? [],
                scannedChapters: frontier.chaptersRead,
                complete: false
            )
        }
        // 一次性落盘：逐条 upsert 会把「整份 jobs 重新编码 + 原子写」做 N 次。
        let report = await store.upsertAll(planned)
        await analysisQueue.enqueueAll(report.fresh)
        if report.created > 0 || report.overlapped > 0 {
            // overlapped 就是「与恢复/上次排产重叠」的那部分：这批键在表里本来就已经是
            // pending，重排只抬了优先级。这个数不为 0 时，账面才会看着像「排了 6,559 个、
            // 又恢复了 13,116 个」，实际是同一批活被数了两遍。
            print("[Analysis] 《\(book.title)》窗口补产 章\(frontier.chapter)/\(book.chapters.count)："
                + "新建 \(report.created) / 重叠 \(report.overlapped) / 已完成跳过 \(report.skipped)，"
                + "扫 \(scanned) 章（\(done.count) 章整本已做过不读盘），"
                + "在队未完成 \(open + report.fresh.count)/\(Self.analysisWindowBatches) 批，"
                + "耗时 \(String(format: "%.0f", (CFAbsoluteTimeGetCurrent() - started) * 1000))ms（后台，只在没有收听时跑）")
        }
        // 整本人物档案仍要在后台补完：窗口只保证前沿那几十章有证据，后半本靠这条。
        if !CharacterRoster.shared.isBuilt(bookID: book.id) { startRosterBackfill(bookID: book.id) }
        // 自愈：队列挂起只该由「正在收听」引起。排产时已经没有心跳却还挂着，
        // 说明状态对不上（例如 stop/start 的边界），在这里放开，
        // 不然后台解析会永远醒不过来。
        if analysisSuspended, !isListening {
            await resumeAnalysis(reason: "排产时已无收听")
        }
        return report.fresh.count
    }

    // MARK: - 人物档案

    /// 合成这一句之前，先把「这个人用哪把声音」拿到手上。
    ///
    /// 要卡这个点，是因为音频按句缓存、而声音按人定：缺档案时判出来的嗓和补齐之后
    /// 判出来的可能不是同一个，那正是「同一个人两句两个声音」。
    ///
    /// 但**只等这一章和它前面几章**，不等整本书：老书第一次出声时等整本扫描，实测把
    /// 第一句音频拖到 28 秒（绍宋 443 章扫了 26 秒）。整本改成后台增量补档，
    /// 而档案「判出性别就钉死」，所以后补的证据只会让还没判的人定下来——那些人名
    /// 早录的那几句由漂移分支认出来、退回重录，不会留下半本书两种嗓。
    private func ensureRoster(bookID: UUID, chapterID: UUID) async {
        guard !CharacterRoster.shared.isBuilt(bookID: bookID) else { return }
        let window = rosterWindow(bookID: bookID, chapterID: chapterID)
        let seen = rosterScanned[bookID] ?? []
        let missing = window.filter { !seen.contains($0) }
        if !missing.isEmpty {
            var union = rosterScanned[bookID] ?? []
            union.formUnion(missing)
            await scanRoster(bookID: bookID, chapterIDs: missing, scannedSoFar: union.count)
            rosterScanned[bookID] = union
        }
        startRosterBackfill(bookID: bookID)
    }

    /// 往前多读几章：人物第一次出场时正文通常已经把性别写明白了（「那少年」「王婶」），
    /// 所以窗口里的证据几乎总能判出这个人，不必等整本书。
    private static let rosterWindowChapters = 6

    private func rosterWindow(bookID: UUID, chapterID: UUID) -> [UUID] {
        guard let chapters = knownBooks[bookID]?.chapters,
              let position = chapters.firstIndex(where: { $0.id == chapterID })
        else { return [chapterID] }
        let from = max(0, position - Self.rosterWindowChapters)
        return chapters[from...position].map(\.id)
    }

    /// 整本补档挂在后台，一次一章、边扫边并。它是唯一会读完整本书正文的地方。
    private func startRosterBackfill(bookID: UUID) {
        guard rosterBuilds[bookID] == nil, !CharacterRoster.shared.isBuilt(bookID: bookID) else { return }
        rosterBuilds[bookID] = Task { await self.backfillRoster(bookID: bookID) }
    }

    private func backfillRoster(bookID: UUID) async {
        // 有书单按书单来（章序准），只有那种「只知道 bookID」的场合才去磁盘目录里数。
        // 不能写成 `knownBooks[…]?.… ?? await …`：?? 的右边是 autoclosure，进去就不支持并发。
        let ids: [UUID]
        if let book = knownBooks[bookID] {
            ids = book.chapters.map(\.id)
        } else {
            ids = await chapterStore.chapterIDs(bookID: bookID)
        }
        var texts: [[String]] = []
        var starts: [[Bool]] = []
        var covered = 0
        var read = 0
        var aborted = false
        for id in ids {
            // 「清空音频与标注」会挂掉这个任务：那种时候扫到底只会钉出一份空档案，
            // 而 complete 那份会把重扫挡住——人人回到默认嗓，正是这次要治的东西。
            if Task.isCancelled { aborted = true; break }
            // 导入排产那条路可能已经先把整本扫完了（它会直接钉 complete），别再扫第二遍。
            // 句柄要放手：留着它，将来「清空音频与标注」之后就没法再起一轮补档了。
            if CharacterRoster.shared.isBuilt(bookID: bookID) { rosterBuilds[bookID] = nil; return }
            guard let chapter = await chapterStore.load(bookID: bookID, chapterID: id) else { continue }
            texts.append(chapter.sentences.map(\.text))
            starts.append(chapter.sentences.map(\.startsParagraph))
            covered += 1
            read += 1
            // 让一让盘：点开一章取正文比补档重要，几百章一口气读会把那 1 秒预算吃掉。
            try? await Task.sleep(nanoseconds: 2_000_000)
            if texts.count >= Self.rosterWindowChapters + 1 {
                await scanRoster(bookID: bookID, texts: texts, paragraphStarts: starts,
                                 scannedChapters: covered, complete: false)
                texts = []
                starts = []
            }
        }
        guard !aborted else {
            rosterBuilds[bookID] = nil
            return
        }
        if !texts.isEmpty {
            await scanRoster(bookID: bookID, texts: texts, paragraphStarts: starts,
                             scannedChapters: covered, complete: false)
        }
        // 一个章都没读到（正文还没落库、或盘被回收了）不能钉 complete：那等于把这本书
        // 永久钉在「档案已建好、里面没人」上。留着标记不建，下次合成再补一轮。
        // 钉之前再问一次取消：清盘可能就发生在这几毫秒里。
        if !Task.isCancelled, read > 0 || ids.isEmpty {
            await scanRoster(bookID: bookID, texts: [], paragraphStarts: [], scannedChapters: ids.count, complete: true)
            rosterScanned[bookID] = Set(ids)
        }
        rosterBuilds[bookID] = nil
    }

    private func scanRoster(bookID: UUID, chapterIDs: [UUID], scannedSoFar: Int) async {
        var texts: [[String]] = []
        var starts: [[Bool]] = []
        texts.reserveCapacity(chapterIDs.count)
        for id in chapterIDs {
            guard let chapter = await chapterStore.load(bookID: bookID, chapterID: id) else { continue }
            texts.append(chapter.sentences.map(\.text))
            starts.append(chapter.sentences.map(\.startsParagraph))
        }
        await scanRoster(bookID: bookID, texts: texts, paragraphStarts: starts,
                        scannedChapters: scannedSoFar, complete: false)
    }

    /// 扫一批正文，把还没判出性别的人补进档案。`texts` 是调用方已经读好的章文本
    /// （整书排产那条路顺手就有；窗口扫描与后台补档自己去读盘）。
    /// `paragraphStarts` 与 `texts` 逐章对齐：引号配对按**段落**数（见 ``CharacterAnalysis/quotePairing(_:_:)``），
    /// 少了这份标记就只能退化成一句一段，那会把正常排版的书误判成「引号不配」而关掉承前。
    /// `scannedChapters` 是这本书**累计**扫过的章数，只进日志与档案的进度字段，判定不看它。
    private func scanRoster(bookID: UUID, texts: [[String]], paragraphStarts: [[Bool]],
                            scannedChapters: Int, complete: Bool) async {
        let started = CFAbsoluteTimeGetCurrent()
        // 字符串扫描放到 actor 外面跑：它动辄上百毫秒，而在 actor 里跑的话
        // 这段时间里 openChapter、播放心跳全都得排队等着，看着就是「点了没反应」。
        // 引号配对也在这里一起数：它同样是逐句扫字符，绝不能挪到 openChapter 那条 await 上。
        let scan = await Task.detached(priority: .utility) {
            (CharacterAnalysis.analyze(chapterTexts: texts),
             CharacterAnalysis.quotePairing(chapters: texts, paragraphStarts: paragraphStarts))
        }.value
        guard CharacterRoster.shared.merge(
            bookID: bookID,
            people: scan.0,
            scannedChapters: scannedChapters,
            complete: complete,
            quotes: scan.1
        ) else { return }

        let title = knownBooks[bookID]?.title ?? String(bookID.uuidString.prefix(8))
        let ms = String(format: "%.0f", (CFAbsoluteTimeGetCurrent() - started) * 1000)
        // 收尾那一次没有正文（只把状态钉成「整本扫完」），别让它看着像「这本书没人说话」。
        // 入档闸门现在按全书累计，所以「本轮」那一截只说明这批看到了谁；
        // 档案里到底有多少人是另一件事，日志里必须给这一句——不然「这批达标 3 个」
        // 会被读成「这本书只有 3 个人有嗓」。
        let tally = texts.isEmpty ? "不新增人名" : CharacterAnalysis.summary(scan.0)
        // 承前借名的门槛在这里报出来：它按整本书累计的引号配对**段落**样本判，实机上「这句为什么没借」
        // 只能从这一行看。total 还没攒到 200 时一律是「关」，那两个数字就是原因。
        let quotes = CharacterRoster.shared.quotePairing(bookID: bookID)
        print("[Roster] 《\(title)》\(tally)"
            + "｜档案累计 \(CharacterRoster.shared.names(bookID: bookID).count) 人"
            + "｜别名 \(CharacterRoster.shared.aliasMap(bookID: bookID).count) 条"
            + "｜承前\(CharacterRoster.shared.allowsParagraphCarry(bookID: bookID) ? "开" : "关")（引号不配 \(quotes.unbalanced)/\(quotes.total) 段）"
            + "｜本轮 \(texts.count) 章 \(ms)ms，累计 \(scannedChapters) 章"
            + (complete ? "｜整本扫完，判过性别的一个字不改" : "｜整本仍在后台补"))
    }

    /// The only chapter-open entry point: parsed text -> promotion.
    /// 「点开一章 → 看见正文」的预算只算这两段：启动（首次含任务表恢复）+ 取正文。
    /// 排产挂在它们后面，不再计入出正文的时间。
    ///
    /// `at` 是这次打开要落在哪一句（续读时就是上次那句）。它必须由调用方给，
    /// 不能「先按章首排产、调用方再补一次 reportPosition」：那是两次排产在抢同一个
    /// 位置，落后的那次会把 interactive 的锚点拽回句 0，续读的那句反而一直等音频。
    func openChapter(_ descriptor: ChapterDescriptor, bookID: UUID, context _: StoryContext, at sentence: Int = 0) async throws -> Chapter {
        let t0 = CFAbsoluteTimeGetCurrent()
        await start()
        let t1 = CFAbsoluteTimeGetCurrent()
        let chapter = try await loadParsedChapter(descriptor, bookID: bookID)
        let t2 = CFAbsoluteTimeGetCurrent()
        func ms(_ from: Double, _ to: Double) -> String { String(format: "%.0f", (to - from) * 1000) }
        print("[Open] chapter=\(chapter.index) 句数=\(chapter.sentences.count) 出正文=\(ms(t0, t2))ms（启动=\(ms(t0, t1)) 取正文=\(ms(t1, t2))）")
        // 排产不能挡正文：它要规则标注、把其他章的 interactive 任务降级、再逐句写
        // 任务表。正文此刻已经在手上，参数和音频由 promote 的 emit 走 chapterUpdates
        // 那条流补回来——UI 本来就是按这条流更新音频的，晚几毫秒看不出来。
        // 上次记住的句序可能超出这一章（断句规则改过、章重切过），按句数收回来。
        let anchor = max(0, min(sentence, chapter.sentences.count - 1))
        if chapter.sentences.isEmpty {
            // 图片章/空白页没有后续 emit：漏掉这一次广播，页面就永远挂着「校准中」，
            // 队列里一个任务都没有，看起来就是卡死。这种章不排产，等得起。
            return await promote(chapter: chapter, bookID: bookID, sentence: anchor)
        }
        Task { await self.promote(chapter: chapter, bookID: bookID, sentence: anchor) }
        return chapter
    }

    /// 只取正文，一行调度都不排：给阅读页预取相邻一章的分页用。
    ///
    /// 为什么不能复用 `openChapter`：它出门前必过 `promote`——按那一句重排音频优先级、
    /// 把别的章的 interactive 任务降级、再写任务表。读者只是往后多看一眼，
    /// 凭什么把声音的锚点挪到下一章去。取正文这一段两边是同一份（`loadParsedChapter`）。
    func readChapter(
        _ descriptor: ChapterDescriptor,
        bookID: UUID
    ) async throws -> Chapter {
        try await loadParsedChapter(descriptor, bookID: bookID)
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

    /// 说话人提取口径升级后，给已经落库的老章节补一次「这句是谁说的」。
    ///
    /// 每章只跑一次（版本号跟着正文一起落库），代价见 `[Annot]` 日志。之所以只重算
    /// 说话人而不重跑分析：情绪那些参数可能有 LLM 校准过的好结果，正则冲掉它是倒退；
    /// 而正文一个字都不动，声音真的变了的那几句交给 ``purgeReclaimedAudio`` 认出、
    /// 单独退回重录。
    ///
    /// 挂在 TTS worker 上而不是 `loadParsedChapter` 里：整章重算实测 300 句 110ms（Mac 直编），
    /// 手机上还要慢几倍，再加上一次整章落库——放在开章那条 await 上就会吃掉「1 秒出正文」
    /// 的一半预算。音频这一侧反正必须等档案，等这一次迁移不额外排队。
    private func migrateSpeakers(_ chapter: Chapter, bookID: UUID, protecting: Set<Int>) async -> Chapter {
        guard chapter.annotationVersion != DialogueAttribution.annotationVersion else { return chapter }
        let started = CFAbsoluteTimeGetCurrent()
        var migrated = await fastAnalyzer.refreshSpeakers(chapter, bookID: bookID)
        migrated.annotationVersion = DialogueAttribution.annotationVersion
        try? await chapterStore.save(chapter: migrated, bookID: bookID)
        await cache.set(migrated)
        // 正文一个字没变，但「这句是谁说的」变了：对话的排版标记跟着改，页面得看见。
        emit(migrated)
        // 名字变了 → 该用哪把声音也可能变，当场对账一次（不等下次开章）。
        migrated = await purgeReclaimedAudio(migrated, bookID: bookID, protecting: protecting)
        let named = migrated.sentences.reduce(0) { $1.characterName == nil ? $0 : $0 + 1 }
        print("[Annot] chapter=\(chapter.index) 说话人按新口径重算：\(chapter.sentences.count) 句里 \(named) 句认出了人名，"
            + "耗时 \(String(format: "%.0f", (CFAbsoluteTimeGetCurrent() - started) * 1000))ms（一次性，正文/情绪都不动，只有声音变了的那几句重录）")
        return migrated
    }

    /// 走落库这条路就没有 parser 兜着了，而音频住在 `Library/Caches` 下——系统随时
    /// 能回收它。留着指向空气的 `audioURL`，播放器会直接跳过这一句，而 ``scheduleTTS``
    /// 见 audioURL 非空也不排产，句子就永久静音。排产记录同样要退回 pending：
    /// 任务还是 .completed 的话 `upsertAll` 认为做过，重排不进去。
    ///
    /// 同一个循环还管「声音过期」：档案是**边听边补**的（先扫这一章附近几章，整本在后台补），
    /// 而那之前这句已经按旧口径（有名角色也一律无名那把嗓）录过了；说话人口径升级后
    /// ``migrateSpeakers`` 重算的名字同样会撞上这一条。`audioURL` 非空就永远排不进产，
    /// 不在这里开口子，这本书的对话会一直用错的声音，`produce` 里那点校验根本没有机会跑。
    ///
    /// `protecting` 是 worker 正在合成的那几句：漂移退回把它们也退回的话，等于任务表
    /// 和音频自己跟自己抢（这一轮录完，下一轮又看见一条指向同一句的 pending）。
    private func purgeReclaimedAudio(
        _ chapter: Chapter,
        bookID: UUID,
        protecting: Set<Int> = []
    ) async -> Chapter {
        var chapter = chapter
        var reclaimed: [Int] = []
        var drifted: [Int] = []
        // 正在播的那一句放过：播放器是按 URL 拿着 AVPlayerItem 在读的，
        // 这里把它退回待合成，队列立刻就能轮到它，`produce` 会先删旧文件再录——
        // 文件在播放中途消失，表现是当前这句哑掉。下次开章再纠它。
        let playing = readingPositions[chapter.id]
        for i in chapter.sentences.indices {
            guard let url = chapter.sentences[i].audioURL else { continue }
            if !FileManager.default.fileExists(atPath: url.path) {
                chapter.sentences[i].audioURL = nil
                chapter.sentences[i].duration = nil
                chapter.sentences[i].audioStatus = .pending
                reclaimed.append(i)
                continue
            }
            // 没记声音的老数据按「旧口径」折算，不是一律判错：否则第一次开章会把
            // 整本书的旁白（本来就用对了 Uncle_Fu）全删了重录。
            let expected = VoiceResolution.resolve(sentence: chapter.sentences[i], chapter: chapter, bookID: bookID)
            let recorded = chapter.sentences[i].recordedVoiceID ?? VoiceResolution.legacy(for: chapter.sentences[i])
            guard recorded != expected, i != playing, !protecting.contains(i) else { continue }
            chapter.sentences[i].audioURL = nil
            chapter.sentences[i].duration = nil
            chapter.sentences[i].audioStatus = .pending
            // recordedVoiceID 留着：磁盘上那个文件确实还是那把声音，
            // `produce` 靠它认出该删的是哪一个。
            drifted.append(i)
        }
        guard !reclaimed.isEmpty || !drifted.isEmpty else { return chapter }
        for i in reclaimed + drifted { await store.reopenTTS(chapterID: chapter.id, sentenceIndex: i) }
        chapter.ttsStatus = .partial
        chapter.audioStatus = .generating
        try? await chapterStore.save(chapter: chapter, bookID: bookID)
        await cache.set(chapter)
        emit(chapter)
        if !reclaimed.isEmpty {
            print("[Cache] chapter=\(chapter.index) 有 \(reclaimed.count) 句音频已被系统回收，退回待合成重排")
        }
        if !drifted.isEmpty {
            print("[Voice] chapter=\(chapter.index) 有 \(drifted.count) 句的声音与人物档案不符，退回待合成（只重录这些句，旁白与无名对话不动）")
        }
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
        // 档案就在解析树里，跟着一起删了；内存里那份也必须丢掉，
        // 不然下一轮扫书会被「已经建好」的假象挡住，重录又拿回旧口径。
        CharacterRoster.shared.forget(bookID: bookID)
        // 正在跑的补档也必须掐掉并忘掉进度：它手上那份正文已经没了，扫到底会钉出一份
        // 「已建好但里面没人」的档案，而「已建好」正好挡住重扫。
        rosterBuilds[bookID]?.cancel()
        rosterBuilds[bookID] = nil
        rosterScanned[bookID] = nil
        let dropped = await store.dropBook(bookID: bookID)
        // 去抖写盘留 250ms 窗口，但「清空」是用户接下来所有判断的前提：
        // 不立刻落盘，进程此刻被杀就会留下一张指向已删文件的任务表。
        await store.flushNow()
        await cache.removeAll()
        interactiveRequests[bookID] = nil
        lastListeningBeat = nil
        // 标注和任务记录都被丢了，这本书必须能重新排产解析：游标回到开头，
        // 正在扫的那一份掐掉（它手上的章列表和 done 集合已经作废）。
        analysisFills[bookID]?.cancel()
        analysisFills[bookID] = nil
        analysisFrontiers[bookID] = nil
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
        // 只有换章那一下才惊动排产：窗口是滚动的，读者往前走了，前沿也该往前挪一格。
        // 逐句推进不触发——那会让每句播放都多走一遍任务表。
        if readingChapters[bookID] != chapterID {
            readingChapters[bookID] = chapterID
            Task { await self.refillAnalysisWindow(bookID: bookID) }
        }
        guard let chapter = await chapterStore.load(bookID: bookID, chapterID: chapterID) else { return }
        await promote(chapter: chapter, bookID: bookID, sentence: sentenceIndex)
        // §5 相邻章节档位：下一章 > 上一章 > 远处后台（100）
        await promoteNeighbor(nextChapterID, bookID: bookID, base: 500)
        await promoteNeighbor(prevChapterID, bookID: bookID, base: 400)
    }

    /// UI「重试」入口（§14 情况5）：该章 failed 任务复位并立即做 interactive 提升。
    func retryChapter(bookID: UUID, chapterID: UUID) async {
        await start()
        let revived = await store.resetFailed(chapterID: chapterID)
        for job in revived { await queue(job) }
        // 人工重试是唯一能把终态捞回来的入口：游标必须回到开头，否则那一批
        // 已经在游标后面，窗口扫描永远不会再提议它（done 集合这一轮已经不含那章了）。
        // 书单还没记下这本书时什么都不做——换章和开书那条路会再触发一次补产。
        if let book = revived.first.flatMap({ knownBooks[$0.bookID] }) {
            analysisFrontiers[book.id] = AnalysisFrontier()
            _ = await fillAnalysisWindow(book)
        }
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
        lastListeningBeat = now
        Task { await self.suspendAnalysisForListening() }
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
        // 邻章只排音频：解析是这本书的后台作业（窗口补产），不在这里按打开动作插队
        let due = chapter.sentences.indices
            .filter { chapter.sentences[$0].analysisStatus == .completed }
            .map { (index: $0, priority: base) }
        await scheduleTTS(chapter: chapter, bookID: bookID, sentences: due, mode: .background)
    }

    @discardableResult
    private func promote(chapter: Chapter, bookID: UUID, sentence: Int) async -> Chapter {
        readingPositions[chapter.id] = sentence
        lastListeningBeat = Date()
        await suspendAnalysisForListening()
        // 规则先把播放位置附近这一窗填满（无 GPU、毫秒级），本窗立刻可播；
        // 窗外的句子用「已落库的解析结果」，没解析到的句子只缺校准、不缺参数。
        var ready = await prime(chapter: chapter, bookID: bookID, from: sentence)
        // §19.12 只保留最近一次打开意图：其他章节的 interactive 任务全部降级
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
        // 打开章节不再排解析：解析是导入时起的后台作业（`fillAnalysisWindow`），
        // 播放这条路径上只有 TTS。窗口的句子由上面的规则填满，播放头往前推
        // 一格窗口就跟着滑一格，所以解析没跑到的章节照样能连续播，只是听感没被校准。
        // 只为「参数已就绪」的句子排 TTS：本窗（规则）+ 解析已跑过的句子。
        let due = ready.sentences.indices
            .filter { ready.sentences[$0].analysisStatus == .completed }
            .map { (index: $0, priority: priority($0, near: sentence)) }
        await scheduleTTS(chapter: ready, bookID: bookID, sentences: due, mode: .interactive, requestedAt: t0)
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
        var primed = await fastAnalyzer.prime(chapter, bookID: bookID, in: window)
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000

        primed.audioStatus = .generating
        primed.analysisStatus = .running
        try? await chapterStore.save(chapter: primed, bookID: bookID)
        await cache.set(primed)
        emit(primed)
        print("[Fast] 规则标注窗口 [\(lower),\(upper)) 内 \(missing)/\(window.count) 句耗时 \(String(format: "%.1f", ms))ms → 本窗直接开播，远处句子等 LLM 定参数")
        return primed
    }
    /// 只造任务、不落盘不入队：持久化与入队由窗口补产（`scanAnalysisWindow`）一次性做。
    private func analysisJobs(chapter: Chapter, bookID: UUID, rank: Int) -> [EnhancementJob] {
        let batches = (chapter.sentences.count + 9) / 10
        var jobs: [EnhancementJob] = []
        jobs.reserveCapacity(batches)
        for batch in 0..<batches {
            let key = "analysis:\(bookID.uuidString):\(chapter.id.uuidString):\(batch)"
            // 整书按章序单调排产：越靠前的章节越先解析，进度才是「解析到第几章」。
            // 这个数只在分析队列内部比大小；跨类型（和 TTS 抢内存）的排序在 `run`
            // 的 gatePriority 里另算，别把它当成内存闸口的优先级。
            jobs.append(EnhancementJob(id: key, bookID: bookID, chapterID: chapter.id, type: .analysisBatch, batchIndex: batch, sentenceIndex: nil, state: .pending, priority: max(1, 100_000 - rank - batch), mode: .background, memoryBytes: analysisEstimate, attempts: 0, createdAt: Date(), startedAt: nil, finishedAt: nil, error: nil))
        }
        return jobs
    }
    /// 一次排入若干句的音频。逐句入队的话，每条都要跨 actor 写一次任务表、再让队列
    /// 扫一遍 pending，一章一千句就是 O(n²)——而 `promote` 在每次换句时都会跑完这一整轮。
    /// 已出过音频的句子跳过：`audioURL` 非空还排产，worker 会把重复合成当成有效工作。
    private func scheduleTTS(chapter: Chapter, bookID: UUID, sentences: [(index: Int, priority: Int)], mode: JobPriorityMode, requestedAt: Date = Date()) async {
        // 关掉语音后不再排产合成：这些句子在用户重新开章时自会重新排上，
        // 而把整章几百条任务压在队列里等开回来，只是一份没人读、还要落盘的排产记录。
        guard !speechHeld else { return }
        var jobs: [EnhancementJob] = []
        jobs.reserveCapacity(sentences.count)
        for item in sentences {
            guard chapter.sentences.indices.contains(item.index), chapter.sentences[item.index].audioURL == nil else { continue }
            let key = "tts:\(bookID.uuidString):\(chapter.id.uuidString):\(item.index)"
            jobs.append(EnhancementJob(id: key, bookID: bookID, chapterID: chapter.id, type: .ttsSentence, batchIndex: nil, sentenceIndex: item.index, state: .pending, priority: item.priority, mode: mode, memoryBytes: ttsEstimate, attempts: 0, createdAt: requestedAt, startedAt: nil, finishedAt: nil, error: nil))
        }
        guard !jobs.isEmpty else { return }
        let fresh = await store.upsertAll(jobs).fresh
        await ttsQueue.enqueueAll(fresh)
    }
    private func queue(_ job: EnhancementJob) async { if job.type == .analysisBatch { await analysisQueue.enqueue(job) } else { await ttsQueue.enqueue(job) } }

    private func worker(for type: EnhancementJobType) async {
        while !Task.isCancelled, let job = await (type == .analysisBatch ? analysisQueue : ttsQueue).next() {
            // 任务体放进子 Task：进后台要能掐掉「正在跑的那一个」而不把 worker 循环
            // 一起取消（worker 一死，回前台就再没有取任务的人了）。`await task.value`
            // 是取消感知的：worker 自己被 stop() 取消时，子任务也一起被取消，
            // 所以两条路都不漏。
            let task = Task { await self.run(job) }
            inFlight.set(job.id, task: task, type: type)
            await task.value
            inFlight.clear(job.id)
        }
    }

    private func run(_ original: EnhancementJob) async {
        var job = original
        // 关掉语音这一路再来一道闸：worker 可能正好在挂闸之前取走了一个任务，那时候
        // 谁都不知道用户已经把它关了。退回队列不算失败——开回来照原样接着跑。
        // （这一步的重新入队排在 syncSuspension 之后，落下时闸已经关好，不会被同一个
        // worker 立刻再取走，所以这里不是自旋。）
        if speechHeld {
            job.state = .pending; job.startedAt = nil; job.error = nil
            await store.update(job); await queue(job)
            return
        }
        // `.running` 不落盘：worker 每取一个任务就整份重写任务表的话，一晚上就是几千次
        // 全表编码，而这一次写盘换不来任何「崩溃后少跑一批」的收益——disk 上留 pending
        // 的原样，recover 翻回 pending，幂等。代价是「批次把进程搞崩」这种失败不会累计
        // 重试次数（每次冷启都重跑那一批）；真出现那种崩溃要靠 [Scheduler] failed 那行看，
        // 而不是靠这里记账。attempts 仍然在内存里加，任务收尾时随结果一起落盘。
        job.state = .running; job.startedAt = Date(); job.attempts += 1
        let beforeMemory = MemoryProbe.snapshot()
        var analysisJobPicked = false
        var analysisSlotTaken = false
        var ttsJobPicked = false
        defer {
            if analysisJobPicked {
                if analysisSlotTaken { runningAnalysisJobs = max(0, runningAnalysisJobs - 1) }
                analysisJobsActive = max(0, analysisJobsActive - 1)
                Task { await self.unloadAnalyzerIfIdle() }
                // 这一批无论做成什么样，窗口都空出了一格（终态失败也算做完的章不再提议）。
                // 挂在收尾而不是挂在成功里：一次让位/失败如果不补，窗口就永久缺几格，
                // 后台解析会在跑到某处后自己停下。
                Task { await self.refillAnalysisWindow(bookID: job.bookID) }
            }
            if ttsJobPicked {
                ttsJobsActive = max(0, ttsJobsActive - 1)
                Task { await self.unloadTTSIfHeld() }
            }
        }
        if job.type == .ttsSentence {
            ttsJobPicked = true
            ttsJobsActive += 1
        }
        if job.type == .analysisBatch {
            analysisJobPicked = true
            analysisJobsActive += 1
            guard await waitForListeningToStop(job: job) else {
                job.state = .pending; job.startedAt = nil; job.error = "等待音频缓冲时被取消"
                await store.update(job); await analysisQueue.enqueue(job); return
            }
            analysisSlotTaken = true
            runningAnalysisJobs += 1
        }
        // 内存闸口是解析和 TTS **共用**的，两边的优先级数字必须跨类型可比：
        // 分析批次是 99950 这种五位数，TTS 最高才 10000，于是播放器会排在一个
        // 它自己挤不进去的分析批次后面一起饿死（`release` 只放队首，队首等不到就
        // 全体等待）。真机日志里 `budget reserved=1578MB available=469MB` 之后
        // TTS 停在句121 不再出声，就是这个形状。播放是用户这一秒的体验，
        // 分析晚跑几十秒无所谓，所以把 TTS 抬到绝对高位。
        let gatePriority = job.type == .ttsSentence ? job.priority + 1_000_000 : job.priority
        guard await budget.acquire(job.memoryBytes, priority: gatePriority) else {
            // 预估本身就大于全局预算，这不是「再试一次可能挤得进」：acquire 只在
            // requested <= budgetBytes 时返回 false，重试多少次都是同一句 false。
            // 按用尽额度钉成终态，`recover` 与窗口排产都不会再把它外放，
            // 否则每次冷启都重跑一遍这种注定不做的批次（日志里那几千个 failed 就是这么来的）。
            job.state = .failed; job.attempts = EnhancementJobStore.maxAutoRetries
            job.finishedAt = Date(); job.error = "Memory estimate exceeds global budget"
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
            // 只有合成要卡这道闸：解析不碰声音，而卡在那儿会把第一句音频白白推迟一次整本扫盘。
            if job.type == .ttsSentence { await ensureRoster(bookID: job.bookID, chapterID: job.chapterID) }
            guard var chapter = await chapterStore.load(bookID: job.bookID, chapterID: job.chapterID) else { throw CocoaError(.fileNoSuchFile) }
            if job.type == .ttsSentence {
                // 老章节的说话人补算挂在这儿，不挂在开章那条 await 上：这一句马上要拿名字去查档案，
                // 而「谁在说话」变了的其他句也在这里一起对账。正在合成的这句要护住——
                // 漂移分支把它退回待合成，等于任务表和音频自己跟自己抢。
                chapter = await migrateSpeakers(
                    chapter,
                    bookID: job.bookID,
                    protecting: Set(job.sentenceIndex.map { [$0] } ?? [])
                )
            }
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
                let base = await fastAnalyzer.prime(chapter, bookID: job.bookID, in: start..<end)
                var cursor = start
                while cursor < end {
                    let upper = cursor < headEnd ? headEnd : end
                    let working = try await analyzer.analyzeBatch(chapter: base, range: cursor..<upper, context: StoryContext(characters: [], recentCharacters: [], recentEvents: []))
                    // 被后台掐掉的生成不会报错：MLXLMCommon 在 token 边界自查取消后
                    // 就把已经吐出的半截文本正常返回了。这一步必须挡在合并之前——
                    // 半截 JSON 能解析出前几句，合并进库就成了「参数突然变了但其实没分析完」。
                    if Task.isCancelled { throw CancellationError() }
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
                        // 声音标记和音频是同一件产物的属性：只跟着音频走，
                        // 留在旧快照上会把「这句是谁录的」记岔，过期检查就看不出真过期。
                        updated.recordedVoiceID = old.recordedVoiceID
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
                    let due = (cursor..<upper).map { (index: $0, priority: job.mode == .interactive ? priority($0, near: current) : 100) }
                    await scheduleTTS(chapter: latest, bookID: job.bookID, sentences: due, mode: job.mode)
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
            // 被后台门禁掐掉的批次/句子没有错，只是时机不对：退回队列等回前台重跑。
            // 记成 failed 的话，用户一回来就看到满屏「分析失败 / 合成失败」，而那一
            // 刻真正该做的是别再往 Metal 里提交推理。
            if Self.isHaltedByBackground(error) {
                print("[Gate] 后台门禁中断 \(job.id)（\(error.localizedDescription)）→ 退回队列，等回前台重跑")
                job.state = .pending; job.startedAt = nil; job.error = nil
                await store.update(job); await queue(job)
                return
            }
            // 后台里整条顺位链都空了（选中的是本地 GPU 模型，Edge 又坏到被跳过、本地 CPU
            // 那一格没权重）。这时候继续取任务只会把整章句子逐个记成「合成失败」，而播放器
            // 对失败句是**永久跳过**——用户回来听到的就是快进。这不是任务的错，是这一刻真没退路：
            // 这一句退回队列、队列挂起，等回前台（`applyBackground(false)` 会放开）。
            if error is TTSSynthesisError, job.type == .ttsSentence,
               AppBackgroundGate.shared.isBackground {
                print("[Gate] 后台：语音后端全部不可用 → 挂起合成队列，这一句退回等回前台（\(error.localizedDescription)）")
                job.state = .pending; job.startedAt = nil; job.error = nil
                ttsHeldByBackground = true
                await store.update(job); await queue(job)
                await syncSuspension()
                return
            }
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
    /// 「不是任务的错」那一类中止：后台门禁在推理入口拦下的（`backgroundHalted`），
    /// 以及被它掐掉的在飞任务（协作式停止后抛 `CancellationError`）。
    /// 两者都该退回队列等回前台，而不是记成失败。
    private static func isHaltedByBackground(_ error: Error) -> Bool {
        error is CancellationError || (error as? AIError) == .backgroundHalted
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

    /// 解析与 TTS 彻底分开：只要用户在听，分析批次就等着。两边同抢一块 GPU 就是
    /// 发烫和内存峰值的来源，而旧版「攒够 5 句音频就插一批」的交错等于谁都没让路。
    /// 等待前先把模型权重卸掉（约 600MB），收听期间的内存就只剩 TTS 一份。
    /// 返回 false 表示等待中被取消，调用方需把批次退回 pending。
    private func waitForListeningToStop(job: EnhancementJob) async -> Bool {
        guard isListening else { return true }

        await analyzer.unloadModel()
        let deadline = Date().addingTimeInterval(Self.analysisStarvationTimeout)
        print("[Gate] 用户正在收听 → 后台解析让路（模型已卸载，权重内存还给 TTS），最多等 \(Int(Self.analysisStarvationTimeout))s")

        while true {
            if Task.isCancelled { return false }
            if !isListening { return true }
            if Date() >= deadline {
                print("[Gate] 让路超时，照常分析 \(job.id)")
                return true
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
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
        let reason: String
        if speechHeld {
            reason = "语音播报已关闭"
        } else if analysisSuspended {
            reason = "收听中已挂起"
        } else if analysisHeldByBackground {
            // 进后台那一刻正好有批次在跑，闸只挡得住后面的：排队的批次还成千上万，
            // 光看 pendingCount 就永远等不到「排空」，权重白占着 1.2GB。
            reason = "后台门禁已挂起"
        } else if await analysisQueue.pendingCount == 0 {
            reason = "分析队列排空"
        } else {
            return
        }
        // 卸载要清空 MLX 的 cached 池（一次 clearCache 可能吃掉几百毫秒的
        // CPU），而这一刻 TTS 正在出声。把耗时和当时的排队量一起打出来，
        // 才能判明「放一半卡住」究竟是不是这一步造成的。
        let unloadStart = CFAbsoluteTimeGetCurrent()
        await analyzer.unloadModel()
        let unloadMs = (CFAbsoluteTimeGetCurrent() - unloadStart) * 1000
        let ttsPending = await ttsQueue.pendingCount
        // 「让给 TTS」只在语音还开着时成立：关掉语音是两边一起交还，别打出一条误导人的账。
        print("[Memory] \(reason) → 卸载 Qwen3-0.6B（\(speechHeld ? "语音已关，TTS 权重同步交还" : "权重内存让给 TTS 缓存与预取")，"
            + "卸载耗时 \(String(format: "%.0f", unloadMs))ms，此刻 TTS 排队 \(ttsPending) 句）")
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
