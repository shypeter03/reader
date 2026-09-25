//
//  AITools.swift
//  Reader
//
//  Created by 粟海洋 on 2026/8/27.
//

import Foundation

enum AITools {

    // MARK: - Build Prompt

    /// 给 0.6B 小模型下的指令：只问朗读参数，不问「这句是谁说的」。
    ///
    /// 两版演进都在削任务量，因为真机日志里失败的都是任务本身：
    /// 1. 旧版 8 列 JSON、指令 3000 字：prefill 大、多约束下漏列串列。→ 压到 6 列。
    /// 2. 6 列仍不稳：`[11,"d","灵",neutral,0.5,0.8]`（emotion 没加引号）、
    ///    `"0.80,0.80],`（字符串没闭合），而且 10 句全被判成对白、说话人写成
    ///    「灵」「秦」「人体」「元气」这种单字幻觉——说话人直接影响选哪把声音，
    ///    错了比不填更糟。
    ///
    /// 所以现在：type / speaker 交回正则（`FastChapterAnalyzer`，它按引号和本句
    /// 提示词判对白，不会凭空造人名），LLM 只报 emotion / 情绪强度 / 声音力度这三件
    /// 它确实比正则强的事。格式也不再要 JSON：一行一句、空格分隔的 4 个字段，
    /// 少掉引号与括号就少掉一整类语法失败，输出 token 也一起减半。
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

        为小说句子标注 TTS 朗读参数。每句一行，共 \(chapter.sentences.count) 行，序号照抄输入、顺序一致：\(indexList)

        每行 4 项，用空格分开：序号 情绪 情绪强度 声音力度
        情绪只能写这 9 个英文词之一：neutral happy sad angry surprised fearful excited calm tense
        情绪强度 0~1：0.3 轻微 / 0.5 中等 / 0.8 明显 / 1.0 极强烈。
        声音力度 0~1，与情绪强度互相独立，按情绪取：neutral/calm/sad 0.80，fearful 0.75，happy/tense 0.85，surprised/excited 0.90，angry 0.95；只有本句明写轻声、低声、小声、耳语、悄悄，才给 0.6~0.75。
        情绪弱不等于声音虚：悲伤、平静、克制都不许读成气声。整句的音量、气息、语速必须从头到尾一致，不许句尾越读越轻。
        不要引号、不要方括号、不要逗号、不要解释、不要说话人。判断不了就写：序号 neutral 0.5 0.8

        示例（与下面的输入无关，序号不要照抄）：
        7 calm 0.3 0.8
        8 angry 0.85 0.95

        输入：
        \(sentenceList)

        现在直接输出。
        """
    }

    // MARK: - Parse Response

    /// 一条识别结果：序号 + 三个朗读参数。数值为 nil 表示模型没给出可用的数。
    private struct Record {
        var index: Int?
        var emotion: Emotion
        var intensity: Double?
        var voiceStrength: Double?
    }

    /// 按「情绪词」为锚点在记号流里定位每条结果，再按位置收参数。
    ///
    /// 不解析 JSON：模型会漏引号、漏闭合括号、多写一列、把两数塞进一个串，任何一处
    /// 语法塌掉都能把整批带进默认值。这里引号括号逗号一律当分隔符丢掉，所以
    /// `31 calm 0.5 0.8`、`[31,"calm",0.5,0.8]`、`31 calm 0.5 0.8（说明）` 是同一个结果；
    /// 坏掉的一行只丢那一行（那句保留规则参数），后面的行照样收。
    static func parseResponse(
        _ response: String,
        expectedIndices: [Int]
    ) -> (result: AIAnalysisResult, issues: [String]) {

        let expected = Set(expectedIndices)
        let tokens = tokenize(response, expectedIndices: expected)
        var records: [Record] = []
        // 上一条结果消费到的位置：往前找序号时不越过它，免得把上一行的力度当序号。
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

            // 情绪词之后的两个数：情绪强度、声音力度（越界交给校验裁回 0~1）。
            // 撞见下一行的序号或情绪就停，别让缺数字的一行把下一行的参数顺走。
            var numbers: [Double] = []
            var k = i + 1
            while k < tokens.count, numbers.count < 2 {
                let token = tokens[k]
                if token.indexCandidate != nil || token.emotion != nil { break }
                if let value = token.number {
                    numbers.append(value)
                }
                k += 1
            }

            records.append(Record(
                index: index,
                emotion: emotion,
                intensity: numbers.first,
                voiceStrength: numbers.count > 1 ? numbers[1] : nil
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

    /// 返回「一定合规」的朗读参数 + 本次所做的修正项。
    /// issues 非空即代表模型原始输出缺项/越界，被强制修正到合法值。
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

        // voiceStrength 与 emotionIntensity 独立：模型常把「悲伤/紧张」顺手写成
        // 0.2 这类气声值，听感就是后半句越读越轻、句尾泄气。低于地板时按该情绪的
        // 推荐值抬回来，绝不把虚弱的力度原样送进 TTS。
        var voiceStrength = record.voiceStrength
        if voiceStrength == nil {
            issues.append("声音力度缺失→\(emotion.defaultVoiceStrength)")
            voiceStrength = emotion.defaultVoiceStrength
        } else if let raw = voiceStrength, raw < 0 || raw > 1 {
            let clamped = clamp(raw, min: 0, max: 1)
            issues.append("声音力度越界(\(raw))→\(clamped)")
            voiceStrength = clamped
        }
        if let raw = voiceStrength, raw < Self.voiceStrengthFloor {
            let lifted = max(Self.voiceStrengthFloor, emotion.defaultVoiceStrength)
            issues.append("声音力度过低(\(raw))→\(lifted)，情绪弱不等于声音虚")
            voiceStrength = lifted
        }

        return (
            AIAnalyzedSentence(
                index: expectedIndex,
                emotion: emotion,
                emotionIntensity: intensity ?? Emotion.neutral.defaultIntensity,
                voiceStrength: voiceStrength ?? emotion.defaultVoiceStrength
            ),
            issues
        )
    }

    /// 送进 TTS 的最低声音力度。低于此值基本就是气声/句尾泄气。
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
