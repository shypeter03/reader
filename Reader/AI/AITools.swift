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

        let sentenceList = chapter.sentences
            .map {
                "\($0.index): \($0.text.replacingOccurrences(of: "\n", with: " "))"
            }
            .joined(separator: "\n")

        let indices = chapter.sentences.map(\.index)
        let indexList = indices.map(String.init).joined(separator: ",")
        let count = indices.count

        return """
    /no_think

    你是一个小说文本分析器，负责为 TTS 生成语音控制信息。

    请逐句分析输入的 \(count) 个句子。

    只输出 JSON 数组，不要输出解释、Markdown、代码块或其他文字。

    每句话必须输出一个数组，并且每个数组必须恰好包含 7 个元素：

    [index,"n"或"d",speaker,emotion,emotionIntensity,speed,pitch]

    ==================================================
    【1. index】
    ==================================================

    必须严格使用输入句子的 index。

    输出顺序必须与输入完全一致。

    必须输出 \(count) 行。

    index 必须严格为：

    [\(indexList)]

    不得修改、遗漏、重复或重新排序。

    ==================================================
    【2. n / d】
    ==================================================

    第二列表示句子的类型：

    "n" = narration，旁白

    "d" = dialogue，人物对白

    如果句子主要是在描述：

    - 场景
    - 环境
    - 人物动作
    - 人物心理
    - 事件
    - 故事情节

    使用：

    "n"

    如果句子是人物正在说的话，使用：

    "d"

    即使无法确定具体是谁说的，只要能够判断这是人物对白，也应该使用：

    "d"

    ==================================================
    【3. speaker】
    ==================================================

    第三列表示说话人。

    目标是尽可能识别说话人。

    可以根据当前句子中出现的信息判断，例如：

    - “张三说：……”
    - “李四问道：……”
    - “王五喊道：……”
    - “张三：“你来了？””
    - “‘快走！’张三大喊。”
    - 当前句明确指出某个人正在说话

    如果当前句能够明确确定说话人：

    填写人物姓名。

    人物姓名可以来自当前句子。

    不要因为没有人物列表就放弃识别。

    如果当前句是对白，但无法可靠确定说话人：

    第三列使用 null。

    不要猜测一个不确定的人物。

    注意：

    如果第二列为 "n"，第三列必须为 null。

    如果第二列为 "d"，第三列可以是人物姓名，也可以是 null。

    例如：

    [1,"d","张三","angry",0.8,1.1,0.1]

    或者：

    [1,"d",null,"neutral",0.5,1.0,0.0]

    ==================================================
    【4. emotion】
    ==================================================

    分析当前句子的情绪。

    只能使用以下值：

    neutral
    happy
    sad
    angry
    surprised
    fearful
    excited
    calm
    tense

    不要输出其他情绪名称。

    ==================================================
    【5. emotionIntensity】
    ==================================================

    表示情绪强度。

    范围：

    0.0 ~ 1.0

    必须是 JSON number，不能加引号。

    参考：

    0.0 ~ 0.2：几乎没有情绪
    0.3 ~ 0.4：轻微
    0.5 ~ 0.6：中等
    0.7 ~ 0.8：明显
    0.9 ~ 1.0：非常强烈

    ==================================================
    【6. speed】
    ==================================================

    表示 TTS 语速。

    范围：

    0.7 ~ 1.3

    必须是 JSON number。

    参考：

    0.7 ~ 0.85：非常慢
    0.86 ~ 0.95：偏慢
    0.96 ~ 1.05：正常
    1.06 ~ 1.15：偏快
    1.16 ~ 1.3：非常快

    根据句子的表达方式和情绪判断。

    ==================================================
    【7. pitch】
    ==================================================

    表示 TTS 音调。

    范围：

    -0.2 ~ 0.2

    必须是 JSON number。

    参考：

    -0.2 ~ -0.1：明显低沉
    -0.1 ~ -0.03：略低
    -0.03 ~ 0.03：正常
    0.03 ~ 0.1：略高
    0.1 ~ 0.2：明显偏高

    根据句子的情绪和表达方式判断。

    ==================================================
    【默认值】
    ==================================================

    如果无法可靠判断情绪：

    "neutral",0.5

    如果无法可靠判断语速：

    1.0

    如果无法可靠判断音调：

    0.0

    如果是对白但无法确定说话人：

    "d",null

    如果是旁白：

    "n",null

    例如：

    [5,"n",null,"neutral",0.5,1.0,0.0]

    或者：

    [6,"d",null,"neutral",0.5,1.0,0.0]

    ==================================================
    【重要原则】
    ==================================================

    1. 每句话都必须返回完整的 7 个字段。

    2. 不要遗漏 speaker、emotion、emotionIntensity、speed、pitch。

    3. speaker 尽可能识别，但不确定时使用 null。

    4. 不要为了确定 speaker 而编造人物。

    5. emotion、speed、pitch 即使无法精确判断，也必须给出合法默认值。

    6. 不要把数字合并成字符串。

    错误：

    [1,"d","张三","happy","0.8,1.1,0.1"]

    正确：

    [1,"d","张三","happy",0.8,1.1,0.1]

    7. 最终必须输出完整 JSON。

    ==================================================
    【输入】
    ==================================================

    \(sentenceList)

    ==================================================
    现在直接输出 JSON 数组。
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
