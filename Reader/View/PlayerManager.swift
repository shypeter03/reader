//
//  PlayerManager.swift
//  Reader
//
//  Created by 粟海洋 on 2026/8/26.
//

import Foundation
import AVFoundation
import Combine

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

    private init() {
        configureAudioSession()
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

    // MARK: - Configure

    func configure(
        chapters: [ChapterDescriptor],
        currentIndex: Int
    ) {
        self.chapters = chapters
        self.currentChapterIndex = currentIndex
    }

    // MARK: - Load Chapter

    func load(chapter: Chapter) {

        stop()

        awaitingAudio = false

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

            playCurrentSentence()
        }
    }

    // MARK: - Load Next Chapter

    func loadNextChapter(_ chapter: Chapter) {

        currentChapterIndex += 1

        wantsToPlay = true

        load(chapter: chapter)

        playCurrentSentence()
    }

    // MARK: - Play

    func play() {

        guard
            !sentences.isEmpty
        else {
            return
        }

        wantsToPlay = true

        if player == nil {
            playCurrentSentence()
            return
        }

        player?.rate = Float(playbackRate)

        isPlaying = true
    }

    // MARK: - Pause

    func pause() {

        wantsToPlay = false

        awaitingAudio = false

        player?.pause()

        isPlaying = false
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
    }

    // MARK: - Seek

    func seek(to seconds: Double) {

        guard
            let player,
            duration > 0
        else {
            return
        }

        let value = max(
            0,
            min(seconds, duration)
        )

        let time = CMTime(
            seconds: value,
            preferredTimescale: 600
        )

        player.seek(
            to: time,
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    // MARK: - Skip

    func skipForward() {

        seek(
            to: currentTime + 15
        )
    }

    func skipBackward() {

        seek(
            to: currentTime - 15
        )
    }

    func playSentence(at index: Int) {

        guard sentences.indices.contains(index) else {
            return
        }

        wantsToPlay = true

        currentSentenceIndex = index
        playCurrentSentence()
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
                }
                return
            }

            awaitingAudio = true

            isPlaying = false

            return
        }

        awaitingAudio = false

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
        }

        guard let player else { return }

        player.rate = Float(playbackRate)

        onAudioStarted?(currentSentenceIndex)

        observeEnd(item: item)

        addTimeObserver(player: player)

        isPlaying = true
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

            Task {
                if let next = await callback() {
                    self.loadNextChapter(next)
                } else {
                    self.isPlaying = false
                    self.progress = 1
                }
            }

        } else {

            isPlaying = false
            progress = 1
        }
    }
}
