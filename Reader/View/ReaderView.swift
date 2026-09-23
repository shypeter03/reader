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

    @State private var chapter: Chapter?

    @State private var showPlayer = false

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
        }
        .sheet(
            isPresented: $showPlayer
        ) {

            NavigationStack {

                PlayerView(
                    player: PlayerManager.shared
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

        let context =
            StoryContext(
                characters: [],
                recentCharacters: [],
                recentEvents: []
            )

        let currentIndex =
            book.chapters.firstIndex {
                $0.id == chapterDescriptor.id
            } ?? 0

        let nextDescriptor: ChapterDescriptor? =
            currentIndex + 1 < book.chapters.count
                ? book.chapters[currentIndex + 1]
                : nil

        let player = PlayerManager.shared

        player.configure(
            chapters: book.chapters,
            currentIndex: currentIndex
        )

        player.onAudioStarted = { sentenceIndex in
            Task {
                await pipeline.recordPlaybackStarted(
                    bookID: book.id,
                    chapterID: chapterDescriptor.id,
                    sentenceIndex: sentenceIndex
                )
            }
        }

        setupNextChapterCallback(
            player: player,
            context: context
        )

        do {

            // This returns raw text immediately. AI/TTS updates arrive through a
            // separate stream and never decide whether the reader can open.
            let initial = try await pipeline.openChapter(
                chapterDescriptor,
                bookID: book.id,
                context: context
            )
            self.chapter = initial
            player.load(chapter: initial)

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

    /// 动态解析「下一章」：优先缓存/后台任务，缺失才现场生成；
    /// 同时链式预处理再下一章。索引从 PlayerManager 实时读取，
    /// 因此跨章推进后无需重新注册。
    private func setupNextChapterCallback(
        player: PlayerManager,
        context: StoryContext
    ) {

        let chapters = book.chapters
        let bookID = book.id
        let pipeline = self.pipeline

        weak var weakPlayer = player

        player.onNeedNextChapter = {

            guard let player = weakPlayer else {
                return nil
            }

            let nextIndex = player.currentChapterIndex + 1

            guard nextIndex < chapters.count else {
                return nil
            }

            let descriptor = chapters[nextIndex]

            let next = await pipeline.resolveNext(
                descriptor,
                bookID: bookID,
                context: context
            )

            let followingIndex = nextIndex + 1

            return next
        }
    }

    @ViewBuilder
    private func readerContent(
        _ chapter: Chapter
    ) -> some View {

        VStack(spacing: 0) {

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

            ScrollViewReader { proxy in

                ScrollView {

                    LazyVStack(
                        alignment: .leading,
                        spacing: 16
                    ) {

                        if chapter.sentences.isEmpty {

                            Text(
                                "这一章没有可朗读的正文（图片页或空白页）"
                            )
                            .font(
                                .body
                            )
                            .foregroundStyle(
                                .secondary
                            )
                            .frame(
                                maxWidth: .infinity,
                                alignment: .center
                            )
                            .padding(
                                .top, 40
                            )
                        }

                        ForEach(
                            chapter.sentences
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
                        .horizontal, 20
                    )
                    .padding(
                        .top, 16
                    )
                    .padding(
                        .bottom, 100
                    )
                }
                .onChange(
                    of: player.currentSentenceIndex
                ) { _, newIndex in

                    Task {
                        let idx = book.chapters.firstIndex {
                            $0.id == chapterDescriptor.id
                        } ?? 0
                        await pipeline.updateReadingPosition(
                            bookID: book.id,
                            chapterID: chapterDescriptor.id,
                            sentenceIndex: newIndex,
                            nextChapterID: idx + 1 < book.chapters.count ? book.chapters[idx + 1].id : nil,
                            prevChapterID: idx > 0 ? book.chapters[idx - 1].id : nil
                        )
                    }

                    guard player.isPlaying else {
                        return
                    }

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
    private func sentenceRow(
        _ sentence: Sentence,
        isActive: Bool
    ) -> some View {

        VStack(
            alignment: .leading,
            spacing: 4
        ) {

            HStack(spacing: 6) {

                if sentence.speaker == .character,
                   let name = sentence.characterName {

                    Text(name)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(
                            isActive
                                ? Color.accentColor
                                : .secondary
                        )
                }

                if sentence.audioURL == nil {

                    Image(systemName: "hourglass")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Text(sentence.text)
                .font(.title3)
                .foregroundStyle(
                    isActive
                        ? .primary
                        : .secondary
                )
                .fontWeight(
                    isActive ? .semibold : .regular
                )
        }
        .padding(
            .vertical, 4
        )
        .animation(
            .easeInOut(
                duration: 0.2
            ),
            value: isActive
        )
    }

    @ViewBuilder
    private func playBar() -> some View {

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
