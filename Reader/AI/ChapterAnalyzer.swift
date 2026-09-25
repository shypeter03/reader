//
//  ChapterAnalyzer.swift
//  Reader
//
//  Created by 粟海洋 on 2026/8/26.
//

import Foundation

/// 一次流式分析产出的进度快照。
/// - `chapter`：截至本次、前 `analyzedEnd` 句已完成标注的章节快照。
/// - `analyzedEnd`：已分析句子的数组上界（单调递增），调用方可据此
///   只对 `[上次 end, analyzedEnd)` 这一段做 TTS，实现逐批交错。
struct AnalysisProgress: Sendable {
    let chapter: Chapter
    let analyzedEnd: Int
}

actor ChapterAnalyzer {

    private let ai: AIService

    /// 首批句子数刻意远小于常规批次，用于压低 TTFA（首次可播放音频时间）。
    /// 只需 2 句即可开播：每句 TTS ~数秒，首批越小，用户越早听到声音。
    private let firstBatchSize = 2
    private let batchSize = 10

    init(
        ai: AIService
    ) {
        self.ai = ai
    }

    // MARK: - Analyze (whole chapter)

    func analyze(
        chapter: Chapter,
        context: StoryContext
    ) async throws -> Chapter {

        var latest = chapter

        for try await progress in analyzeStreaming(
            chapter: chapter,
            context: context
        ) {
            latest = progress.chapter
        }

        return latest
    }

    /// 调度器使用的独立批次入口。它不会等待章节的其他批次，因此可被优先队列重排。
    func analyzeBatch(
        chapter: Chapter,
        range: Range<Int>,
        context: StoryContext
    ) async throws -> Chapter {
        guard !range.isEmpty else { return chapter }
        var updated = chapter
        let safeRange = max(0, range.lowerBound)..<min(chapter.sentences.count, range.upperBound)
        guard !safeRange.isEmpty else { return chapter }
        let batch = Array(chapter.sentences[safeRange])
        let batchChapter = Chapter(
            id: chapter.id,
            index: chapter.index,
            title: chapter.title,
            sentences: batch,
            characters: chapter.characters,
            audioStatus: chapter.audioStatus,
            textStatus: chapter.textStatus,
            analysisStatus: .running,
            ttsStatus: chapter.ttsStatus
        )
        let result = try await analyzeBatch(
            basePrompt: AITools.buildPrompt(chapter: batchChapter, context: context),
            expectedIndices: batch.map(\.index),
            ai: ai
        )
        apply(result, to: &updated, range: safeRange)
        for index in safeRange { updated.sentences[index].analysisStatus = .completed }
        return updated
    }

    // MARK: - Analyze (streaming, batch by batch)

    /// 逐批分析并 yield 章节快照：每次 yield 时，前 `k` 句已完成标注，
    /// 后面的句子尚未处理。调用方可立即对这 `k` 句做 TTS，实现
    /// 「生产一批、消费一批」，无需等待整章分析完成。
    func analyzeStreaming(
        chapter: Chapter,
        context: StoryContext
    ) -> AsyncThrowingStream<AnalysisProgress, Error> {

        let ai = self.ai
        let firstBatchSize = self.firstBatchSize
        let batchSize = self.batchSize

        return AsyncThrowingStream { continuation in

            let task = Task {

                var chapter = chapter
                chapter.audioStatus = .analyzing

                let sentences = chapter.sentences
                let total = sentences.count

                print("[LLM] 流式分析章节：\(chapter.title)（\(total) 句）")

                if total == 0 {
                    chapter.audioStatus = .pending
                    continuation.yield(
                        AnalysisProgress(chapter: chapter, analyzedEnd: 0)
                    )
                    continuation.finish()
                    return
                }

                var start = 0
                var batchNumber = 0

                do {
                    while start < total {

                        if Task.isCancelled {
                            continuation.finish()
                            return
                        }

                        let size = (start == 0) ? firstBatchSize : batchSize
                        let end = min(start + size, total)
                        let batchSentences = Array(sentences[start..<end])
                        batchNumber += 1

                        print("[LLM] 批次 \(batchNumber) 句 \(start)-\(end - 1)")

                        let batchChapter = Chapter(
                            id: chapter.id,
                            index: chapter.index,
                            title: chapter.title,
                            sentences: batchSentences,
                            characters: chapter.characters,
                            audioStatus: chapter.audioStatus
                        )

                        let prompt = AITools.buildPrompt(
                            chapter: batchChapter,
                            context: context
                        )

                        let result = try await analyzeBatch(
                            basePrompt: prompt,
                            expectedIndices: batchSentences.map { $0.index },
                            ai: ai
                        )

                        apply(
                            result,
                            to: &chapter,
                            range: start..<end
                        )

                        // 「分析前」不再单列：调度器起批时那条 [Memory] 就是同一份数据
                        MemoryProbe.log("Batch \(batchNumber) 分析后")

                        continuation.yield(
                            AnalysisProgress(chapter: chapter, analyzedEnd: end)
                        )

                        start = end
                    }

                    chapter.audioStatus = .pending
                    continuation.yield(
                        AnalysisProgress(chapter: chapter, analyzedEnd: total)
                    )
                    continuation.finish()

                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// 生成 + schema 校验一批。缺字段/非法值视为失败：带反馈提示重试一次，
    /// 最终取问题最少的输出（参数均已修正到合法值，不影响 TTS 与播放连续性）。
    private func analyzeBatch(
        basePrompt: String,
        expectedIndices: [Int],
        ai: AIService
    ) async throws -> AIAnalysisResult {

        var prompt = basePrompt
        var bestResult: AIAnalysisResult?
        var bestIssueCount = Int.max

        // 一行四个字段约 8 个 token，24 是留余量的上界。不再用 4096：那等于允许模型
        // 在一批 10 句上跑进重复循环，KV 一路涨到几个 GB，还要几十秒才停。
        let maxTokens = 32 + expectedIndices.count * 24

        for attempt in 1 ... 2 {

            let response = try await ai.generate(
                prompt: prompt,
                maxTokens: maxTokens
            )
            let (result, issues) = AITools.parseResponse(
                response,
                expectedIndices: expectedIndices
            )

            if issues.isEmpty {
                return result
            }

            if issues.count < bestIssueCount {
                bestIssueCount = issues.count
                bestResult = result
            }

            guard attempt < 2 else { break }

            let summary = issues.prefix(4).joined(separator: "；")
            let indices = expectedIndices.map(String.init).joined(separator: " ")
            prompt = basePrompt + """

            上一份输出无效（\(summary)）。丢弃它并从头重新输出，不要修补、不要解释。
            共 \(expectedIndices.count) 行，每行 4 项、空格分开：序号 情绪 情绪强度 声音力度
            序号依次为 \(indices)；情绪只能是 neutral happy sad angry surprised fearful excited calm tense 之一；两个数字都在 0~1，不加引号、不加方括号。
            """
            print("↻ 批次重试生成（上轮问题 \(issues.count) 处）")
        }

        print("⚠️ 批次重试后仍有 \(bestIssueCount) 处不合规，采用问题最少的输出")
        return bestResult ?? AIAnalysisResult(sentences: [])
    }

    func unloadModel() async {
        MemoryProbe.log("LLM 卸载前")
        await ai.unload()
        MemoryProbe.log("LLM 卸载后")
    }

    // MARK: - Apply AI Result To A Sentence Range

    private func apply(
        _ result: AIAnalysisResult,
        to chapter: inout Chapter,
        range: Range<Int>
    ) {

        let byIndex = Dictionary(
            result.sentences.map { ($0.index, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        for offset in range {

            guard offset < chapter.sentences.count else { break }

            let sentence = chapter.sentences[offset]

            guard let analysis = byIndex[sentence.index] else {
                print("⚠️ AI 没有返回句子 index：\(sentence.index)")
                continue
            }

            var updated = sentence

            // 只有这 3 项来自模型：type / speaker 交回正则，speed / pitch 跟情绪查表。
            updated.emotion = analysis.emotion
            updated.emotionIntensity = clamp(analysis.emotionIntensity, min: 0, max: 1)
            updated.voiceStrength = clamp(
                analysis.voiceStrength,
                min: AITools.voiceStrengthFloor,
                max: 1
            )
            // speed / pitch 跟情绪查表，而不是跟模型：情绪被校准了，语速音调必须一起走，
            // 否则会出现「angry 却用 calm 的语速」。表就是 Emotion 那一份，
            // 和正则路径、和旧指令里的「按情绪推荐」完全同源。
            // 情绪没被改就不动这两列：正则给带「……」的句子留了 -0.03 的收尾减速，
            // 每次按表重算会把这点差别报成「参数变了」，白重录一句音频。
            if analysis.emotion != sentence.emotion {
                updated.speed = analysis.emotion.defaultSpeed
                updated.pitch = analysis.emotion.defaultPitch
            }

            chapter.sentences[offset] = updated
        }
    }

    // MARK: - Clamp

    private func clamp(
        _ value: Double,
        min: Double,
        max: Double
    ) -> Double {
        Swift.max(min, Swift.min(max, value))
    }
}
