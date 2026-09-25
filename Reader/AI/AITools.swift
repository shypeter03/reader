//
//  AITools.swift
//  Reader
//
//  Created by 粟海洋 on 2026/8/27.
//

import Foundation

enum AITools {

    // MARK: - Build Prompt

    /// 给 0.6B 小模型下的指令：只问「情绪 + 情绪强度」两件它比正则强的事。
    ///
    /// 一路减法的理由是真机日志里的失败形状：
    /// 1. 旧版 8 列 JSON、指令 3000 字：prefill 大、多约束下漏列串列。→ 压到 6 列。
    /// 2. 6 列仍不稳：`[11,"d","灵",neutral,0.5,0.8]`（emotion 没加引号）、
    ///    `"0.80,0.80],`（字符串没闭合），而且 10 句全被判成对白、说话人写成
    ///    「灵」「秦」这种单字幻觉——说话人直接影响选哪把声音，错了比不填更糟。
    ///    → type / speaker 交回正则，格式弃 JSON 改一行四字段。
    /// 3. 四字段版真机仍稳定漏最后一列：`句21: 声音力度缺失→0.8` 每批 7~8 处，
    ///    每次都触发整批重试=同一批 10 句再烧一遍 GPU。而声音力度本来就不需要
    ///    理解上下文——它只由「吼/低声/耳语」这类提示语动词决定，
    ///    `FastChapterAnalyzer.detectVoiceStrength` 已经在管这件事，口径还和这里一致。
    ///    → 收回到规则，模型只剩 3 个字段。
    static func buildPrompt(
        chapter: Chapter,
        context: StoryContext
    ) -> String {

        let sentenceList = chapter.sentences
            .map {
                "\($0.index): \($0.text.replacingOccurrences(of: "\n", with: " "))"
            }
            .joined(separator: "\n")

        let indexList = chapter.sentences
            .map { String($0.index) }
            .joined(separator: " ")

        return """
        /no_think

        为小说句子标注朗读情绪。每句一行，共 \(chapter.sentences.count) 行，序号照抄输入、顺序一致：\(indexList)

        每行 3 项，用空格分开：序号 情绪 情绪强度
        情绪只能写这 9 个英文词之一：neutral happy sad angry surprised fearful excited calm tense
        情绪强度 0~1：0.3 轻微 / 0.5 中等 / 0.8 明显 / 1.0 极强烈。
        情绪弱不等于声音虚：悲伤、平静、克制也只是情绪淡，不是气声。
        不要引号、不要方括号、不要逗号、不要解释、不要说话人。判断不了就写：序号 neutral 0.5

        示例（与下面的输入无关，序号不要照抄）：
        7 calm 0.3
        8 angry 0.85

        输入：
        \(sentenceList)

        现在直接输出。
        """
    }

    // MARK: - Parse Response

    /// 一条识别结果：序号 + 情绪 + 情绪强度。数值为 nil 表示模型没给出可用的数。
    private struct Record {
        var index: Int?
        var emotion: Emotion
        var intensity: Double?
    }

    /// 按「情绪词」为锚点在记号流里定位每条结果，再按位置收参数。
    ///
    /// 不解析 JSON：模型会漏引号、漏闭合括号、多写一列、把两数塞进一个串，任何一处
    /// 语法塌掉都能把整批带进默认值。这里引号括号逗号一律当分隔符丢掉，所以
    /// `31 calm 0.5`、`[31,"calm",0.5]`、`31 calm 0.5（说明）` 是同一个结果；
    /// 坏掉的一行只丢那一行（那句保留规则参数），后面的行照样收。
    static func parseResponse(
        _ response: String,
        expectedIndices: [Int]
    ) -> (result: AIAnalysisResult, issues: [String]) {

        let expected = Set(expectedIndices)
        let tokens = tokenize(response, expectedIndices: expected)
        var records: [Record] = []
        // 上一条结果消费到的位置：往前找序号时不越过它，免得把上一行的参数当序号。
        var cursor = 0
        var i = 0

        while i < tokens.count {
            guard let emotion = tokens[i].emotion else {
                i += 1
                continue
            }

            var index: Int?
            var j = i - 1
            while j >= cursor {
                if let candidate = tokens[j].indexCandidate {
                    index = candidate
                    break
                }
                j -= 1
            }

            // 情绪词之后那一个数就是情绪强度（越界交给校验裁回 0~1）。
            // 撞见下一行的序号或情绪就停，别让缺数字的一行把下一行的参数顺走。
            var intensity: Double?
            var k = i + 1
            while k < tokens.count {
                let token = tokens[k]
                if token.indexCandidate != nil || token.emotion != nil { break }
                if let value = token.number {
                    intensity = value
                    k += 1
                    break
                }
                k += 1
            }

            records.append(Record(
                index: index,
                emotion: emotion,
                intensity: intensity
            ))
            cursor = k
            i = k
        }

        var byIndex = [Int: Record]()
        var unassigned: [Record] = []
        for record in records {
            guard let index = record.index else {
                unassigned.append(record)
                continue
            }
            byIndex[index] = byIndex[index] ?? record
        }
        // 序号列整个没认出来（模型自己从 1 重新编号）时按输出顺序补位：
        // 宁可参数错配一句，也不要整批退回默认值。
        for record in unassigned {
            guard let slot = expectedIndices.first(where: { !byIndex.keys.contains($0) }) else { break }
            byIndex[slot] = record
        }

        if byIndex.count < expectedIndices.count {
            print("⚠️ 只从输出里认出 \(byIndex.count)/\(expectedIndices.count) 句，缺的句子保留规则参数")
            logRawExcerpt(response)
        }

        var sentences: [AIAnalyzedSentence] = []
        var allIssues: [String] = []

        for idx in expectedIndices {
            guard let record = byIndex[idx] else {
                // 没认出来就什么都不做：这一句留着正则那套参数照读。硬塞 neutral
                // 反而是拿「模型的失败」盖掉正则本来正确的判断。
                allIssues.append("句\(idx): 无输出→保留规则参数")
                continue
            }
            let (sentence, issues) = makeSentence(record: record, expectedIndex: idx)
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

    // MARK: - Build One Sentence + Validation

    /// 返回「一定合规」的情绪标注 + 本次所做的修正项。
    /// issues 非空即代表模型原始输出缺项/越界，被强制修正到合法值。
    ///
    /// 只修情绪强度：声音力度不再经过模型，所以这里不可能也不该出现它的修正记录。
    private static func makeSentence(
        record: Record,
        expectedIndex: Int
    ) -> (AIAnalyzedSentence, [String]) {

        var issues: [String] = []

        let emotion = record.emotion

        var intensity = record.intensity
        if intensity == nil {
            issues.append("情绪强度缺失→\(emotion.defaultIntensity)")
            intensity = emotion.defaultIntensity
        } else if let raw = intensity, raw < 0 || raw > 1 {
            let clamped = clamp(raw, min: 0, max: 1)
            issues.append("情绪强度越界(\(raw))→\(clamped)")
            intensity = clamped
        }

        return (
            AIAnalyzedSentence(
                index: expectedIndex,
                emotion: emotion,
                emotionIntensity: intensity ?? Emotion.neutral.defaultIntensity
            ),
            issues
        )
    }

    /// 送进 TTS 的最低声音力度。低于此值基本就是气声/句尾泄气。
    /// 现在由规则引擎兜底（`FastChapterAnalyzer.detectVoiceStrength`），模型不参与。
    static let voiceStrengthFloor: Double = 0.6

    // MARK: - Tokenizer

    /// 一个记号：一段连续的英文字母（情绪词候选）或一个数字。其余字符
    /// （引号、方括号、逗号、冒号、Markdown、中文）都是分隔符。
    private struct Token {
        let number: Double?
        /// 认「本句序号」用：纯整数、且确实是这一批要的句子号。
        let indexCandidate: Int?
        let emotion: Emotion?

        private init(number: Double?, indexCandidate: Int?, emotion: Emotion?) {
            self.number = number
            self.indexCandidate = indexCandidate
            self.emotion = emotion
        }

        init(word: String) {
            self.init(number: nil, indexCandidate: nil, emotion: Emotion(rawValue: word.lowercased()))
        }

        init(numberText: String, expectedIndices: Set<Int>) {
            let value = Double(numberText)
            var candidate: Int?
            if !numberText.contains("."), let whole = value.map({ Int($0) }), expectedIndices.contains(whole) {
                candidate = whole
            }
            self.init(number: value, indexCandidate: candidate, emotion: nil)
        }
    }

    private static func tokenize(_ text: String, expectedIndices: Set<Int>) -> [Token] {
        let chars = Array(text)
        var tokens: [Token] = []
        var i = 0

        while i < chars.count {
            let c = chars[i]

            if c.isASCII, c.isLetter {
                var word = ""
                while i < chars.count, chars[i].isASCII, chars[i].isLetter {
                    word.append(chars[i])
                    i += 1
                }
                tokens.append(Token(word: word))
                continue
            }

            if c.isASCII, c.isNumber {
                var digits = ""
                while i < chars.count {
                    let d = chars[i]
                    if d.isASCII, d.isNumber {
                        digits.append(d)
                        i += 1
                        continue
                    }
                    // 小数点只在后面紧跟数字才算进这个数；否则当句读丢掉（「0.8.」仍是 0.8）
                    if d == ".", i + 1 < chars.count, chars[i + 1].isASCII, chars[i + 1].isNumber {
                        digits.append(d)
                        i += 1
                        continue
                    }
                    break
                }
                tokens.append(Token(numberText: digits, expectedIndices: expectedIndices))
                continue
            }

            i += 1
        }

        return tokens
    }

    /// 日志用：模型输出换行折叠、只留节选，用来区分「没出声」和「参数漂了」。
    private static func logRawExcerpt(_ text: String) {
        let flat = text.replacingOccurrences(of: "\n", with: "⏎")
        if flat.count <= 360 {
            print("[RawOut] \(flat)")
        } else {
            print("[RawOut] 头:\(flat.prefix(180)) …… 尾:\(flat.suffix(180))")
        }
    }

    // MARK: - Helpers

    private static func clamp(_ value: Double, min lo: Double, max hi: Double) -> Double {
        Swift.max(lo, Swift.min(hi, value))
    }

}
