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

                print("================================")
                print("开始 AI 流式分析章节")
                print("章节：\(chapter.title)")
                print("句子数量：\(total)")
                print("================================")

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

                        print("处理批次 \(batchNumber)，句子 \(start)-\(end - 1)")

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

                        MemoryProbe.log("Batch \(batchNumber) 分析前")

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

        for attempt in 1 ... 2 {

            let response = try await ai.generate(prompt: prompt)
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
            let indices = expectedIndices.map(String.init).joined(separator: ",")
            prompt = basePrompt + """

            上一份输出无效（\(summary)）。丢弃它并从头重新输出完整 JSON；不要修补、不要解释。
            外层数组必须含恰好 \(expectedIndices.count) 行，第一列必须依次为 [\(indices)]。
            每行都必须恰好 7 个元素：[index,"n"或"d",name或null,emotion,0...1,0.7...1.3,-0.2...0.2]。
            任何不确定项都用合法保守值 [index,"n",null,"neutral",0.5,1.0,0.0]，绝不能遗漏字段或提前结束数组。
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

            updated.type = analysis.type
            updated.speaker = analysis.speaker

            if analysis.speaker == .character {

                let characterName = analysis.characterName
                updated.characterName = characterName

                if let characterName {
                    updated.characterID = chapter.characters.first {
                        $0.name == characterName
                    }?.id
                } else {
                    updated.characterID = nil
                }

            } else {

                updated.characterName = nil
                updated.characterID = nil
            }

            updated.emotion = analysis.emotion
            updated.emotionIntensity = clamp(analysis.emotionIntensity, min: 0, max: 1)
            updated.speed = clamp(analysis.speed, min: 0.7, max: 1.3)
            updated.pitch = clamp(analysis.pitch, min: -0.2, max: 0.2)
            updated.voiceStrength = clamp(
                analysis.voiceStrength,
                min: AITools.voiceStrengthFloor,
                max: 1
            )

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
