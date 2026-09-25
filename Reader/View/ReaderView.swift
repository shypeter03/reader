//
//  ReaderView.swift
//  Reader
//
//  Created by 粟海洋 on 2026/8/26.
//

import SwiftUI

struct ReaderView: View {

    let book: Book

    let chapterDescriptor: ChapterDescriptor

    private let pipeline =
            ReaderContainer.shared.pipeline

    private let bookStore = BookStore.shared

    @State private var chapter: Chapter?

    @State private var showPlayer = false

    /// 分页结果。只在「章 / 句数 / 角色名到位情况 / 页尺寸 / 字号」变化时重算。
    @State private var layout = PageLayout.placeholder

    @State private var currentPage = 0

    @State private var lastPersistedSentence = -1

    /// 本布局对应哪一章：换章那一次要把页码对齐到正在播的那句。
    @State private var layoutChapterID: UUID?

    @AppStorage("fontSize")
    private var fontScale: Double = 1.0

    @AppStorage("autoScroll")
    private var autoFollow = true

    @ObservedObject
    private var player = PlayerManager.shared

    private let speedOptions: [Double] = [
        0.75, 1.0, 1.25, 1.5, 2.0
    ]

    var body: some View {

        Group {

            if let chapter {

                readerContent(
                    chapter
                )

            } else {

                ProgressView(
                    "正在加载章节…"
                )
            }
        }
        .task {

            await loadChapter()
        }
        .onChange(of: player.currentChapter?.id) { _, newID in

            // PlayerManager 自动切换到下一章时，刷新正文展示
            guard newID != nil,
                  let played = player.currentChapter,
                  played.id != chapter?.id
            else {
                return
            }

            self.chapter = played

            lastPersistedSentence = -1

            persistProgress(force: true)
        }
        .onDisappear {

            // 关章 / 退到书单：把最后这一句落盘，下次进来才接着读
            persistProgress(force: true)
        }
        .sheet(
            isPresented: $showPlayer
        ) {

            NavigationStack {

                PlayerView(
                    player: PlayerManager.shared,
                    // 弹层只当展示面：会话是阅读页开起来的，续播、落进度、
                    // 订阅生成结果都在阅读页做，这一页再做一个就成两套进度互相覆盖。
                    ownsSession: false
                )
                .toolbar {

                    ToolbarItem(
                        placement:
                            .topBarTrailing
                    ) {

                        Button("完成") {

                            showPlayer
                                = false
                        }
                    }
                }
            }
        }
    }

    private func loadChapter() async {

        let currentIndex =
            book.chapters.firstIndex {
                $0.id == chapterDescriptor.id
            } ?? 0

        let player = PlayerManager.shared

        do {

            // openChapter 立刻返回正文；AI/TTS 的结果走下面那条流更新，
            // 绝不参与「这一章能不能打开」的判断。装配（书单、下一章回调、
            // 排产提示）在 PlayerManager.start 里，和播放页共用。
            let initial = try await player.start(
                book: book,
                chapter: chapterDescriptor,
                // 只有「接着上次那章」才恢复句序；另开一章从章首读起。
                restoreTo: currentIndex == book.lastReadChapter
                    ? book.lastReadSentence : nil,
                pipeline: pipeline
            )

            self.chapter = initial

            lastPersistedSentence = player.currentSentenceIndex

            // 打开即落一次位置：只读三句就退出的话，进度也该跟到这一章
            persistProgress(force: true)

            for try await updated in await pipeline.chapterUpdates(chapterDescriptor.id) {
                self.chapter = updated
                player.updateSentences(updated.sentences)
            }

        } catch {

            print(
                "章节加载失败:",
                error
            )
        }
    }

    // MARK: - Reading progress

    /// 阅读位置落盘（章下标 + 章内句序）。切一句写一次会把整份书单重新编码，
    /// 所以按句序节流：攒够 8 句才写，换章 / 关章时强制写一次。
    private func persistProgress(force: Bool = false) {

        let chapterIndex = player.currentChapterIndex

        let sentenceIndex = player.currentSentenceIndex

        guard force
              || abs(sentenceIndex - lastPersistedSentence) >= 8
        else {
            return
        }

        lastPersistedSentence = sentenceIndex

        let bookID = book.id

        Task {
            await bookStore.setProgress(
                bookID: bookID,
                chapterIndex: chapterIndex,
                sentenceIndex: sentenceIndex
            )
        }
    }
}

// MARK: - Content

private extension ReaderView {

    @ViewBuilder
    func readerContent(
        _ chapter: Chapter
    ) -> some View {

        VStack(spacing: 0) {

            statusRow(chapter)

            GeometryReader { geometry in

                pageReader(
                    chapter,
                    size: geometry.size
                )
            }

            playBar()
        }
        .navigationTitle(
            chapter.title
        )
        .navigationBarTitleDisplayMode(
            .inline
        )
        .toolbar {

            // 章节名居中：书本里标题在页面中轴上，导航栏默认左对齐是 App 的读法。
            // navigationTitle 保留，它管 VoiceOver 的屏幕标题。
            ToolbarItem(
                placement: .principal
            ) {
                Text(
                    chapter.title
                )
                .font(
                    .system(
                        size: 15,
                        weight: .semibold
                    )
                )
                .lineLimit(1)
                .frame(
                    maxWidth: .infinity,
                    alignment: .center
                )
            }

            ToolbarItem(
                id: "player",
                placement: .topBarTrailing
            ) {

                Button {

                    showPlayer = true

                } label: {

                    Image(
                        systemName:
                            "list.bullet"
                    )
                }
            }
        }
    }

    @ViewBuilder
    func statusRow(
        _ chapter: Chapter
    ) -> some View {

        if chapter.analysisStatus != .completed || chapter.ttsStatus != .completed {
            HStack(spacing: 8) {
                if chapter.analysisStatus != .completed {
                    Label(
                        chapter.analysisStatus == .failed ? "AI 分析失败" : "AI 分析中",
                        systemImage: chapter.analysisStatus == .failed ? "exclamationmark.triangle" : "sparkles"
                    )
                    if chapter.analysisStatus == .failed {
                        Button("重试") {
                            Task {
                                await pipeline.retryChapter(
                                    bookID: book.id,
                                    chapterID: chapterDescriptor.id
                                )
                            }
                        }
                        .font(.caption)
                    }
                }
                if chapter.ttsStatus != .completed {
                    Label(
                        chapter.ttsStatus == .failed ? "语音生成失败" : "语音准备中",
                        systemImage: chapter.ttsStatus == .failed ? "exclamationmark.triangle" : "waveform"
                    )
                    if chapter.ttsStatus == .failed {
                        Button("重试") {
                            Task {
                                await pipeline.retryChapter(
                                    bookID: book.id,
                                    chapterID: chapterDescriptor.id
                                )
                            }
                        }
                        .font(.caption)
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
    }

    func pageReader(
        _ chapter: Chapter,
        size: CGSize
    ) -> some View {

        TabView(selection: pageBinding) {

            ForEach(
                Array(layout.pages.enumerated()),
                id: \.offset
            ) { pageIndex, positions in

                ReaderPageView(
                    sentences: chapter.sentences,
                    positions: positions,
                    bodySize: layout.bodySize,
                    chapterTitle: chapter.title,
                    activePosition: player.currentSentenceIndex,
                    tap: { position in
                        player.playSentence(at: position)
                    }
                )
                .tag(pageIndex)
            }
        }
        .tabViewStyle(
            .page(indexDisplayMode: .never)
        )
        .background(Color(.systemBackground))
        .overlay(alignment: .bottomTrailing) {

            pageIndicator
        }
        .task(id: layoutKey(chapter, size)) {

            rebuildLayout(chapter, size: size)
        }
        .onChange(of: player.currentSentenceIndex) { _, newIndex in

            onSentenceChanged(newIndex)
        }
    }

    var pageBinding: Binding<Int> {

        Binding(
            get: {
                min(max(currentPage, 0), max(layout.pageCount - 1, 0))
            },
            set: {
                currentPage = $0
            }
        )
    }

    var pageIndicator: some View {

        Text(
            "\(min(currentPage + 1, layout.pageCount)) / \(layout.pageCount)"
        )
        .font(
            .caption
        )
        .monospacedDigit()
        .foregroundStyle(.tertiary)
        .padding(.trailing, 14)
        .padding(.bottom, 10)
        .allowsHitTesting(false)
    }

    /// 分页输入。角色名数量也在里面：LLM 认出说话人后每句要多占一行，
    /// 不重排的话页高会一路偏下去。
    func layoutKey(
        _ chapter: Chapter,
        _ size: CGSize
    ) -> String {

        let labeled =
            chapter.sentences.reduce(0) {
                $0 + ($1.characterName == nil ? 0 : 1)
            }

        return """
        \(chapter.id.uuidString)|\(chapter.sentences.count)|\(labeled)\
        |\(Int(size.width))x\(Int(size.height))|\(fontScale)
        """
    }

    func rebuildLayout(
        _ chapter: Chapter,
        size: CGSize
    ) {

        let next = PageLayout.paginate(
            chapter.sentences,
            in: size,
            scale: fontScale,
            chapterTitle: chapter.title
        )

        layout = next

        let isNewChapter = layoutChapterID != chapter.id

        if isNewChapter {
            layoutChapterID = chapter.id
        }

        // 换章：页码要跟到正在播的那句（打开时就是上次读到的那句）。
        // 同章重排（字号改了、角色名到了）：留在当前页，只把越界的页码收回来，
        // 免得用户手动翻到的那页被播放位置拽走。
        if isNewChapter {
            currentPage = next.page(containing: player.currentSentenceIndex)
        } else {
            currentPage = min(currentPage, next.pageCount - 1)
        }
    }

    func onSentenceChanged(
        _ newIndex: Int
    ) {

        persistProgress()

        Task {
            await player.reportPosition(newIndex)
        }

        guard autoFollow else {
            return
        }

        let target = layout.page(containing: newIndex)

        let shown = min(
            max(currentPage, 0),
            max(layout.pageCount - 1, 0)
        )

        guard target != shown else {
            return
        }

        withAnimation(
            .easeInOut(duration: 0.35)
        ) {
            currentPage = target
        }
    }

    @ViewBuilder
    func playBar() -> some View {

        HStack(spacing: 30) {

            Button {

                player.togglePlay()

            } label: {

                Image(
                    systemName:
                        player.isPlaying
                        ? "pause.circle.fill"
                        : "play.circle.fill"
                )
                .font(.system(size: 44))
            }

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

                VStack(spacing: 2) {

                    Image(
                        systemName:
                            "speedometer"
                    )
                    .font(.caption)

                    Text(
                        String(
                            format: "%.2fx",
                            player.playbackRate
                        )
                    )
                    .font(.caption2)
                }
                .foregroundStyle(.secondary)
                .frame(width: 50)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .padding(
            .horizontal, 20
        )
        .padding(
            .vertical, 12
        )
        .frame(maxWidth: .infinity)
        .background(
            .ultraThinMaterial
        )
    }
}
