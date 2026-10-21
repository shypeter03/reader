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

    /// AVPlayer「还在不在走」和手上那个 item「读不读得出来」。
    ///
    /// 这两样不盯，「后台莫名暂停」就没有成因可找：系统可以在我们一条 `pause()` 都没走
    /// 的情况下把播放掐掉（会话被别的 App 抢走、内存压力、item 废了），而 `isPlaying`
    /// 是自己写的 true，于是屏幕上在播、锁屏上在播、耳朵里什么都没有。
    /// 等音频的那一段也没有心跳可问，只能靠 KVO 这一路自己醒。
    private var controlStatusObservation: NSKeyValueObservation?

    private var itemStatusObservation: NSKeyValueObservation?

    /// 上一次自愈是什么时候。KVO 只在值变化时来，本来不循环，但「会话抢不回来」那种
    /// 情形会一路「给了 rate 又被弹回 paused」，别让它把日志刷满。
    private var lastStallHealAt = Date.distantPast

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

    /// 上一句放完的时刻 + 它是第几句，用来量「换 `AVPlayerItem` 到下一句真出声」那段空档。
    ///
    /// 为什么要这个数：一句被 48 字上限裁成两半时，接缝上叠了两样东西——前一段自带的
    /// 尾静音，和这一段换 item 的空档。前者合成那边已经能打印（`[TTS⏱] … 尾静音 …s→留 …s`），
    /// 后者只有真机放着音频才量得到。听感上「说到某个字停一下」到底是哪一样撑起来的，
    /// 就靠这两个数分工。
    ///
    /// 记的是「从哪一句接过来」：只有播放头正好走到它的下一句才算这一笔，别的入口
    /// （点句、双击读句、跨章）一律不认，免得把用户按下去的那一下也量成换 item 的开销。
    private var seamClock: (from: Int, at: Double)?

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
    /// **持有**一个激活的播放会话。所以每一次要给播放器 rate 之前都补一次（新建和复用
    /// 两条分支都算），中断回来、KVO 抢回播放时也各补一次。
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
            // 认「还想不想听」，不认「这一刻在不在出声」：等音频的那一段 `isPlaying` 是
            // false，可人确实还在听这一本。按 `isPlaying` 判就漏记这一次，而漏记的代价是
            // 中断结束时既不抢会话也不续播——「熄屏时来了一条提示音，之后朗读再没响过」。
            guard wantsToPlay else { return }
            // 会话被抢走时播放器其实已经停了，这里只把状态对齐、并记住「中断前在听」。
            pausedBySystemInterruption = true
            isPlaying = false
            nowPlaying.setRate(0)
            updateAudioHold()
            print("[Session] 被系统中断 → 暂停（中断结束后自动续播）")

        case .ended:
            // 先把会话抢回来，再谈要不要续播。被系统拿走之后不 `setActive(true)`，
            // 后面每一次给 rate 都是空转：不报错、也不出声，而 `isPlaying` 还会被写成 true。
            // 这一步和「中断前在不在放」无关——没在放也要还回来，否则下一次起播同样哑掉。
            ensureSessionActive()

            guard pausedBySystemInterruption else {
                // 中断前本就没在听（或 `.began` 那一路没记上）：只把保活重新结算一次，
                // 顶话的那路静音也在被抢走时死掉了，得有人把它救回来。
                updateAudioHold()
                return
            }

            pausedBySystemInterruption = false
            let options = AVAudioSession.InterruptionOptions(
                rawValue: note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            )
            let shouldResume = options.contains(.shouldResume)
            print("[Session] 中断结束（shouldResume=\(shouldResume)）→ \(shouldResume ? "续播" : "停在这里")")
            if shouldResume {
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
        // 输出设备一变，顶话的那一路静音也可能跟着掉（它走的也是这一条音频会话）。
        // 先重新结算保活，再判要不要停：不先补的话，「等音频 + 断了蓝牙耳机」那一段
        // 就没人再调 `updateAudioHold`，进程就此能被冻住。
        updateAudioHold()

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
            print("[Card] 不按播放：\(speechEnabled ? "手上没有正文（还没装配到章）" : "「语音播报」关着") 句=\(currentSentenceIndex) 句数=\(sentences.count)")
            return
        }

        wantsToPlay = true

        // 把锚点挪回这一句。卡片上按下播放的那一句常常正是「还没音频」的那一句（等合成
        // 期间被中断或被冻过），而排产只认最近报过一次的位置：不补报就是「按了播放，
        // 然后等一句永远不来的音频」。和开回语音播报、跳章走的是同一条路。
        let index = currentSentenceIndex
        Task { await self.reportPosition(index) }

        if player == nil {
            playCurrentSentence()
            return
        }

        // 播放器上手上的那句和指针那句不是同一句（等音频的那一段把 item 摘掉了）：
        // 这里直接给 rate 只会「按了没声却显示在播」，按指针那句重走一遍起播。
        if player?.currentItem == nil {
            playCurrentSentence()
            return
        }

        ensureSessionActive()
        player?.rate = Float(playbackRate)

        isPlaying = true

        nowPlaying.setRate(playbackRate)
        updateAudioHold()
        // 「手上」是播放器当前那个 item 的音频文件名：按了播放却没声时，这一行说明它
        // 到底在给哪一句的 rate（`AVPlayerItem` 不露 URL，要经 asset 取）。
        let held = (player?.currentItem?.asset as? AVURLAsset)?
            .url
            .lastPathComponent ?? "无 item"
        print("[Card] 播放 句=\(index) 手上=\(held)")
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

        print("[Card] 暂停 句=\(currentSentenceIndex)")

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

        // 先摘「想播」，再停播放器：`player.pause()` 会当场把一条 `timeControlStatus`
        // 变化丢进主线程队列（KVO 自愈那条路），留着 true 就是「关了语音还响一句」，
        // 而后台里它还会让静音保活一直顶着（`updateAudioHold` 只认这个值）。
        wantsToPlay = false

        player?.pause()

        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil

        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil

        // 观测挂在 player/item 上：这一层把播放器整个放下，观测也就没人接了，
        // 留着下一次起播前会被旧对象叫起来（认不出那是哪一句）。
        controlStatusObservation?.invalidate()
        controlStatusObservation = nil

        itemStatusObservation?.invalidate()
        itemStatusObservation = nil

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

    /// 用户挑了这一句要听（正文上双击的落点）。三件事按顺序办：
    /// ①当场把正在放的那一句收声；②把这个位置报给调度器——音频还没合成的那一句，
    /// 「加载」就只有这一条路（排产窗口按这个锚点往前挪，见 `promote`/`prime`）；③自动起播。
    ///
    /// 为什么要专门报位置：`onAudioStarted` 只在真出声那一刻走，而这一句恰恰可能正等着合成；
    /// 不报的话锚点还留在旧那句上，用户点的那一句要等前面一路念完才排到。
    func playSentence(at index: Int) {

        guard
            speechEnabled,
            sentences.indices.contains(index)
        else {
            return
        }

        wantsToPlay = true

        currentSentenceIndex = index

        Task { await self.reportPosition(index) }

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

        // 取证：每开口一句报一次「谁在说 + 用哪把嗓 + 这段音频出自哪个后端」。
        // 听出来的「旁白换人」只有这一行能对上：
        // `录` 是这段缓存实际用的嗓（可能是档案补齐前录的），`该` 是按现在的口径算出来的嗓，
        // 两者不一致就说明这句该重录；`该` 自己在一章里跳来跳去，那就是归属判错了。
        // `出` 是磁盘上那个文件所在的命名空间：`recordedVoiceID` 只记名字，而同一名字
        // 在 Edge 是 zh-CN-YunyangNeural、在 Kokoro 是 zm_098——是两把嗓。所以「`该` 全程
        // 不变、`出` 在 edge-v1/kokoro-v3 之间跳」正是「全是旁白却换人」最像的成因
        // （Edge 是主后端，某句网络失败就掉到 Kokoro 录那一句，落回磁盘混进同一章）。
        if let book = currentBook, let chapter = currentChapter {
            let backend = sentence.audioURL?
                .deletingLastPathComponent()
                .lastPathComponent
            print("[Voice] 句\(currentSentenceIndex) \(sentence.type.rawValue)/\(sentence.speaker.rawValue) 名=\(sentence.characterName ?? "-") 录=\(sentence.recordedVoiceID ?? "旧口径") 该=\(VoiceResolution.resolve(sentence: sentence, chapter: chapter, bookID: book.id)) 出=\(backend == chapter.id.uuidString ? "平铺" : (backend ?? "无音频")) 「\(String(sentence.text.prefix(12)))」")
        }

        // 「记录说有音频」和「磁盘上真有那个文件」是两件事：音频存在 Caches 里，系统缺盘
        // 时会自己收走，#181 那类重录也是先删文件再排产，而句子表上那份 `audioURL` 还留着。
        // 把这样的 URL 挂上 AVPlayer，item 只会停在 `.failed`：不出声，也永远等不到
        // 「放到末尾」，播放头就此钉在这一句上。所以先认盘，再认记录。
        let url = sentence.audioURL.flatMap {
            FileManager.default.fileExists(atPath: $0.path) ? $0 : nil
        }

        guard let url else {

            // 到这儿就是「这一句放不出来」，两种成因：合成/分析已判失败（不会再有音频），
            // 和记录上留着 `audioURL` 而磁盘上文件已不在（上面那次 `fileExists` 认出来的）。
            // 两种都只能跳过——等下去是死路：`scheduleTTS` 只排「记录上没有音频」的句子，
            // 那份记录要等下次开章的 `purgeReclaimedAudio` 才会被改回待合成。
            if sentence.audioStatus == .failed
                || sentence.analysisStatus == .failed
                || sentence.audioURL != nil {

                skipUnplayableSentence(
                    sentence.audioURL.map { "记录说有音频、文件不在（\($0.lastPathComponent)）" }
                        ?? "audio=\(sentence.audioStatus) analysis=\(sentence.analysisStatus) 都判失败"
                )
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

            // 等音频的这一段是几十秒的合成，不是换 item 的开销：这笔账不清掉，
            // 续播时那一下会把整段等待都报成 `[Gap]`。
            seamClock = nil

            // 指针已经挪到这一句，可它的音频还没来：手上那一句旧音频必须当场收声，而且
            // 要从播放器上**摘掉**。只把 `isPlaying` 写成 false 是假的——AVPlayer 还在放
            // 上一句，而它放完会走 `handleSentenceFinished` 把播放头推到 i+1，用户点的那
            // 一句就此被跳过去（表现就是「点了没反应，声音接着念别的」）。摘掉之后既不响，
            // 也不会自己往前跑；音频到达时 `updateSentences` 那条续播会再回到这里起播。
            if let player, player.currentItem != nil {
                player.pause()
                player.replaceCurrentItem(with: nil)
            }

            isPlaying = false

            currentTime = 0

            progress = 0

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

        // 每一次真正要给播放器 rate 之前都要确认会话是激活的，**两条分支都要**：
        // 原来只有「新建播放器」那一条补这一步，而等音频的那一段恰恰是把 item 摘掉、
        // 实例留着——续播时走的是复用那条支，会话要是被谁抢走过，这一步就漏了，
        // 结果是 `isPlaying` 写成 true、屏幕上在播、耳朵里什么都没有。
        ensureSessionActive()

        if let existingPlayer = player {
            if let observer = timeObserver {
                existingPlayer.removeTimeObserver(observer)
            }
            timeObserver = nil
            existingPlayer.replaceCurrentItem(with: item)
        } else {
            player = AVPlayer(playerItem: item)
        }

        guard let player else { return }

        player.rate = Float(playbackRate)

        onAudioStarted?(currentSentenceIndex)

        observeEnd(item: item)

        addTimeObserver(player: player)

        watchPlayback(player: player, item: item)

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

                    // 空档在这儿收尾：新 item 的时间开始走 = 真的出声了。
                    if let clock = self.seamClock, self.currentSentenceIndex == clock.from + 1,
                       time.seconds > 0 {
                        self.seamClock = nil
                        print("[Gap] 句\(clock.from)→\(self.currentSentenceIndex) 换 item 的空档 "
                            + "\(String(format: "%.0f", (CFAbsoluteTimeGetCurrent() - clock.at) * 1000))ms")
                    }

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

    /// 挂上「播放器还在不在走」和「这个 item 读不读得出来」两路观测。
    ///
    /// 为什么非 KVO 不可：后台里最常见的那几种停，一条 `pause()` 都不经过我们——会话被
    /// 抢走又还回来、系统直接把播放掐了、item 废了。这些既不发通知也不抛错，只有这两个
    /// 值会变。不盯着就只能等下一次心跳，而「等音频」那一段压根没有心跳可等。
    func watchPlayback(player: AVPlayer, item: AVPlayerItem) {

        controlStatusObservation?.invalidate()
        controlStatusObservation = player.observe(
            \.timeControlStatus,
            options: [.new]
        ) { [weak self] player, _ in
            Task { @MainActor in
                self?.handleControlStatus(player)
            }
        }

        itemStatusObservation?.invalidate()
        itemStatusObservation = item.observe(
            \.status,
            options: [.new]
        ) { [weak self] item, _ in
            Task { @MainActor in
                self?.handleItemStatus(item)
            }
        }
    }

    private func handleControlStatus(
        _ player: AVPlayer
    ) {
        // 只认「用户没按停，可它不走了」这一种。等音频（`awaitingAudio`）那一段是我们
        // 自己把 item 摘掉的，被系统中断掐着的那种有 `.ended` 负责接回来。
        //
        // `player === self.player` 这一条不能省：KVO 的回调是丢进主线程队列再执行的，
        // 而 `stop()` 里那句 `player?.pause()` 正好会发一次。这条迟到一回，就会在
        // 已经换上的新播放器之外，把已经丢掉的旧实例再 `rate = 1` 一次——两路声音叠着放。
        guard player.timeControlStatus == .paused,
              player === self.player,
              wantsToPlay,
              !awaitingAudio,
              !pausedBySystemInterruption,
              player.currentItem != nil
        else { return }

        // 这一句正好播完、`handleSentenceFinished` 还在路上：那是正常交接，不是被掐。
        if let item = player.currentItem,
           item.duration.seconds > 0,
           item.currentTime().seconds >= item.duration.seconds - 0.05 {
            return
        }

        let now = Date()
        guard now.timeIntervalSince(lastStallHealAt) >= 1 else { return }
        lastStallHealAt = now

        print("[Stall] 播放器被停下（不是用户按的）句\(currentSentenceIndex) → 抢回会话、按指针那句续播")

        ensureSessionActive()
        player.rate = Float(playbackRate)
    }

    private func handleItemStatus(
        _ item: AVPlayerItem
    ) {
        // 只处理还挂在播放器上的那一个：换句之后旧 item 的回调也该作废。
        guard item.status == .failed, item === player?.currentItem else { return }

        skipUnplayableSentence(
            "item 读不出来：\(item.error?.localizedDescription ?? "无错误信息")"
        )
    }

    /// 这一句放不出来：把播放头挪到下一句，别钉死在这儿。
    ///
    /// 为什么不等：`scheduleTTS` 只排「记录上没有音频」的句子，所以只要那份记录不改，
    /// 这一句在本章内永远不会重录——等下去就是把朗读停在一句放不出来的句子上，
    /// 用户看到的正是「放着放着莫名停了」。少听一句是明亏，停死是暗亏。
    private func skipUnplayableSentence(
        _ reason: String
    ) {
        print("[Stall] 句\(currentSentenceIndex)/\(sentences.count) 放不出来（\(reason)）→ 跳过这一句，下次开章会重录")

        // 手上那个废 item 必须摘掉：留着下一次 `play()` 会以为「有 item」而只给 rate，
        // 等于又去放同一句放不出来的音频。
        player?.pause()
        player?.replaceCurrentItem(with: nil)

        awaitingAudio = false
        awaitingSince = nil

        if currentSentenceIndex < sentences.count - 1 {
            currentSentenceIndex += 1
            // 下一句大概率同样放不出来（系统整章收走缓存时，几千句会连着都是这个样子）：
            // 就地递归会把主线程调用栈吃穿，这里换成一次任务切换，把这条链摊平成队列。
            Task { @MainActor in
                self.playCurrentSentence()
            }
        } else {
            isPlaying = false
            progress = 1
            // 这一章再也没有能放的了：别再顶着「想播」，否则保活静音会一直挂着，
            // 而卡片也停在一个永远等不到的位置上。
            wantsToPlay = false
            nowPlaying.setRate(0)
            updateAudioHold()
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
                    // 只在**人造接缝**上记这一笔：被 48 字上限裁开的那半句后面紧跟的是另一次
                    // 合成，那一下停顿是「尾静音 + 换 item」两样叠出来的，量不到换 item 那一半
                    // 就没法判断该不该动播放器。自然句末和跨章（等的是读盘排产，形状不同）都不量。
                    if self.currentSentenceIndex < self.sentences.count - 1,
                       SentenceSplitter.endsMidClause(
                           self.sentences[self.currentSentenceIndex].text
                       ) {
                        self.seamClock = (self.currentSentenceIndex, CFAbsoluteTimeGetCurrent())
                    }
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
