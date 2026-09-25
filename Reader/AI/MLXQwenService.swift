//
//  MLXQwenService.swift
//  Reader
//
//  Created by 粟海洋 on 2026/8/26.
//

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import Tokenizers
import MLXNN


actor MLXQwenService: AIService {

    private var session: ChatSession?

    private var isLoaded = false

    private var model: ModelContext?

    // MARK: - Load Model

    func load() async throws {

        guard !isLoaded else {
            return
        }
        guard model == nil else {
            return
        }

        print("开始加载 Qwen3-0.6B (本地模型)...")

        // Qwen3-0.6B-MLX-4bit 以 folder reference（蓝色文件夹）打包为 bundle 内的
        // 独立子目录。必须从该子目录加载：MLXLMCommon 的 loadWeights 会用
        // FileManager.enumerator 递归合并目录下所有 *.safetensors，若从 bundle 根
        // 加载会把 SparkTTSCache 里的 Spark 骨干权重（hidden 896）一并读入并覆盖
        // Qwen3 的同名权重（hidden 1024），导致 mismatchedSize。
        let bundleResourceName = "Qwen3-0.6B-MLX-4bit"
        guard let modelDirectory = Bundle.main.url(
            forResource: bundleResourceName,
            withExtension: nil
        ) else {
            print("未找到内置模型文件夹 \(bundleResourceName)（需以 folder reference 方式加入工程）")
            throw AIError.modelNotLoaded
        }

        let fm = FileManager.default
        for file in ["config.json", "model.safetensors"] {
            guard fm.fileExists(atPath: modelDirectory.appendingPathComponent(file).path) else {
                print("缺少内置 Qwen3 文件: \(file)")
                throw AIError.modelNotLoaded
            }
        }

        model = try await loadModel(
            from: modelDirectory,
            using: #huggingFaceTokenizerLoader()
        )

        guard let model else {
            throw AIError.modelNotLoaded
        }
        session = ChatSession(
            model,
            // 常驻 session 只服务 analyzeChapter 那条旧入口；调度器每批都自带
            // maxTokens 走下面的 batchSession，所以这里给个宽裕的兜底上限就行。
            generateParameters: Self.makeParameters(maxTokens: 1024),
            additionalContext: [
                "enable_thinking": false
            ]
        )

        isLoaded = true

        print("Qwen3-0.6B 加载完成")
    }

    private static func makeParameters(
        maxTokens: Int
    ) -> GenerateParameters {
        GenerateParameters(
            maxTokens: maxTokens,
            temperature: 0.1,
            // 位置式 JSON 每批会合法地重复 "n"/null/0.5 等结构 token 十次；
            // 1.5 的惩罚恰好重罚这些最高频 token，导致列错位、字段缺失。
            // 分析输出是结构化文本，不是散文，无需反重复。
            repetitionPenalty: 1.0,
            repetitionContextSize: 50
        )
    }

    func unload() async {
        // 调度器在分析队列排空时会例行检查卸载，模型从没加载过就别打印「已卸载」。
        guard isLoaded else { return }
        session = nil
        model = nil
        isLoaded = false
        // 只置 nil 不等于把内存还给系统：MLX allocator 会把释放的 buffer 留在
        // cached 池里复用（上限就是 cacheLimit，这里是 2GB），这部分是脏页、
        // 计入进程驻留。所以「已卸载」却一直占着 1.x GB，Kokoro 那条路上
        // 这笔内存一秒钟都不该留着——排空即清。
        let cachedBefore = MLX.Memory.snapshot().cacheMemory
        MLX.Memory.clearCache()
        print("Qwen3-0.6B 已卸载，MLX cached \(cachedBefore / 1_048_576)MB → \(MLX.Memory.snapshot().cacheMemory / 1_048_576)MB")
    }

    // MARK: - Generate

    func generate(
        prompt: String,
        maxTokens: Int
    ) async throws -> String {

        if !isLoaded {
            MemoryProbe.log("LLM 加载 前")
            try await load()
            MemoryProbe.log("LLM 加载 后")
        }

        guard let model else {
            throw AIError.modelNotLoaded
        }

        // 关键修复：每个 prompt 用独立的 ChatSession。
        // 之前常驻 session 会跨批次累积会话历史与 KV，
        // 使整章分析内存从 ~3.5GB 线性涨到 ~11.5GB。
        let batchSession = ChatSession(
            model,
            generateParameters: Self.makeParameters(maxTokens: maxTokens),
            additionalContext: ["enable_thinking": false]
        )

        let response = try await batchSession.respond(to: prompt)

        // 只在缓存真涨上去时回收：MLX allocator 会复用 cached buffer，
        // 每批无脑 clearCache 会让下一批重新分配全部中间张量。
        let cached = MLX.Memory.snapshot().cacheMemory
        if cached > MemoryProbe.clearThresholdBytes {
            MLX.Memory.clearCache()
            print("[Memory] cached \(cached / 1_048_576)MB > \(MemoryProbe.clearThresholdBytes / 1_048_576)MB → clearCache")
        }

        return response
    }

    // MARK: - Analyze Chapter (Batched)

    func analyzeChapter(
        _ chapter: Chapter,
        context: StoryContext?
    ) async throws -> ChapterAnalysis {

        try await load()

        guard let session else {
            throw AIError.modelNotLoaded
        }

        let batchSize = 8
        let allSentences = chapter.sentences
        let batches = stride(from: 0, to: allSentences.count, by: batchSize).map {
            Array(allSentences[$0..<min($0 + batchSize, allSentences.count)])
        }

        var allCharacters: [AnalyzedCharacter] = []
        var allAnalyzedSentences: [AnalyzedSentence] = []

        for (batchIndex, batch) in batches.enumerated() {
            print("[LLM] 批次 \(batchIndex + 1)/\(batches.count)（\(batch.count) 句）")

            let prompt = buildPrompt(
                chapter: chapter,
                sentences: batch,
                context: context
            )

            let response = try await session.respond(to: prompt)

            // 不再整份打印模型输出：解析失败那条路径自己会带原文节选。
            let analysis = parseResponse(response)

            allCharacters.append(contentsOf: analysis.characters)
            allAnalyzedSentences.append(contentsOf: analysis.sentences)
        }

        let uniqueCharacters = allCharacters.reduce(into: [AnalyzedCharacter]()) { result, char in
            if !result.contains(where: { $0.name == char.name }) {
                result.append(char)
            }
        }

        let sortedSentences = allAnalyzedSentences.sorted { $0.index < $1.index }

        return ChapterAnalysis(
            characters: uniqueCharacters,
            sentences: sortedSentences
        )
    }

    // MARK: - Build Prompt

    private func buildPrompt(
        chapter: Chapter,
        sentences: [Sentence],
        context: StoryContext?
    ) -> String {

        let knownCharacters =
            context?.characters
                .map {
                    """
                    {"name": \(jsonString($0.name)), "gender": \(jsonString($0.gender.rawValue)), "age": \(jsonString($0.age.rawValue))}
                    """
                }
                .joined(separator: ", ")
            ?? ""

        let sentenceList =
            sentences
                .map {
                    """
                    {"index": \($0.index), "text": \(jsonString($0.text))}
                    """
                }
                .joined(separator: ",\n")

        return """
        /no_think
        分析小说句子，输出JSON。

        已知人物：[\(knownCharacters)]
        章节：\(chapter.title)

        句子：
        [\(sentenceList)]

        规则：
        - type: narration或dialogue
        - speaker: 旁白用null，对白填人物名
        - emotion: neutral/happy/sad/angry/surprised/fearful/excited/calm/tense
        - intensity: 0.0~1.0
        - speed: 0.7~1.3
        - pitch: -0.2~0.2

        只输出纯JSON。不要Markdown。不要注释。不要解释。不要//。

        格式：
        {"characters":[{"name":"韩立","gender":"male","age":"young","description":"人物描述"}],"sentences":[{"index":0,"type":"narration","speaker":null,"emotion":"calm","intensity":0.2,"speed":0.95,"pitch":0.0}]}
        """
    }

    // MARK: - Parse Response

    private func parseResponse(
        _ response: String
    ) -> ChapterAnalysis {

        var text = response.trimmingCharacters(in: .whitespacesAndNewlines)

        if text.hasPrefix("```json") {
            text = text.replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else if text.hasPrefix("```") {
            text = text.replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        text = stripJSONComments(text)

        if let data = text.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return parseAnalysisDict(dict)
        }

        if let data = text.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return parseAnalysisDict(["characters": [], "sentences": arr])
        }

        if let repaired = repairTruncatedJSON(text),
           let data = repaired.data(using: .utf8) {
            if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return parseAnalysisDict(dict)
            }
            if let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                return parseAnalysisDict(["characters": [], "sentences": arr])
            }
        }

        print("JSON 解析失败，使用默认值")
        print("原始响应: \(text.prefix(500))")

        return ChapterAnalysis(characters: [], sentences: [])
    }

    // MARK: - Strip JSON Comments

    private func stripJSONComments(_ text: String) -> String {
        var result = ""
        var inString = false
        let chars = Array(text)
        var i = 0

        while i < chars.count {
            let c = chars[i]

            if c == "\\" && inString {
                result.append(c)
                if i + 1 < chars.count {
                    i += 1
                    result.append(chars[i])
                }
                i += 1
                continue
            }

            if c == "\"" {
                inString = !inString
                result.append(c)
                i += 1
                continue
            }

            if !inString && c == "/" && i + 1 < chars.count && chars[i + 1] == "/" {
                while i < chars.count && chars[i] != "\n" {
                    i += 1
                }
                continue
            }

            result.append(c)
            i += 1
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - JSON Repair

    private func repairTruncatedJSON(_ text: String) -> String? {
        let chars = Array(text)

        guard let firstBrace = chars.firstIndex(of: "{") else { return nil }

        let firstBracket = chars.firstIndex(of: "[").flatMap { $0 < firstBrace ? $0 : nil }
        let isBareArray = firstBracket != nil

        var i = firstBracket ?? firstBrace
        var inString = false
        var lastCompleteObjEnd: Int? = nil
        var depth = 0
        let sentenceObjDepth = isBareArray ? 2 : 3

        while i < chars.count {
            let c = chars[i]

            if c == "\\" && inString {
                i += 2
                continue
            }

            if c == "\"" {
                inString = !inString
                i += 1
                continue
            }

            if inString {
                i += 1
                continue
            }

            if c == "{" || c == "[" {
                depth += 1
                if c == "{" && depth == sentenceObjDepth {
                    lastCompleteObjEnd = nil
                }
            } else if c == "}" || c == "]" {
                if c == "}" && depth == sentenceObjDepth {
                    lastCompleteObjEnd = i
                }
                depth -= 1
                if depth == 0 {
                    return String(chars[0...i])
                }
            }

            i += 1
        }

        if let end = lastCompleteObjEnd {
            let suffix = isBareArray ? "]" : "]}"
            let truncated = String(chars[0...end]) + suffix
            if let data = truncated.data(using: .utf8),
               let _ = try? JSONSerialization.jsonObject(with: data) {
                return truncated
            }
        }

        return nil
    }

    // MARK: - Dict-based Parser

    private func parseAnalysisDict(_ dict: [String: Any]) -> ChapterAnalysis {
        var characters: [AnalyzedCharacter] = []
        var sentences: [AnalyzedSentence] = []

        if let chars = dict["characters"] as? [[String: Any]] {
            for c in chars {
                guard let name = c["name"] as? String, !name.isEmpty else { continue }
                let gender = (c["gender"] as? String).flatMap { Gender(rawValue: $0) } ?? .unknown
                let age = (c["age"] as? String).flatMap { AgeType(rawValue: $0) } ?? .unknown
                let desc = c["description"] as? String
                characters.append(AnalyzedCharacter(name: name, gender: gender, age: age, description: desc))
            }
        }

        if let sents = dict["sentences"] as? [[String: Any]] {
            for s in sents {
                guard let index = s["index"] as? Int else { continue }

                let typeStr = (s["type"] as? String) ?? "narration"
                let sentenceType: SentenceType = typeStr == "dialogue" ? .dialogue : .narration

                var speaker: String? = nil
                if let sp = s["speaker"] as? String {
                    speaker = (sp == "无" || sp.isEmpty || sp == "null") ? nil : sp
                }

                if speaker == nil, let cn = s["characterName"] as? String {
                    speaker = (cn == "无" || cn.isEmpty || cn == "null") ? nil : cn
                }

                let emotionStr = (s["emotion"] as? String) ?? "neutral"
                let emotion = Emotion(rawValue: emotionStr) ?? .neutral

                let intensity = extractDouble(from: s, keys: ["intensity", "emotionIntensity", "emotionsIntensity"], fallback: 0.5)
                let speed = max(0.7, min(1.3, extractDouble(from: s, keys: ["speed"], fallback: 1.0)))
                let pitch = max(-0.2, min(0.2, extractDouble(from: s, keys: ["pitch"], fallback: 0.0)))

                sentences.append(AnalyzedSentence(
                    index: index,
                    type: sentenceType,
                    speaker: speaker,
                    emotion: emotion,
                    intensity: intensity,
                    speed: speed,
                    pitch: pitch
                ))
            }
        }

        return ChapterAnalysis(characters: characters, sentences: sentences)
    }

    private func extractDouble(from dict: [String: Any], keys: [String], fallback: Double) -> Double {
        for key in keys {
            if let v = dict[key] as? Double {
                return v
            }
            if let v = dict[key] as? Int {
                return Double(v)
            }
            if let v = dict[key] as? String, let d = Double(v) {
                return d
            }
        }
        return fallback
    }

    private func jsonString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")

        return "\"\(escaped)\""
    }
}

// MARK: - Memory Probe

/// 基于 MLX 分配器的内存探针，用于验证分析/TTS 各阶段内存是否稳定（需求 13）。
enum MemoryProbe {

    /// MLX 的 cacheLimit 默认等于 memoryLimit（≈1.5×recommendedMaxWorkingSetSize），
    /// 8GB 机器上会把 4~6GB 留在 allocator 里，逼近 jetsam 红线。
    static let cacheLimitBytes = 2 * 1024 * 1024 * 1024

    /// 缓存超过这个量才回收；以下都靠 allocator 复用已有 buffer。
    static let clearThresholdBytes = 1_536 * 1024 * 1024

    static func configureCacheLimit() {
        let current = MLX.Memory.cacheLimit
        guard current > cacheLimitBytes else {
            print("[Memory] cacheLimit 保持 \(current / 1_048_576)MB（已不高于目标）")
            return
        }
        MLX.Memory.cacheLimit = cacheLimitBytes
        print("[Memory] cacheLimit \(current / 1_048_576)MB → \(cacheLimitBytes / 1_048_576)MB")
    }

    static func snapshot() -> (active: Int, cached: Int, peak: Int) {
        let s = MLX.Memory.snapshot()
        return (s.activeMemory, s.cacheMemory, s.peakMemory)
    }

    static func log(_ label: String) {

        let s = snapshot()

        func mb(_ value: Int) -> Int { value / 1_048_576 }

        print(
            "[Memory] \(label) | active \(mb(s.active))MB  cached \(mb(s.cached))MB  peak \(mb(s.peak))MB"
        )
    }
}
