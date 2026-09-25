//
//  PlayerView.swift
//  Reader
//
//  Created by 粟海洋 on 2026/8/26.
//

import SwiftUI

/// 「播放」这一页。两种身份：
///
/// - 从阅读页点开的弹层：只当 PlayerManager 现状的展示面（`ownsSession = false`），
///   续播、落进度、订阅生成都归阅读页，别和它抢同一份状态；
/// - tab 上独立的一页：自己把上次那本书那一章那一句话捞起来（`ownsSession = true`）。
struct PlayerView: View {

    @ObservedObject
    var player: PlayerManager

    /// 这一页要不要自己掌管会话（续播 / 进度落盘 / 订阅生成结果）。
    var ownsSession: Bool = true

    private let pipeline =
            ReaderContainer.shared.pipeline

    private let bookStore = BookStore.shared

    /// 列表的行沿用系统 `.body` 的字号，段距按这个字号算。
    private static let rowBodySize: CGFloat = 17

    /// 攒够这么多句才落一次盘：每句都写会把整份书单重新编码一遍。
    private static let persistStride = 8

    private let speedOptions: [Double] = [
        0.75, 1.0, 1.25, 1.5, 2.0
    ]

    @State private var lastPersistedSentence = -1

    /// 续播失败的原因。不静默吞掉：最常见的就是书单记的正文路径读不到，
    /// 一句「续播失败：…」比一个空页面有用得多。
    @State private var resumeFailure: String?

    /// 续播正在进行：这一刻句子还是空的，但别急着说「从书库打开一章」，
    /// 正文马上就到。
    @State private var isResuming = false

    /// 给「回到当前句」用的列表滚动器。ScrollViewReader 只在自己的构建闭包里递
    /// proxy，播放坞在它外面，所以从这里接过去。
    @State private var scrollProxy: ScrollViewProxy?

    /// 章标题。正文第一句常常就是它本身（EPUB 的 `<h1>` 被抽成了第一段），
    /// 它要按标题排：居中、不缩进。
    private var chapterTitle: String {
        player.currentChapter?.title ?? ""
    }

    var body: some View {

        Group {

            if player.sentences.isEmpty {

                emptyState

            } else {

                VStack(spacing: 0) {

                    header

                    sentenceList

                    dock
                }
            }
        }
        .background(
            Color(.systemBackground)
        )
        .navigationTitle(
            player.currentChapter?.title
                ?? "尚未播放"
        )
        .navigationBarTitleDisplayMode(
            .inline
        )
        .task {
            await resumeLastSession()
        }
        // 换章（含播到章末自动推进的那一章）就换订阅：这一章新合成出来的音频
        // 要能填进 player.sentences，否则播放会停在等不到的那一句上。
        .task(id: ownsSession ? player.currentChapter?.id : nil) {
            await watchCurrentChapter()
        }
        .onChange(of: player.currentSentenceIndex) { _, newIndex in
            sentenceChanged(newIndex)
        }
        .onDisappear {
            persistProgress(force: true)
        }
    }

    // MARK: - Resume

    /// 打开这一页就把上次关闭前的那本书、那一章、那一句捞回来。
    private func resumeLastSession() async {

        guard ownsSession, player.currentChapter == nil else {
            return
        }

        isResuming = true
        defer { isResuming = false }

        guard let book = await bookStore.lastReadBook(),
              !book.chapters.isEmpty else {
            return
        }

        let index = min(
            max(book.lastReadChapter, 0),
            book.chapters.count - 1
        )

        do {
            _ = try await player.start(
                book: book,
                chapter: book.chapters[index],
                restoreTo: book.lastReadSentence,
                pipeline: pipeline
            )
            resumeFailure = nil
        } catch {
            resumeFailure = error.localizedDescription
            print("⚠️ [播放页] 续播失败：\(error)")
        }
    }

    private func watchCurrentChapter() async {

        guard ownsSession, let chapterID = player.currentChapter?.id else {
            return
        }

        do {
            for try await updated in await pipeline.chapterUpdates(chapterID) {
                // 只喂句子：这一页不翻页，位置也不动，音频到位就能接着播。
                player.updateSentences(updated.sentences)
            }
        } catch {
            print("⚠️ [播放页] 章节更新流中断：\(error)")
        }
    }

    private func sentenceChanged(_ index: Int) {

        guard ownsSession else {
            return
        }

        persistProgress()

        Task {
            await player.reportPosition(index)
        }
    }

    /// 阅读位置落盘（章下标 + 章内句序）。
    private func persistProgress(force: Bool = false) {

        guard ownsSession else {
            return
        }

        let sentenceIndex = player.currentSentenceIndex

        guard force
              || abs(sentenceIndex - lastPersistedSentence) >= Self.persistStride
        else {
            return
        }

        lastPersistedSentence = sentenceIndex

        let bookID = player.currentBook?.id
        let chapterIndex = player.currentChapterIndex

        Task {
            guard let bookID else { return }
            await bookStore.setProgress(
                bookID: bookID,
                chapterIndex: chapterIndex,
                sentenceIndex: sentenceIndex
            )
        }
    }

    // MARK: - Header

    private var header: some View {

        VStack(alignment: .leading, spacing: 10) {

            HStack(alignment: .top, spacing: 10) {

                VStack(alignment: .leading, spacing: 2) {

                    if let book = player.currentBook {
                        Text(book.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Text(chapterHeading)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                statusChip
            }

            progressBar(
                value: player.chapterProgress,
                height: 4
            )

            HStack {
                Spacer()

                Text(
                    "本章 \(Int(player.chapterProgress * 100))%"
                )
            }
            .font(.caption2)
            .monospacedDigit()
            .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .background(
            Color(.secondarySystemBackground)
        )
    }

    /// 章名一律用章自己的标题。别在这里拼「第 N 章」：N 是书单数组下标，
    /// 书里印的章号是另一套（前言占一格、正文从「第5章」起），两套号并排就成了
    /// 「第 9 章 · 第5章…」这种看着像出错的样子。
    private var chapterHeading: String {
        player.currentChapter?.title ?? "尚未播放"
    }

    /// 这一章还缺什么：分析没完、语音没完、还是两边某一类失败了。
    @ViewBuilder
    private var statusChip: some View {

        let status = generationStatus

        if let status {
            Label(status.text, systemImage: status.image)
                .font(.caption2)
                .foregroundStyle(status.tone)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(status.tone.opacity(0.12))
                )
        }
    }

    private var generationStatus: (text: String, image: String, tone: Color)? {

        guard let chapter = player.currentChapter else {
            return nil
        }

        if chapter.analysisStatus == .failed || chapter.ttsStatus == .failed {
            return ("生成失败", "exclamationmark.triangle.fill", .orange)
        }
        if chapter.ttsStatus != .completed {
            return ("语音准备中", "waveform", Color.accentColor)
        }
        if chapter.analysisStatus != .completed {
            return ("AI 分析中", "sparkles", Color.accentColor)
        }
        return nil
    }

    private func progressBar(
        value: Double,
        height: CGFloat
    ) -> some View {

        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(Color.accentColor)
                    .frame(
                        width: proxy.size.width * min(max(value, 0), 1)
                    )
            }
        }
        .frame(height: height)
        .animation(
            .easeOut(duration: 0.2),
            value: value
        )
    }

    // MARK: - Sentence list

    private var sentenceList: some View {

        ScrollViewReader { proxy in

            ScrollView {

                LazyVStack(
                    alignment: .leading,
                    // 段距由每行自己的 top padding 给（见 `sentenceRow`）：
                    // 这里再给一份的话，段内句子之间也会出现空隙，
                    // 一段读起来又成了断开的好几条。
                    spacing: 0
                ) {

                    ForEach(
                        player.sentences
                    ) { sentence in

                        sentenceRow(
                            sentence,
                            isActive: sentence.index
                                == player.currentSentenceIndex
                        )
                        .id(sentence.index)
                        .onTapGesture {

                            player.playSentence(
                                at: sentence.index
                            )
                        }
                    }
                }
                .padding(
                    .horizontal, 16
                )
                .padding(
                    .top, 14
                )
                .padding(
                    .bottom, 24
                )
            }
            .onChange(
                of: player.currentSentenceIndex
            ) { _, newIndex in

                withAnimation(
                    .easeInOut(
                        duration: 0.3
                    )
                ) {

                    proxy.scrollTo(
                        newIndex,
                        anchor: .center
                    )
                }
            }
            .onAppear {
                scrollProxy = proxy
            }
        }
    }

    @ViewBuilder
    private func sentenceRow(
        _ sentence: Sentence,
        isActive: Bool
    ) -> some View {

        let isHeading = ReaderTypography.isChapterHeading(
            sentence,
            chapterTitle: chapterTitle
        )

        HStack(
            alignment: .top,
            spacing: 8
        ) {

            // 当前句的左轴：读长段时光标高亮整条底色太糊，一条竖杠就够指位
            Capsule()
                .fill(isActive ? Color.accentColor : Color.clear)
                .frame(width: 2.5)
                .padding(.vertical, 3)

            VStack(
                alignment: isHeading ? .center : .leading,
                spacing: 4
            ) {

                if sentence.speaker == .character,
                   let name = sentence.characterName {

                    HStack(spacing: 4) {

                        Text(name)

                        if isActive, player.isPlaying {
                            Image(systemName: "waveform")
                                .symbolEffect(
                                    .variableColor.iterative,
                                    options: .repeating
                                )
                        }
                    }
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(
                        isActive
                            ? Color.accentColor
                            : .secondary
                    )
                }

                Text(
                    ReaderTypography.displayText(
                        sentence,
                        chapterTitle: chapterTitle
                    )
                )
                    .font(
                        .system(
                            size: Self.rowBodySize,
                            weight: isActive ? .semibold : .regular
                        )
                    )
                    .multilineTextAlignment(isHeading ? .center : .leading)
                    .frame(
                        maxWidth: .infinity,
                        alignment: isHeading ? .center : .leading
                    )
                    .foregroundStyle(
                        isActive
                            ? .primary
                            : .secondary
                    )
            }
        }
        .padding(
            .top,
            ReaderTypography.gap(
                before: sentence,
                startsPage: sentence.index == 0,
                size: Self.rowBodySize
            )
        )
        .padding(
            // 段内句子之间只留这一点（高亮条的下沿），段距由上面的 gap 给
            .bottom, 6
        )
        .padding(
            .horizontal, 10
        )
        .frame(
            maxWidth: .infinity,
            alignment: .leading
        )
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(
                    isActive
                        ? Color.accentColor.opacity(0.10)
                        : Color.clear
                )
        )
        .animation(
            .easeInOut(
                duration: 0.2
            ),
            value: isActive
        )
    }

    // MARK: - Dock

    private var dock: some View {

        VStack(spacing: 12) {

//            sentenceScrub

            HStack(spacing: 0) {

                speedMenu

                Spacer()

                stepButton(
                    system: "backward.end.fill",
                    label: "上一句",
                    enabled: player.currentSentenceIndex > 0
                ) {
                    player.playSentence(
                        at: player.currentSentenceIndex - 1
                    )
                }

                playButton
                    .padding(.horizontal, 18)

                stepButton(
                    system: "forward.end.fill",
                    label: "下一句",
                    enabled: player.currentSentenceIndex
                        < player.sentences.count - 1
                ) {
                    player.playSentence(
                        at: player.currentSentenceIndex + 1
                    )
                }

                Spacer()

                // 右边放「回到正在播的那一句」：手动往上翻过之后，这是唯一的锚点
                locateButton
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 6)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            // 毛玻璃坞和正文之间要有条界线，不然滚动的字会糊到按钮底下
            Divider()
        }
    }

    /// 句内进度。一句音频常常只有几秒，所以拖动的是这一句而不是整章。
//    private var sentenceScrub: some View {
//
//        HStack(spacing: 10) {
//
//            Text(Self.clock(player.currentTime))
//            Text("/")
//                .foregroundStyle(.quaternary)
//            Text(Self.clock(player.duration))
//                .foregroundStyle(.secondary)
//
//            Slider(
//                value: Binding(
//                    get: { player.progress },
//                    set: { player.seek(to: $0 * player.duration) }
//                ),
//                in: 0...1
//            )
//            .disabled(player.duration <= 0)
//        }
//        .font(.caption2)
//        .monospacedDigit()
//        .foregroundStyle(.secondary)
//    }

    private var playButton: some View {

        Button {
            player.togglePlay()
        } label: {
            Image(
                systemName: player.isPlaying
                    ? "pause.fill"
                    : "play.fill"
            )
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 58, height: 58)
            .background(
                Circle()
                    .fill(Color.accentColor)
            )
            .shadow(
                color: Color.accentColor.opacity(0.35),
                radius: 8,
                y: 3
            )
        }
        .accessibilityLabel(
            player.isPlaying ? "暂停" : "播放"
        )
    }

    private func stepButton(
        system: String,
        label: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {

        Button(
            action: action
        ) {
            Image(systemName: system)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(
                    enabled ? Color.primary : Color.secondary.opacity(0.45)
                )
                .frame(width: 42, height: 42)
                .background(
                    Circle()
                        .fill(Color.primary.opacity(0.06))
                )
        }
        .accessibilityLabel(label)
    }

    /// 把列表滚回正在播的那一句。
    private var locateButton: some View {

        Button {
            withAnimation(.easeInOut(duration: 0.3)) {
                scrollProxy?.scrollTo(
                    player.currentSentenceIndex,
                    anchor: .center
                )
            }
        } label: {
            Image(systemName: "dot.scope")
                .font(.system(size: 17, weight: .medium))
                .frame(width: 42, height: 42)
                .background(
                    Circle()
                        .fill(Color.primary.opacity(0.06))
                )
        }
        .accessibilityLabel("回到当前句")
    }

    private var speedMenu: some View {

        Menu {

            ForEach(
                speedOptions,
                id: \.self
            ) { rate in

                Button {

                    player.playbackRate = rate

                } label: {

                    HStack {

                        Text(
                            String(
                                format: "%.2fx",
                                rate
                            )
                        )

                        if player.playbackRate == rate {

                            Image(
                                systemName: "checkmark"
                            )
                        }
                    }
                }
            }

        } label: {

            HStack(spacing: 4) {

                Image(
                    systemName: "speedometer"
                )

                Text(
                    String(
                        format: "%.2gx",
                        player.playbackRate
                    )
                )
            }
            .font(.caption.weight(.medium))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(Color.primary.opacity(0.06))
            )
        }
    }

    // MARK: - Empty

    private var emptyState: some View {

        VStack(spacing: 14) {

            Spacer()

            Image(
                systemName: "headphones"
            )
            .font(.system(size: 46, weight: .light))
            .foregroundStyle(.secondary)
            .frame(width: 96, height: 96)
            .background(
                Circle()
                    .fill(Color.primary.opacity(0.05))
            )

            Text(
                isResuming
                    ? "准备播放"
                    : "还没有正在播的章节"
            )
                .font(.title3.weight(.semibold))

            if isResuming {

                HStack(spacing: 8) {

                    ProgressView()
                        .controlSize(.small)

                    Text("正在接上上次读到的地方")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

            } else if let reason = resumeFailure {

                Text("续播失败：\(reason)")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)

            } else {

                Text("从书库里打开一章，下次进这一页就会自动接上这里")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
            }

            Spacer()
        }
        .frame(
            maxWidth: .infinity
        )
    }

    /// 秒 → m:ss。等宽数字，不然时间一跳整条进度就抖。
    private static func clock(
        _ seconds: Double
    ) -> String {

        guard seconds.isFinite, seconds >= 0 else {
            return "0:00"
        }

        let total = Int(seconds.rounded())

        return String(
            format: "%d:%02d",
            total / 60,
            total % 60
        )
    }
}
