//
//  TTSGenerator.swift
//  Reader
//

import Foundation
import AVFoundation

actor TTSGenerator {

    private let tts: TTSService

    private let audioStore: AudioStore

    init(
        tts: TTSService,
        audioStore: AudioStore
    ) {
        self.tts = tts
        self.audioStore = audioStore
    }

    // MARK: - Generate (full chapter)

    func generate(
        chapter: Chapter,
        bookID: UUID
    ) async throws -> Chapter {

        var chapter = chapter

        chapter.audioStatus = .generating

        for index in chapter.sentences.indices {

            let sentence = chapter.sentences[index]

            chapter.sentences[index] =
                try await produceAudio(
                    for: sentence,
                    in: chapter,
                    bookID: bookID
                )
        }

        chapter.audioStatus = .completed

        return chapter
    }

    // MARK: - Synthesize (sentence range, for interleaved pipeline)

    /// 只合成 [range) 内尚未就绪的句子并写盘，返回带音频的章节快照。
    /// 供 ReaderPipeline「分析一批→合成一批→播放」的交错流程调用。
    /// 逐句处理天然限流：一次只驻留一句的原始波形，写完即释放。
    func synthesize(
        chapter: Chapter,
        range: Range<Int>,
        bookID: UUID
    ) async throws -> Chapter {

        var chapter = chapter

        var startTime = CFAbsoluteTimeGetCurrent()

        for offset in range {

            if Task.isCancelled {
                throw CancellationError()
            }
            startTime = CFAbsoluteTimeGetCurrent()

            guard offset < chapter.sentences.count else { break }

            let sentence = chapter.sentences[offset]

            MemoryProbe.log("Sentence \(sentence.index) TTS 前")

            do {
                chapter.sentences[offset] =
                    try await Self.produce(
                        sentence: sentence,
                        chapter: chapter,
                        bookID: bookID,
                        tts: tts,
                        audioStore: audioStore
                    )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // 单句失败不拖垮整章：该句留空（播放器跳过无音频句），
                // 下次进入章节时磁盘无缓存会自然重试。
                print("⚠️ 句 \(sentence.index) 合成失败，跳过：\(error.localizedDescription)")
            }

            let endTime = CFAbsoluteTimeGetCurrent()
            let elapsedMs = (endTime - startTime) * 1000
            MemoryProbe.log("Sentence \(sentence.index) TTS 后,耗时：\(String(format: "%.2f", elapsedMs)) ms")
        }

        return chapter
    }

    /// 调度器的最小工作单元：一个句子。缓存命中时不会加载/调用模型。
    func synthesizeSentence(
        chapter: Chapter,
        sentenceIndex: Int,
        bookID: UUID
    ) async throws -> Chapter {
        guard chapter.sentences.indices.contains(sentenceIndex) else { return chapter }
        var updated = chapter
        updated.sentences[sentenceIndex].audioStatus = .running
        updated.sentences[sentenceIndex] = try await Self.produce(
            sentence: updated.sentences[sentenceIndex],
            chapter: updated,
            bookID: bookID,
            tts: tts,
            audioStore: audioStore
        )
        updated.sentences[sentenceIndex].audioStatus = .completed
        return updated
    }

    // MARK: - Generate (streaming)

    /// 边生成边返回：每完成一句（首批）或每完成一批（后续）就 yield 一次
    /// 当前的 Chapter 快照，前台可以立即播放已经就绪的句子。
    func generateStreaming(
        chapter: Chapter,
        bookID: UUID,
        batchSize: Int = 5
    ) -> AsyncThrowingStream<Chapter, Error> {

        let tts = self.tts
        let audioStore = self.audioStore

        return AsyncThrowingStream { continuation in

            Task {

                do {

                    var chapter = chapter

                    chapter.audioStatus = .generating

                    let count = chapter.sentences.count

                    var index = 0
                    var batchStart = 0

                    while index < count {

                        if Task.isCancelled {
                            continuation.finish()
                            return
                        }

                        let sentence = chapter.sentences[index]

                        chapter.sentences[index] =
                            try await Self.produce(
                                sentence: sentence,
                                chapter: chapter,
                                bookID: bookID,
                                tts: tts,
                                audioStore: audioStore
                            )

                        index += 1

                        let isFirstSentence = (index == 1)
                        let isBatchEnd =
                            (index - batchStart) >= batchSize
                            || index == count

                        if isFirstSentence || isBatchEnd {

                            if isBatchEnd {
                                batchStart = index
                            }

                            continuation.yield(chapter)
                        }
                    }

                    chapter.audioStatus = .completed

                    continuation.yield(chapter)

                    continuation.finish()

                } catch {

                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Produce Audio For One Sentence

    private func produceAudio(
        for sentence: Sentence,
        in chapter: Chapter,
        bookID: UUID
    ) async throws -> Sentence {

        try await Self.produce(
            sentence: sentence,
            chapter: chapter,
            bookID: bookID,
            tts: tts,
            audioStore: audioStore
        )
    }

    /// 复用磁盘缓存：已存在则直接返回，不再重新合成。
    private static func produce(
        sentence: Sentence,
        chapter: Chapter,
        bookID: UUID,
        tts: TTSService,
        audioStore: AudioStore
    ) async throws -> Sentence {

        if let existing = await audioStore.load(
            bookID: bookID,
            chapterID: chapter.id,
            sentenceID: sentence.id
        ) {

            var reused = sentence
            reused.audioURL = existing

            if reused.duration == nil {
                reused.duration =
                    try? await audioDuration(url: existing)
            }

            return reused
        }

        let voiceID = resolveVoiceID(
            sentence: sentence,
            chapter: chapter,
            bookID: bookID
        )

        let audioData =
            try await tts.synthesize(
                text: sentence.text,
                voiceID: voiceID,
                emotion: sentence.emotion,
                intensity: sentence.emotionIntensity,
                speed: sentence.speed,
                pitch: sentence.pitch
            )

        let saveStart = CFAbsoluteTimeGetCurrent()

        let url =
            try await audioStore.save(
                data: audioData,
                bookID: bookID,
                chapterID: chapter.id,
                sentenceID: sentence.id
            )

        let duration =
            try await audioDuration(url: url)

        let saveMs = (CFAbsoluteTimeGetCurrent() - saveStart) * 1000
        print("[TTS⏱] 存盘+读时长 \(String(format: "%.0f", saveMs))ms (句 \(sentence.index), \(audioData.count)B)")

        var updated = sentence
        updated.audioURL = url
        updated.duration = duration

        return updated
    }

    // MARK: - Voice Resolution

    /// 作废一句音频：LLM 改了参数后旧 WAV 必须从磁盘消失，否则下一次
    /// produce 的缓存命中会把它原样取回来，重录等于没发生。
    func discardAudio(
        bookID: UUID,
        chapterID: UUID,
        sentenceID: UUID
    ) async {
        await audioStore.delete(
            bookID: bookID,
            chapterID: chapterID,
            sentenceID: sentenceID
        )
    }

    func discardBookAudio(
        bookID: UUID
    ) async {
        await audioStore.deleteBook(
            bookID: bookID
        )
    }

    private static func resolveVoiceID(
        sentence: Sentence,
        chapter: Chapter,
        bookID: UUID
    ) -> String {

        if sentence.speaker == .narrator {

            return VoiceManager.narratorVoice()
        }

        guard let characterID = sentence.characterID else {
            return VoiceManager.fallbackVoice()
        }

        guard let character = chapter.characters.first(
            where: { $0.id == characterID }
        ) else {
            return VoiceManager.fallbackVoice()
        }

        if let existing = character.voiceID,
           !existing.isEmpty,
           existing != "default" {
            return existing
        }

        return VoiceManager.voiceForCharacter(
            gender: character.gender,
            age: character.age,
            bookID: bookID
        )
    }

    // MARK: - Audio Duration

    private static func audioDuration(
        url: URL
    ) async throws -> Double {

        let asset =
            AVURLAsset(url: url)

        let duration =
            try await asset.load(.duration)

        return duration.seconds
    }

    // MARK: - Unload

    func unloadModel() async {
        if let mlxService = tts as? Qwen3TTSService {
            await mlxService.unload()
        }
    }
}
