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

    每句话必须输出一个数组，并且每个数组必须恰好包含 8 个元素：

    [index,"n"或"d",speaker,emotion,emotionIntensity,speed,pitch,voiceStrength]

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

    无法确定 speaker 时，不要改变 n/d 的判断。

    ==================================================
    【3. speaker】
    ==================================================

    第三列表示说话人姓名。

    只能使用「当前这一句本身」出现的信息来判断，例如：

    - “张三说：……”
    - “李四问道：……”
    - “王五喊道：……”
    - “张三：“你来了？””
    - “‘快走！’张三大喊。”

    符合以上任一形式时，填写该人物姓名。

    以下情况一律使用 null：

    - 当前句没有出现能确定说话人的文字
    - 需要对上下文做出推断才能确定说话人

    严禁使用以下任何线索来推断 speaker：

    - 上一句或下一句
    - 对话的交替规律、说话人轮换
    - 人物关系、人物性格
    - 故事情节、前后因果

    不要猜测 speaker，宁可输出 null。

    如果第二列为 "n"，第三列必须为 null。

    例如：

    [1,"d","张三","angry",0.8,1.08,0.03,0.95]

    或者：

    [1,"d",null,"neutral",0.5,1.0,0.0,0.8]

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
    【5. emotionIntensity 与 8. voiceStrength 的区别】
    ==================================================

    这是两个互相独立的维度，绝不要用其中一个去推另一个：

    emotionIntensity：情绪有多强。范围 0.0 ~ 1.0
    - 0.0 ~ 0.2：几乎没有情绪
    - 0.3 ~ 0.4：轻微
    - 0.5 ~ 0.6：中等
    - 0.7 ~ 0.8：明显
    - 0.9 ~ 1.0：非常强烈

    voiceStrength：声音本身有多饱满、有支撑力、有力量。范围 0.0 ~ 1.0
    - 0.75 ~ 0.85：正常朗读的饱满程度（默认区间）
    - 0.9 ~ 1.0：愤怒、兴奋等有力度的表达
    - 0.6 ~ 0.75：只有文本明确要求轻声、耳语时才用

    情绪弱不等于声音虚。悲伤、平静、克制都只是语气不同，
    声音依然必须中气充足、有支撑。

    例如一句很悲伤的话可以是：

    emotion = sad, emotionIntensity = 0.8, voiceStrength = 0.85

    绝对不要输出：

    emotion = sad, emotionIntensity = 0.8, voiceStrength = 0.2

    按情绪推荐的 voiceStrength（可在此上下小幅调整，不要低于 0.6）：

    neutral: 0.80
    calm: 0.80
    sad: 0.80
    fearful: 0.75
    happy: 0.85
    tense: 0.85
    surprised: 0.90
    excited: 0.90
    angry: 0.95

    两个字段都必须是 JSON number，不能加引号。

    ==================================================
    【6. speed】
    ==================================================

    speed 是「整句话」的目标语速，范围 0.7 ~ 1.3，必须是 JSON number。

    - 0.7 ~ 0.85：非常慢
    - 0.86 ~ 0.95：偏慢
    - 0.96 ~ 1.05：正常
    - 1.06 ~ 1.15：偏快
    - 1.16 ~ 1.3：非常快

    按情绪推荐：

    neutral: 1.00
    calm: 0.90 ~ 0.95
    sad: 0.88 ~ 0.95
    fearful: 0.95 ~ 1.05
    happy: 1.03 ~ 1.10
    angry: 1.03 ~ 1.12
    surprised: 1.03 ~ 1.12
    tense: 1.03 ~ 1.10
    excited: 1.08 ~ 1.18

    speed 描述的是整句的均匀语速，不存在「前半句快后半句慢」。

    ==================================================
    【7. pitch】
    ==================================================

    pitch 是「整句话」的目标音调偏移，范围 -0.2 ~ 0.2，必须是 JSON number。

    - -0.2 ~ -0.1：明显低沉
    - -0.1 ~ -0.03：略低
    - -0.03 ~ 0.03：正常
    - 0.03 ~ 0.1：略高
    - 0.1 ~ 0.2：明显偏高

    按情绪推荐（不要给极端值）：

    neutral: 0.00
    calm: -0.03
    sad: -0.05 ~ -0.10
    angry: 0.00 ~ +0.05
    tense: 0.00 ~ +0.05
    fearful: -0.02 ~ +0.05
    happy: +0.05 ~ +0.10
    surprised: +0.08 ~ +0.15
    excited: +0.08 ~ +0.15

    pitch 低只代表音调低，不代表音量小。

    ==================================================
    【语音表现要求：这一条最重要】
    ==================================================

    你要输出的这些参数会被合成成真人朗读。历史音频最常见的缺陷是：

    前半句正常饱满，后半句越来越轻、越来越慢、越来越虚，
    最后几个字几乎听不清（句尾泄气、中途压低声音）。

    为避免这种情况，参数必须体现「整句一致」：

    1. 从句首到句尾保持基本稳定的音量、气息、声音力度、语速、音调。
    2. 中气充足、声音饱满、有支撑力。
    3. 不允许中途突然降低音量、压低声音、放慢语速、改变音调或改变说话方式。
    4. 不允许句尾泄气、突然变轻、突然变慢、音量骤降、声音发虚。
    5. sad / calm / tense / fearful 等情绪不得通过降低 voiceStrength 来表达。
    6. 情绪可以自然表达，但整句的情绪强度必须连贯，变化平滑。
    7. speed、pitch、voiceStrength 都是整句目标值，不是局部值。

    换句话说：宁可情绪略克制，也不要靠「越读越轻」来表现情绪。

    ==================================================
    【默认值】
    ==================================================

    如果无法可靠判断情绪：

    "neutral",0.5

    如果无法可靠判断语速：1.0

    如果无法可靠判断音调：0.0

    如果无法可靠判断声音力度：0.8

    如果是对白但无法确定说话人："d",null

    如果是旁白："n",null

    例如：

    [5,"n",null,"neutral",0.5,1.0,0.0,0.8]

    或者：

    [6,"d",null,"neutral",0.5,1.0,0.0,0.8]

    ==================================================
    【重要原则】
    ==================================================

    1. 每句话都必须返回完整的 8 个字段，顺序不能变。

    2. 不要遗漏 speaker、emotion、emotionIntensity、speed、pitch、voiceStrength。

    3. speaker 只用当前句自身的线索，不确定时用 null，绝不编造人物。

    4. emotion、speed、pitch、voiceStrength 即使无法精确判断，也必须给出合法默认值。

    5. 六个数值字段必须是 JSON number，不要加引号、不要合并成字符串。

    错误：

    [1,"d","张三","happy","0.8,1.1,0.1,0.85"]

    正确：

    [1,"d","张三","happy",0.8,1.1,0.1,0.85]

    6. 必须是合法 JSON：不允许 Markdown、```json、解释文字。

    7. 必须恰好输出 \(count) 条，index 按输入顺序。

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
                // 对白没写出说话人：仍然是对白（不能因为不知道是谁就改读成旁白），
                // 交给无角色的固定男声朗读。旁白是旁白、无名说话人是另一种声音，
                // 两条路径（正则/LLM）必须落到同一个声音上。
                speaker = .character
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
            fallback: emotion.defaultSpeed, min: 0.7, max: 1.3, name: "speed", issues: &issues
        )
        let pitch = validatedDouble(
            dict, keys: ["pitch"],
            fallback: emotion.defaultPitch, min: -0.2, max: 0.2, name: "pitch", issues: &issues
        )

        // voiceStrength 与 emotionIntensity 独立：模型常把「悲伤/紧张」顺手写成
        // 0.2 这类气声值，听感就是后半句越读越轻、句尾泄气。低于地板时按该情绪的
        // 推荐值抬回来，绝不把虚弱的力度原样送进 TTS。
        var voiceStrength = validatedDouble(
            dict, keys: ["voiceStrength", "strength", "voicePower"],
            fallback: emotion.defaultVoiceStrength, min: 0, max: 1, name: "voiceStrength", issues: &issues
        )
        if voiceStrength < Self.voiceStrengthFloor {
            let lifted = max(Self.voiceStrengthFloor, emotion.defaultVoiceStrength)
            issues.append("voiceStrength 过低(\(voiceStrength))→\(lifted)，情绪弱不等于声音虚")
            voiceStrength = lifted
        }

        return (
            AIAnalyzedSentence(
                index: index,
                type: type,
                speaker: speaker,
                characterName: characterName,
                emotion: emotion,
                emotionIntensity: emotionIntensity,
                speed: speed,
                pitch: pitch,
                voiceStrength: voiceStrength
            ),
            issues
        )
    }

    /// 送进 TTS 的最低声音力度。低于此值基本就是气声/句尾泄气。
    static let voiceStrengthFloor: Double = 0.6

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

    /// [index,type,characterName,emotion,emotionIntensity,speed,pitch,voiceStrength]
    /// → 命名字段 dict。
    /// 模型常把末尾数值塞进一个带引号的串（"0.5,1.0,0.0,0.8"）：先展平回独立
    /// 数字列，保证 8 列对齐。元素不足时对应字段缺失，由 makeSentence 记问题。
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
            "emotion", "emotionIntensity", "speed", "pitch", "voiceStrength",
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
            for suffix in ["]", ",0.8]"] {
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
