//
//  PlayerManager.swift
//  Reader
//
//  Created by 粟海洋 on 2026/8/26.
//

import Foundation
import AVFoundation
import Combine
import UIKit

@MainActor
final class PlayerManager: ObservableObject {

    static let shared = PlayerManager()

    // MARK: - Published

    @Published private(set) var isPlaying = false

    @Published private(set) var currentText: String = ""

    @Published private(set) var currentCharacter: String = "旁白"

    @Published private(set) var currentSentenceIndex: Int = 0

    @Published private(set) var progress: Double = 0

    @Published private(set) var currentTime: Double = 0

    @Published private(set) var duration: Double = 0

    @Published private(set) var currentChapter: Chapter?

    @Published private(set) var sentences: [Sentence] = []

    @Published var playbackRate: Double = 1.0 {
        didSet {
            if isPlaying {
                player?.rate = Float(playbackRate)
            }
            // 卡片上那根条是按媒体秒走的，倍速报错了它才会「看着不对」：一起改。
            nowPlaying.setRate(isPlaying ? playbackRate : 0)
        }
    }

    // MARK: - Chapter Navigation

    private(set) var chapters: [ChapterDescriptor] = []

    private(set) var currentChapterIndex: Int = 0

    var onNeedNextChapter: (() async -> Chapter?)?

    /// Scheduler telemetry only; playback remains independent from generation.
    var onAudioStarted: ((Int) -> Void)?

    var chapterProgress: Double {
        guard !sentences.isEmpty else { return 0 }
        let completed = Double(currentSentenceIndex)
        let total = Double(sentences.count)
        return min(1, (completed + progress) / total)
    }

    // MARK: - Private

    private var player: AVPlayer?

    private var timeObserver: Any?

    private var endObserver: NSObjectProtocol?

    /// 用户是否处于「想播放」状态（用于流式：音频就绪后自动续播）
    private var wantsToPlay = false

    /// 当前句音频尚未生成，正在等待流式返回
    private var awaitingAudio = false

    /// 这一次「等音频」的起点，只为算出等了多久（诊断，不参与任何判断）
    private var awaitingSince: Date?

    /// 锁屏 / 控制中心那张卡片，以及卡片上那些按钮回到播放器的路。
    private let nowPlaying = NowPlayingController()

    /// 「本来该出声、这会儿手上却没有音频」时顶住会话的静音循环（见 `BackgroundAudioHold`）。
    private let hold = BackgroundAudioHold()

    /// 被系统中断（来电、Siri、闹钟）掐掉之前是否在放。
    /// 只有它记着「是系统掐的」那一次，中断结束才自动续播；顺带也用它拦住保活静音——
    /// 中断期间是别人在用音频会话，这时候顶回去就是把电话声音挤掉。
    private var pausedBySystemInterruption = false

    /// 卡片上那根进度条上次推过去是什么时候（`CFAbsoluteTimeGetCurrent`）。
    private var cardTickAt: Double = 0

    private init() {
        configureAudioSession()
        installNowPlayingCommands()
        installSessionObservers()
    }

    deinit {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }

        if let endObserver {
            NotificationCenter.default.removeObserver(
                endObserver
            )
        }
    }

    // MARK: - Audio Session

    private func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("AudioSession 配置失败: \(error)")
        }
    }

    /// 真的起播之前把会话确认成「激活」状态。
    ///
    /// 原来只在 `init()` 里 `setActive(true)` 一次，那一刻什么都还没放：别的 App 正占着
    /// 音频时这一步会失败，而失败之后再也没有第二次。类别（`.playback`）确实还在，前台
    /// 照样出声，于是这个洞只有熄屏才露出来——系统放行一个 App 在后台出声，看的是它
    /// **持有**一个激活的播放会话。所以在每次新建播放器/从中断里回来时补一次。
    private func ensureSessionActive() {
        let session = AVAudioSession.sharedInstance()
        do {
            // 音频服务重置后类别会回到默认（.soloAmbient），这里连类别一起补。
            if session.category != .playback {
                try session.setCategory(.playback, mode: .spokenAudio)
            }
            // 没有公开的「会话是否已激活」可读，所以每次起播前都调一次：
            // 已激活时这是一个空操作，而中断后被系统抢走的会话正需要这一步抢回来。
            try session.setActive(true)
        } catch {
            print("⚠️ [Session] 激活失败（照常尝试出声）：\(error)")
        }
    }

    /// 系统声音现场的变化。这三个通知不接，「熄屏后继续播」在一次来电之后就不成立了。
    private func installSessionObservers() {
        let center = NotificationCenter.default
        center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            self?.handleInterruption(note)
        }
        center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            self?.handleRouteChange(note)
        }
        center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleMediaServicesReset()
        }
        // 进/出后台本身也要重新结算保活：熄屏的那一刻如果已经卡在「等音频」里，
        // 后面没有任何播放状态变化会来触发它，而那正是被冻结的唯一窗口。
        center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateAudioHold()
        }
        center.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateAudioHold()
        }
    }

    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }

        switch type {
        case .began:
            guard isPlaying else { return }
            // 会话被抢走时播放器其实已经停了，这里只把状态对齐、并记住「中断前在放」。
            pausedBySystemInterruption = wantsToPlay
            isPlaying = false
            nowPlaying.setRate(0)
            updateAudioHold()
            print("[Session] 被系统中断 → 暂停（中断结束后\(pausedBySystemInterruption ? "自动续播" : "本就没在放")）")

        case .ended:
            guard pausedBySystemInterruption else { return }
            pausedBySystemInterruption = false
            let options = AVAudioSession.InterruptionOptions(
                rawValue: note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            )
            let shouldResume = options.contains(.shouldResume)
            print("[Session] 中断结束（shouldResume=\(shouldResume)）→ \(shouldResume ? "续播" : "停在这里")")
            if shouldResume {
                ensureSessionActive()
                play()
            } else {
                wantsToPlay = false
                updateAudioHold()
            }

        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw),
              reason == .oldDeviceUnavailable,
              isPlaying else { return }
        // 耳机拔了 / 音箱断开：按系统惯例停下，不然声音会从手上这台设备外放出去。
        pause()
        print("[Session] 输出设备断开 → 暂停")
    }

    private func handleMediaServicesReset() {
        // 系统的音频服务重启（少见，但一旦发生，手上这个 AVPlayer 已经废了）：
        // 会话重新配置、播放器整个重建，正在听的那一句从头放。
        let wanted = wantsToPlay
        stop()
        configureAudioSession()
        print("[Session] 音频服务重置 → 播放器已重建（\(wanted ? "继续播这一句" : "保持暂停")）")
        if wanted {
            playCurrentSentence()
        }
    }

    /// 手上此刻是不是**真的**在出声。用 AVPlayer 自己的判断，不用 `isPlaying`：
    /// 一句放完到下一句挂上去之间、章末等下一章的那几百毫秒里，`isPlaying` 还挂着 true，
    /// 可声音已经没了——那正是熄屏后最容易被冻结的那道缝。
    private var isSounding: Bool {
        player?.timeControlStatus == .playing
    }

    /// 「本来该出声、可现在没出声」的统一结算：只在后台、用户还在听、且不是被系统中断
    /// 掐着的时候，用静音循环顶住会话。每个播放状态变动的地方调一次，别在六处各写条件。
    private func updateAudioHold() {
        let shouldHold = wantsToPlay
            && !isSounding
            && !pausedBySystemInterruption
            && AppBackgroundGate.shared.isBackground

        if shouldHold {
            if !hold.isActive {
                hold.start()
                print("[Hold] 后台暂无音频可放 → 静音顶住会话（不顶就会被冻结，合成一起停）")
            }
        } else if hold.isActive {
            hold.stop()
            print("[Hold] 放掉静音（声音回到正常那一路）")
        }
    }

    // MARK: - Configure

    /// 卡片上的按钮 → 播放动作。装一次，此后系统按键、线控、控制中心都从这里回到播放器。
    private func installNowPlayingCommands() {
        nowPlaying.install(
            NowPlayingCommands(
                play: { [weak self] in self?.play() },
                pause: { [weak self] in self?.pause() },
                toggle: { [weak self] in self?.togglePlay() },
                jumpChapter: { [weak self] delta in self?.jumpChapter(delta) },
                skip: { [weak self] seconds in self?.skipChapter(seconds) },
                seek: { [weak self] seconds in self?.seekChapterPosition(seconds) }
            )
        )
    }

    /// 本章的总时长（媒体秒，不含倍速）。
    private var chapterDuration: Double {
        let rate = charsPerSecond(of: sentences)
        return sentences.reduce(0) { $0 + duration(of: $1, charsPerSecond: rate) }
    }

    /// 现在停在本章第几秒：前面所有句子的长度 + 这一句已经放出去的。
    private var chapterElapsed: Double {
        let rate = charsPerSecond(of: sentences)
        let head = min(currentSentenceIndex, sentences.count)
        var acc: Double = 0
        for index in 0..<head {
            acc += duration(of: sentences[index], charsPerSecond: rate)
        }
        guard sentences.indices.contains(currentSentenceIndex) else { return acc }
        let length = duration(of: sentences[currentSentenceIndex], charsPerSecond: rate)
        return acc + min(max(0, currentTime), length)
    }

    /// 一章的音频不是一个文件，而是几百个句子文件，AVPlayer 手上永远只有当前那一句。
    /// 卡片要的是「本章听到哪儿」，所以本章时长只能自己按句累加。
    ///
    /// 还没合成出来的句子按字数外推：不外推的话刚开播时整章「只有前三句长」，
    /// 进度条会随着句子一个个出声一路倒退——那条尺子看着在动，其实在说谎。
    /// 语速取本章已经出过声的平均值（不同情绪、不同角色差得远，全书平均值不如本章的），
    /// 一个都还没出过时按 4.5 字/秒，那是中文朗读的常见速度。
    private func charsPerSecond(of sentences: [Sentence]) -> Double {
        var chars = 0
        var seconds: Double = 0
        for sentence in sentences {
            guard let duration = sentence.duration, duration > 0 else { continue }
            chars += max(1, sentence.text.count)
            seconds += duration
        }
        guard chars > 0, seconds > 0 else { return 4.5 }
        return Double(chars) / seconds
    }

    private func duration(
        of sentence: Sentence,
        charsPerSecond: Double
    ) -> Double {
        if let duration = sentence.duration, duration > 0 { return duration }
        return max(0.6, Double(max(1, sentence.text.count)) / charsPerSecond)
    }

    /// 整份重推卡片：换章、换句都用它（一句十几秒一次，比句子本身便宜三个数量级）。
    /// 换句也要重推，因为本章的总时长会随着句子陆续合成出来而变。
    private func syncNowPlaying() {
        guard let book = currentBook, let chapter = currentChapter else { return }
        nowPlaying.show(
            NowPlayingTrack(
                bookTitle: book.title,
                author: book.author,
                chapterTitle: chapter.title.isEmpty
                    ? "第 \(chapter.index + 1) 章" : chapter.title,
                coverURL: book.coverURL,
                duration: chapterDuration
            ),
            position: chapterElapsed,
            rate: isPlaying ? playbackRate : 0
        )
    }

    /// 只挪进度，不改内容：播放中的心跳。
    private func syncNowPlayingPosition() {
        nowPlaying.updatePosition(
            chapterElapsed,
            rate: isPlaying ? playbackRate : 0
        )
    }

    func configure(
        chapters: [ChapterDescriptor],
        currentIndex: Int
    ) {
        self.chapters = chapters
        self.currentChapterIndex = currentIndex
    }

    // MARK: - Start / Resume

    /// 现在播的是哪本书：播放页的自动续播、状态重试都要用它。
    private(set) var currentBook: Book?

    private var pipeline: ReaderPipeline?

    /// 把一本书的某一章交给播放器：连上跨章推进要用的书单和回调，取回正文装载，
    /// 并把指针放回上次那句（只挪指针，不起播）。
    ///
    /// ReaderView 的分页展示和播放页的自动续播走的是同一段装配。以前这一段只在
    /// ReaderView 里，播放页自己没法独立把一章播起来——冷启动进播放页就永远停在
    /// 「尚未加载章节」；两段各写一份的话，「播完自动换下一章」「按当前位置排产
    /// 音频」这类问题迟早只有一边修。
    func start(
        book: Book,
        chapter descriptor: ChapterDescriptor,
        restoreTo sentenceIndex: Int?,
        pipeline: ReaderPipeline
    ) async throws -> Chapter {

        self.currentBook = book
        self.pipeline = pipeline

        // 这本书的整书解析批次在这里补排一次：老版本导入的书队列里没有批次，而播放
        // 路径已经不排解析了，不在这里补它就永远等不到 LLM 校准。
        // 绝不能 await：它要逐章读落库正文、再把整本任务写盘，几百章的书是几十秒，
        // 摆在这一步就是「点开章节一直加载不显示正文」。幂等，所以丢后台跑。
        Task { await pipeline.registerBook(book) }

        let context = StoryContext(
            characters: [],
            recentCharacters: [],
            recentEvents: []
        )

        let chapters = book.chapters

        configure(
            chapters: chapters,
            currentIndex: chapters.firstIndex { $0.id == descriptor.id } ?? 0
        )

        onAudioStarted = { index in
            Task {
                await pipeline.recordPlaybackStarted(
                    bookID: book.id,
                    chapterID: descriptor.id,
                    sentenceIndex: index
                )
            }
        }

        // 闭包存在自己身上，强引用 self 会把单例和自己缠成一圈
        onNeedNextChapter = { [weak self] in
            guard let player = self else {
                return nil
            }
            let index = player.currentChapterIndex + 1
            guard index < chapters.count else {
                return nil
            }
            return await pipeline.resolveNext(
                chapters[index],
                bookID: book.id,
                context: context
            )
        }

        let initial = try await pipeline.openChapter(
            descriptor,
            bookID: book.id,
            context: context,
            // 续读的位置一起交出去：排产在后台按这一句排锚点，不再回来二次纠正
            at: sentenceIndex ?? 0
        )

        load(chapter: initial)

        if let saved = sentenceIndex, saved > 0 {
            restoreSentenceIndex(
                min(saved, max(initial.sentences.count - 1, 0))
            )
            // 再报一次位置：章内的锚点 openChapter 已经按这句排好了，这次补的是
            // 相邻两章的音频档位（上一章/下一章）。它要带着整章走一遍排产，
            // 打开这一章的那几百毫秒里正文比它重要，所以丢后台。
            let position = currentSentenceIndex
            Task { await self.reportPosition(position) }
        }

        return initial
    }

    /// 把「现在停在第几句」告诉调度器：相邻章的优先级和音频排产都按这个调。
    func reportPosition(_ index: Int) async {
        guard let book = currentBook, let chapter = currentChapter, let pipeline else {
            return
        }
        await pipeline.updateReadingPosition(
            bookID: book.id,
            chapterID: chapter.id,
            sentenceIndex: index,
            nextChapterID: chapters.indices.contains(currentChapterIndex + 1)
                ? chapters[currentChapterIndex + 1].id : nil,
            prevChapterID: currentChapterIndex > 0
                ? chapters[currentChapterIndex - 1].id : nil
        )
    }

    // MARK: - Load Chapter

    func load(chapter: Chapter) {

        stop()

        awaitingAudio = false
        awaitingSince = nil

        currentChapter = chapter

        sentences = chapter.sentences

        currentSentenceIndex = 0

        progress = 0

        currentTime = 0

        duration = 0

        if let first = sentences.first {
            currentText = first.text
            currentCharacter =
                first.characterName ?? "旁白"
        }

        syncNowPlaying()
        updateAudioHold()
    }

    // MARK: - Load Next Chapter

    /// 把一章交出去播：装载 + 起播。章末自动续播和卡片上的「下一章」共用这一段。
    private func present(chapter: Chapter) {
        wantsToPlay = true
        load(chapter: chapter)
        playCurrentSentence()
    }

    func loadNextChapter(_ chapter: Chapter) {

        currentChapterIndex += 1

        present(chapter: chapter)
    }

    // MARK: - Update Sentences (streaming)

    /// 流式生成时更新句子数据：填充新就绪的 audioURL。
    /// 若正在等待当前句音频，则自动续播。
    func updateSentences(_ newSentences: [Sentence]) {

        sentences = newSentences

        if awaitingAudio,
           wantsToPlay,
           sentences.indices.contains(currentSentenceIndex),
           sentences[currentSentenceIndex].audioURL != nil {

            let waited = awaitingSince.map { String(format: "%.1f", Date().timeIntervalSince($0)) } ?? "-"
            print("[Stall] 句\(currentSentenceIndex) 音频到达 → 续播（等了 \(waited)s）")
            playCurrentSentence()
        }
    }

    // MARK: - Play

    /// 「语音播报」开关存哪儿。阅读页底部那颗按钮和设置页那个 Toggle 写的是同一个键，
    /// 所以两边天然是同一个值——任何一处拨动，另一处立刻跟着变。
    static let speechEnabledKey = "speechEnabled"

    /// 每次现读，不缓存成 @Published：两个页面各自 `@AppStorage` 同一个键才能互相同步，
    /// 这里只是出声前要问一句的闸门。没有记录时算开（老用户升级后行为不变）。
    private var speechEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.speechEnabledKey) as? Bool ?? true
    }

    /// 拨开关的唯一入口：关掉要把已经在放的声音一起停掉，
    /// 否则会出现「关了还在读」。
    ///
    /// 关掉的还不止出声：调度器随之挂住合成与整书解析两条队列、掐掉在飞的推理、
    /// 把 Qwen3 和 TTS 的权重全部交还（见 `ReaderPipeline.applySpeechEnabled`）。
    /// 排产记录一条不丢，所以开回来是接着跑，不是从头再来。
    static func setSpeechEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: speechEnabledKey)
        if !on {
            shared.stop()
            // 卡片也要撤掉：留着就是一张按下去什么都不做的假卡（用户明说别念了）。
            shared.nowPlaying.clear()
        }
        let pipeline = ReaderContainer.shared.pipeline
        Task {
            await pipeline.applySpeechEnabled(on)
            guard on else { return }
            // 关着的这段时间里开过的章节一条合成都没排产（`scheduleTTS` 那道闸），
            // 不补报一次位置就是「按下播放、然后等一句永远不来的音频」。
            // 和跳章那一条是同一个道理，走的是同一条路。
            await shared.reportPosition(shared.currentSentenceIndex)
        }
    }

    func play() {

        guard
            speechEnabled,
            !sentences.isEmpty
        else {
            return
        }

        wantsToPlay = true

        if player == nil {
            playCurrentSentence()
            return
        }

        ensureSessionActive()
        player?.rate = Float(playbackRate)

        isPlaying = true

        nowPlaying.setRate(playbackRate)
        updateAudioHold()
    }

    // MARK: - Pause

    func pause() {

        wantsToPlay = false

        awaitingAudio = false
        awaitingSince = nil

        player?.pause()

        isPlaying = false

        nowPlaying.setRate(0)
        updateAudioHold()

        reportListeningStopped()
    }

    /// 用户停手 = 把 GPU 让给后台解析。调度器只看「有没有人在听」，
    /// 它没法从播放进度自己推断，所以必须在这里明说。
    private func reportListeningStopped() {
        guard let book = currentBook, let pipeline else { return }
        Task { await pipeline.reportListeningStopped(bookID: book.id) }
    }

    // MARK: - Toggle

    func togglePlay() {

        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    // MARK: - Stop

    func stop() {

        player?.pause()

        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil

        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil

        player = nil

        isPlaying = false

        currentTime = 0

        progress = 0

        duration = 0

        nowPlaying.setRate(0)
        updateAudioHold()

        reportListeningStopped()
    }

    // MARK: - Seek / Skip（按**本章**算，锁屏卡片那根条就是这个尺度）

    /// 挪到本章的第几秒：先定位到哪一句，再在那一句里挪剩下的零头。
    ///
    /// 为什么不是「在当前这一句里挪」：一句只有几秒，卡片上的进度条画的是整章，
    /// 拖到中段却只在本句里跳，等于没响应。倍速也不在这里管——这里的单位是媒体秒，
    /// 卡片同样按媒体秒报位置，两边同一个尺子。
    func seekChapterPosition(_ seconds: Double) {

        guard !sentences.isEmpty else { return }

        let rate = charsPerSecond(of: sentences)
        let target = max(0, seconds)
        var head: Double = 0

        for index in sentences.indices {
            let length = duration(of: sentences[index], charsPerSecond: rate)
            // 落在这一句里；拖过最后一句就停在最后一句。
            guard target >= head + length, index < sentences.count - 1 else {
                let offset = max(0, target - head)
                currentSentenceIndex = index
                playCurrentSentence()
                if offset > 0.05, let player {
                    // 刚换上去的 item 可能还在加载：AVPlayer 接受对加载中的 item 定位，
                    // 等它 ready 时自然停在该处。
                    player.seek(
                        to: CMTime(seconds: offset, preferredTimescale: 600),
                        toleranceBefore: .zero,
                        toleranceAfter: .zero
                    )
                    currentTime = offset
                }
                syncNowPlayingPosition()
                return
            }
            head += length
        }
    }

    /// 相对挪动（±15s 那两颗键）。
    func skipChapter(_ seconds: TimeInterval) {
        seekChapterPosition(chapterElapsed + seconds)
    }

    /// 上一章 / 下一章。卡片上那两颗键按的是「曲目切换」，这本书里一首曲目就是一章。
    func jumpChapter(_ delta: Int) {

        guard let book = currentBook, let pipeline else { return }

        let target = currentChapterIndex + delta
        guard book.chapters.indices.contains(target) else {
            print("[NowPlaying] \(delta > 0 ? "后面" : "前面")没有章了（第 \(currentChapterIndex + 1)/\(book.chapters.count) 章）")
            return
        }
        let descriptor = book.chapters[target]

        // 取正文要读盘，不能在命令回调里同步等：那一步会把主线程压在系统按键上。
        Task {
            let context = StoryContext(
                characters: [],
                recentCharacters: [],
                recentEvents: []
            )
            guard let chapter = try? await pipeline.openChapter(
                descriptor,
                bookID: book.id,
                context: context,
                at: 0
            ) else {
                print("⚠️ [NowPlaying] 跳章没读到正文：\(descriptor.title)")
                return
            }
            currentChapterIndex = target
            present(chapter: chapter)
            // 让调度器按新的位置重排相邻章的音频：不报的话，跳过去那一章后面可能没声。
            await reportPosition(currentSentenceIndex)
        }
    }

    func playSentence(at index: Int) {

        guard
            speechEnabled,
            sentences.indices.contains(index)
        else {
            return
        }

        wantsToPlay = true

        currentSentenceIndex = index
        playCurrentSentence()
    }

    /// 恢复上次的阅读位置：只把指针挪到那句，不起播。
    func restoreSentenceIndex(_ index: Int) {

        guard sentences.indices.contains(index) else {
            return
        }

        currentSentenceIndex = index

        currentText = sentences[index].text

        currentCharacter =
            sentences[index].characterName ?? "旁白"

        // 卡片跟着指针走：装载时它按第 0 句报的，这句之后的几句都会被算成「还没听」。
        syncNowPlayingPosition()
    }
}


private extension PlayerManager {

    func playCurrentSentence() {

        guard
            sentences.indices.contains(
                currentSentenceIndex
            )
        else {
            return
        }

        let sentence =
            sentences[currentSentenceIndex]

        currentText = sentence.text

        currentCharacter =
            sentence.characterName ?? "旁白"

        guard
            let url = sentence.audioURL
        else {

            // 合成/分析已失败的句子不会再出现音频，直接跳过，
            // 不让播放停在永远等不到的句子上
            if sentence.audioStatus == .failed || sentence.analysisStatus == .failed {
                if currentSentenceIndex < sentences.count - 1 {
                    currentSentenceIndex += 1
                    playCurrentSentence()
                } else {
                    isPlaying = false
                    progress = 1
                    // 这一章再也没有声音了：别再顶着「想播」，否则保活静音会一直挂着，
                    // 而卡片也停在一个永远等不到的位置上。
                    wantsToPlay = false
                    nowPlaying.setRate(0)
                    updateAudioHold()
                }
                return
            }

            // 诊断：「放一半没声」只有这一种形态——播放头追上了音频边界。
            // 把现场记下来：这句的状态 + 往后 10 句里有音频的句数，
            // 一看就知道是「合成跑不赢播放」还是「根本没排产」。
            if !awaitingAudio {
                awaitingSince = Date()
                let upper = min(sentences.count, currentSentenceIndex + 10)
                let ready = sentences[currentSentenceIndex..<upper].filter { $0.audioURL != nil }.count
                print("[Stall] 句\(currentSentenceIndex)/\(sentences.count) 无音频 → 等待（audio=\(sentence.audioStatus) analysis=\(sentence.analysisStatus) 往后\(upper - currentSentenceIndex)句已有音频=\(ready)）")
            }

            awaitingAudio = true

            isPlaying = false

            // 等音频的这一段是熄屏后最容易死的地方：没有音频在出声，iOS 就把 App 冻结，
            // 于是网络/本地合成一起停，等的东西永远等不到。这里就是为了让它别停。
            nowPlaying.setRate(0)
            updateAudioHold()

            return
        }

        awaitingAudio = false
        awaitingSince = nil

        let item =
            AVPlayerItem(url: url)

        duration = sentence.duration ?? 0

        currentTime = 0

        progress = 0

        if let existingPlayer = player {
            if let observer = timeObserver {
                existingPlayer.removeTimeObserver(observer)
            }
            timeObserver = nil
            existingPlayer.replaceCurrentItem(with: item)
        } else {
            player = AVPlayer(playerItem: item)
            // 新建播放器 = 一次真正的起播（首次、换章、从中断回来都算）：
            // 会话必须在这一刻是激活的，熄屏后系统才认你在出声。
            ensureSessionActive()
        }

        guard let player else { return }

        player.rate = Float(playbackRate)

        onAudioStarted?(currentSentenceIndex)

        observeEnd(item: item)

        addTimeObserver(player: player)

        isPlaying = true

        syncNowPlaying()
        updateAudioHold()
    }
}



private extension PlayerManager {

    func addTimeObserver(player: AVPlayer) {

        timeObserver =
            player.addPeriodicTimeObserver(
                forInterval: CMTime(
                    seconds: 0.05,
                    preferredTimescale: 600
                ),
                queue: .main
            ) { [weak self] time in

                guard let self else {
                    return
                }

                Task { @MainActor in

                    self.currentTime =
                        time.seconds

                    if self.duration > 0 {

                        self.progress =
                            min(
                                1,
                                max(
                                    0,
                                    time.seconds
                                    / self.duration
                                )
                            )
                    }

                    // 锁屏卡片的心跳。系统会按报过去的 rate 自己往前推，1s 一次
                    // 只是把「跳句」和「改倍速」这两类外推跟不上的场合兜住。
                    let now = CFAbsoluteTimeGetCurrent()
                    if now - self.cardTickAt >= 1 {
                        self.cardTickAt = now
                        self.syncNowPlayingPosition()
                    }
                }
            }
    }

    func observeEnd(item: AVPlayerItem) {

        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }

        endObserver =
            NotificationCenter.default.addObserver(
                forName:
                    .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] _ in

                guard let self else {
                    return
                }

                Task { @MainActor in
                    self.handleSentenceFinished()
                }
            }
    }

    func handleSentenceFinished() {

        if currentSentenceIndex
            < sentences.count - 1 {

            currentSentenceIndex += 1

            playCurrentSentence()

        } else if currentChapterIndex < chapters.count - 1,
                  let callback = onNeedNextChapter {

            // 本章最后一句放完，下一章的正文还在读盘/排产：这一段是真没声音，
            // 而 `isPlaying` 还挂着 true。先让保活顶上，别让熄屏时这一缝把 App 冻住。
            updateAudioHold()

            Task {
                if let next = await callback() {
                    self.loadNextChapter(next)
                } else {
                    self.isPlaying = false
                    self.progress = 1
                    // 全书播完了：「想播」必须一起放下，否则静音保活会永远挂着。
                    self.wantsToPlay = false
                    self.nowPlaying.setRate(0)
                    self.updateAudioHold()
                }
            }

        } else {

            isPlaying = false
            progress = 1
            wantsToPlay = false
            nowPlaying.setRate(0)
            updateAudioHold()
        }
    }
}
