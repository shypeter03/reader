//
//  AITools.swift
//  Reader
//
//  Created by 粟海洋 on 2026/8/27.
//

import Foundation

enum AITools {

    // MARK: - Build Prompt
    static func buildPrompt(
        chapter: Chapter,
        context: StoryContext
    ) -> String {

        let characterList = context.characters
            .map { $0.name }
            .joined(separator: ",")

        let sentenceList = chapter.sentences
            .map { "\($0.index): \($0.text.replacingOccurrences(of: "\n", with: " "))" }
            .joined(separator: "\n")

        let indices = chapter.sentences.map(\.index)
        let indexList = indices.map(String.init).joined(separator: ",")
        let count = indices.count

        return """
/no_think
你是严格 JSON 生成器。只输出一个可由 JSON.parse 解析的 JSON 数组；不要解释、不要 Markdown、不要代码围栏、不要省略任何一行。

任务：按输入顺序分析 \(count) 句。必须且只能输出 \(count) 个内层数组；第一列必须依次严格等于 [\(indexList)]。

唯一允许的每行格式（恰好 7 个元素）：
[index,"n"或"d",characterName或null,emotion,emotionIntensity,speed,pitch]

字段规则：
- "n" 是旁白，第三列必须为 null。
- "d" 是对白，第三列人名必须逐字出现在输入句子或已知人物里；找不到说话人时改标 "n"（第三列 null）。
- 示例里的"张三"只是格式占位，禁止出现在输出中；不得为句子编造人物。
- emotion 只能是 neutral/happy/sad/angry/surprised/fearful/excited/calm/tense。
- emotionIntensity 必须是 0.0 到 1.0 的数字；speed 必须是 0.7 到 1.3 的数字；pitch 必须是 -0.2 到 0.2 的数字。
- 三个数值必须是裸数字、各占一列、不加引号；禁止写成 "0.5,1.0,0.0" 这种合并字符串。
- 不确定时输出合法保守值 [index,"n",null,"neutral",0.5,1.0,0.0]。合法完整输出优先于猜测，不得留空、截断或输出占位符。

已知人物：\(characterList.isEmpty ? "无" : characterList)
输入句子（编号不可改）：
\(sentenceList)

输出示例（仅示意格式，不要重复示例）：
[[0,"n",null,"calm",0.3,1.0,0.0],[1,"d","张三","excited",0.8,1.15,-0.05]]
"""
    }

    // MARK: - Parse Response (tolerant extraction, STRICT schema validation)

    /// 容错地把模型文本抽成逐句 dict，再对每个对象做严格 schema 校验。
    /// 返回的 issues 非空即代表模型输出不满足 schema（缺字段/非法值/越界），
    /// 调用方应据此重试生成；issues 里给出的句子参数已被修正到合法值，
    /// 保证送进 TTS 的每条句子参数合规。回退只改变朗读风格、不会丢句
    /// （句子正文来自 EPUB 而非模型），也就不会让播放器卡在永久静音上。
    static func parseResponse(
        _ response: String,
        expectedIndices: [Int]
    ) -> (result: AIAnalysisResult, issues: [String]) {

        let cleaned = stripComments(stripMarkdown(response))

        let dicts = extractSentenceDicts(cleaned)
        let byIndex = Dictionary(
            dicts.compactMap { dict -> (Int, [String: Any])? in
                guard let index = integer(dict["index"]) else { return nil }
                return (index, dict)
            },
            uniquingKeysWith: { first, _ in first }
        )

        var sentences: [AIAnalyzedSentence] = []
        var allIssues: [String] = []

        for (position, idx) in expectedIndices.enumerated() {
            // Index is the contract. Position is only a narrow fallback for
            // legacy object responses that omitted their index entirely.
            let dict = byIndex[idx] ?? (position < dicts.count && integer(dicts[position]["index"]) == nil ? dicts[position] : [:])
            let (sentence, issues) = makeSentence(dict: dict, expectedIndex: idx)
            if !issues.isEmpty {
                allIssues.append(contentsOf: issues.map { "句\(idx): \($0)" })
            }
            sentences.append(sentence)
        }

        if !allIssues.isEmpty {
            let sample = allIssues.prefix(4).joined(separator: "；")
            print("批次校验: \(expectedIndices.count) 句中输出不完全合规，共 \(allIssues.count) 处问题。示例: \(sample)")
        }

        return (AIAnalysisResult(sentences: sentences), allIssues)
    }

    // MARK: - Build One Sentence + Strict Schema Validation

    /// 返回「一定合规」的句子标注 + 本次所做的修正项。
    /// issues 非空即代表模型原始输出不满足 schema，被强制修正/回退。
    private static func makeSentence(
        dict: [String: Any],
        expectedIndex: Int
    ) -> (AIAnalyzedSentence, [String]) {

        var issues: [String] = []

        let index = (dict["index"] as? Int) ?? expectedIndex

        // MARK: type（严格枚举，缺失/非法 → narration）

        let rawType = normalizedString(dict["type"])
        var type: SentenceType
        if rawType == "dialogue" || rawType == "d" {
            type = .dialogue
        } else if rawType == "narration" || rawType == "n" {
            type = .narration
        } else if rawType == nil {
            type = .narration
            issues.append("缺 type→narration")
        } else {
            type = .narration
            issues.append("type 非法(\(rawType ?? ""))→narration")
        }

        // MARK: speaker ↔ type ↔ characterName 一致性（硬约束）

        let rawSpeaker = normalizedString(dict["speaker"])
        let rawName = nonEmptyString(dict["characterName"])

        var speaker: SpeakerType
        var characterName: String?

        switch type {
        case .narration:
            speaker = .narrator
            if rawSpeaker == "character" {
                issues.append("旁白却标 character→narrator")
            }
            if rawName != nil {
                issues.append("旁白携带人物名→置空")
            }
            characterName = nil

        case .dialogue:
            if let name = rawName {
                speaker = .character
                characterName = name
                if rawSpeaker == "narrator" {
                    issues.append("对白却标 narrator→character")
                }
            } else {
                // 对白缺少人物名：无法定位说话人，整体回退为旁白朗读。
                issues.append("对白缺 characterName→回退旁白")
                type = .narration
                speaker = .narrator
                characterName = nil
            }
        }

        // MARK: emotion（严格枚举，缺失/非法都记问题→neutral）

        let emotionToken = normalizedString(dict["emotion"])
        let emotion: Emotion
        if emotionToken == nil {
            emotion = .neutral
            issues.append("emotion 缺失→neutral")
        } else if let e = emotionToken.flatMap({ Emotion(rawValue: $0) }) {
            emotion = e
        } else {
            emotion = .neutral
            issues.append("emotion 非法(\(emotionToken ?? ""))→neutral")
        }

        // MARK: 数值区间（越界裁剪并记问题；缺失/非数用默认并记问题）

        let emotionIntensity = validatedDouble(
            dict, keys: ["emotionIntensity", "effectIntensity", "intensity", "emotionIntensityValue"],
            fallback: 0.5, min: 0, max: 1, name: "emotionIntensity", issues: &issues
        )
        let speed = validatedDouble(
            dict, keys: ["speed"],
            fallback: 1.0, min: 0.7, max: 1.3, name: "speed", issues: &issues
        )
        let pitch = validatedDouble(
            dict, keys: ["pitch"],
            fallback: 0.0, min: -0.2, max: 0.2, name: "pitch", issues: &issues
        )

        return (
            AIAnalyzedSentence(
                index: index,
                type: type,
                speaker: speaker,
                characterName: characterName,
                emotion: emotion,
                emotionIntensity: emotionIntensity,
                speed: speed,
                pitch: pitch
            ),
            issues
        )
    }

    // MARK: - Validation Helpers

    /// 归一化字符串字段：去空白、转小写；空串 / "null" / "无" / NSNull 视为 nil。
    private static func normalizedString(_ value: Any?) -> String? {
        nonEmptyString(value)?.lowercased()
    }

    /// Names are data, not enum tokens: preserve their original capitalization.
    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let s = value as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || t.lowercased() == "null" || t == "无" { return nil }
        return t
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? Double, value.rounded() == value { return Int(value) }
        if let value = value as? String { return Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    /// 取出并校验数值字段：任一 key 命中且可转数字则采用；缺失/非数记问题并用默认；
    /// 越界则裁剪回区间并记问题（不原样透传给 TTS）。
    private static func validatedDouble(
        _ dict: [String: Any],
        keys: [String],
        fallback: Double,
        min lo: Double,
        max hi: Double,
        name: String,
        issues: inout [String]
    ) -> Double {

        var raw: Double?
        for key in keys {
            guard let v = dict[key] else { continue }
            if let d = v as? Double { raw = d; break }
            if let i = v as? Int { raw = Double(i); break }
            if let s = v as? String, let d = Double(s.trimmingCharacters(in: .whitespaces)) {
                raw = d; break
            }
        }

        guard let value = raw else {
            issues.append("\(name) 缺失/非数→\(fallback)")
            return fallback
        }

        if value < lo || value > hi {
            let clamped = clamp(value, min: lo, max: hi)
            issues.append("\(name) 越界(\(value))→\(clamped)")
            return clamped
        }

        return value
    }

    // MARK: - Extract Sentence Dicts

    private static func extractSentenceDicts(_ text: String) -> [[String: Any]] {
        // 先尝试整体解析
        if let data = text.data(using: .utf8),
           let any = try? JSONSerialization.jsonObject(with: data),
           let parsed = normalizeTopLevel(any) {
            return parsed
        }

        // 再试截取首个 [ 到末尾 ] 的片段（模型常带前后杂文本）
        if let start = text.firstIndex(of: "["),
           let end = text.lastIndex(of: "]"), start <= end,
           let data = String(text[start...end]).data(using: .utf8),
           let any = try? JSONSerialization.jsonObject(with: data),
           let parsed = normalizeTopLevel(any) {
            return parsed
        }

        // 位置式格式下模型常在尾部截断（缺 ]），上面两步都会整体失败；
        // 逐个 salvage 平衡的内层 [...] 行，保住已完整的前几句。
        // 先记录原始输出节选：真机日志可直接区分「外层没闭合」还是「内容漂移」。
        logRawExcerpt(text)
        let rows = extractArrayRows(text)
        if !rows.isEmpty {
            print("⚠️ JSON 整体解析失败，按行抢救出 \(rows.count) 条位置式结果")
            return rows
        }

        // 容错：扫描所有平衡的 {...} 对象
        return extractObjects(text)
    }

    /// 顶层结果归一化：位置数组（新格式）→ 逐句 dict；对象数组（旧格式）原样通过。
    private static func normalizeTopLevel(_ any: Any) -> [[String: Any]]? {
        if let dict = any as? [String: Any] {
            if let arr = dict["sentences"] as? [[String: Any]] { return arr }
            if let arr = dict["sentences"] as? [[Any]] {
                return arr.compactMap { positionalDict(from: $0) }
            }
            return [dict]
        }
        if let arr = any as? [[String: Any]] { return arr }
        if let arr = any as? [[Any]] {
            return arr.isEmpty ? nil : arr.compactMap { positionalDict(from: $0) }
        }
        return nil
    }

    /// [index,type,characterName,emotion,emotionIntensity,speed,pitch] → 命名字段 dict。
    /// 模型常把末尾数值塞进一个带引号的串（"0.5,1.0,0.0"）：先展平回独立
    /// 数字列，保证 7 列对齐。元素不足时对应字段缺失，由 makeSentence 记问题。
    private static func positionalDict(from arr: [Any]) -> [String: Any]? {
        var flat: [Any] = []
        for element in arr {
            if let s = element as? String, s.contains(","),
               s.split(separator: ",").count >= 2,
               s.split(separator: ",").allSatisfy({ Double($0.trimmingCharacters(in: .whitespaces)) != nil }) {
                flat.append(contentsOf: s.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) })
            } else {
                flat.append(element)
            }
        }
        let keys = [
            "index", "type", "characterName",
            "emotion", "emotionIntensity", "speed", "pitch",
        ]
        var dict = [String: Any]()
        for (i, key) in keys.enumerated() where i < flat.count {
            dict[key] = flat[i]
        }
        return dict.isEmpty ? nil : dict
    }

    /// 整体解析失败时打印原始输出节选（换行折叠），用于真机定位漂移形态。
    private static func logRawExcerpt(_ text: String) {
        let flat = text.replacingOccurrences(of: "\n", with: "⏎")
        if flat.count <= 360 {
            print("[RawOut] \(flat)")
        } else {
            print("[RawOut] 头:\(flat.prefix(180)) …… 尾:\(flat.suffix(180))")
        }
    }

    /// 从可能已截断的外层数组里逐个提取「平衡」的内层 [...] 行并转成 dict。
    /// 位置式格式下模型常输出 `[[..],[..],...` 后断掉：外层不完整没关系，
    /// 已经完整的前几句仍可用，避免整批回退默认值。
    private static func extractArrayRows(_ text: String) -> [[String: Any]] {
        guard let open = text.firstIndex(of: "[") else { return [] }

        let chars = Array(text[open...])
        var rows: [[String: Any]] = []
        var depth = 0
        var inString = false
        var rowStart: Int? = nil
        var i = 0

        while i < chars.count {
            let c = chars[i]

            if inString {
                if c == "\\" { i += 2; continue }
                if c == "\"" { inString = false }
                i += 1
                continue
            }

            switch c {
            case "\"":
                inString = true
            case "[":
                depth += 1
                if depth == 2 { rowStart = i }
            case "]":
                depth -= 1
                if depth == 1, let s = rowStart {
                    let sub = String(chars[s...i])
                    if let data = sub.data(using: .utf8),
                       let arr = try? JSONSerialization.jsonObject(with: data) as? [Any],
                       let dict = positionalDict(from: arr) {
                        rows.append(dict)
                    }
                    rowStart = nil
                }
            default:
                break
            }

            i += 1
        }

        // 最后一行常被提前 EOS 截断在闭合前：若还剩未闭合的行，补一个 "]" 再试一次；
        // 若断在字符串中间，JSON 仍不完整会自然失败、放弃该行。
        if let s = rowStart, s < chars.count {
            let fragment = String(chars[s...])
            for suffix in ["]", ",0]"] {
                if let data = (fragment + suffix).data(using: .utf8),
                   let arr = try? JSONSerialization.jsonObject(with: data) as? [Any],
                   let dict = positionalDict(from: arr) {
                    rows.append(dict)
                    break
                }
            }
        }

        return rows
    }

    private static func extractObjects(_ text: String) -> [[String: Any]] {
        let chars = Array(text)
        var objects: [[String: Any]] = []
        var i = 0

        while i < chars.count {
            guard chars[i] == "{" else {
                i += 1
                continue
            }

            var depth = 0
            var inString = false
            var j = i
            var end: Int? = nil

            while j < chars.count {
                let c = chars[j]

                if c == "\\" && inString {
                    j += 2
                    continue
                }
                if c == "\"" {
                    inString = !inString
                } else if !inString {
                    if c == "{" {
                        depth += 1
                    } else if c == "}" {
                        depth -= 1
                        if depth == 0 {
                            end = j
                            break
                        }
                    }
                }
                j += 1
            }

            if let end {
                let sub = String(chars[i...end])
                if let data = sub.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let arr = obj["sentences"] as? [[String: Any]] {
                        objects.append(contentsOf: arr)
                    } else {
                        objects.append(obj)
                    }
                }
                i = end + 1
            } else {
                // 不完整对象，丢弃剩余
                break
            }
        }

        return objects
    }

    // MARK: - Strip Markdown / Comments

    private static func stripMarkdown(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```json") {
            t = String(t.dropFirst("```json".count))
        } else if t.hasPrefix("```") {
            t = String(t.dropFirst("```".count))
        }
        t = t.replacingOccurrences(of: "```", with: "")
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripComments(_ text: String) -> String {
        let chars = Array(text)
        var result = ""
        var inString = false
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

        return result
    }

    // MARK: - Helpers

    private static func clamp(_ value: Double, min lo: Double, max hi: Double) -> Double {
        Swift.max(lo, Swift.min(hi, value))
    }

}
