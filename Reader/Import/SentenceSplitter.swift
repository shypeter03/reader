//
//  SentenceSplitter.swift
//  Reader
//
//  Created by 粟海洋 on 2026/8/26.
//

import Foundation

enum SentenceSplitter {

    /// 句子边界。
    ///
    /// 刻意**不含**「：」「；」及半角形式：它们后面必然还有话，从那里切开只能得到
    /// 「他说：」这种说不出口的半截话。实测 Kokoro 对 ≤3 个字的输入失败率
    /// 83%~100%（整段 NaN，存成 WAV 就是满刻度爆音），而把
    /// 「他说：你好。」整句喂进去是 0% 失败、停顿也是对的。
    private static let sentenceEndings =
        CharacterSet(
            charactersIn: "。！？!?\n"
        )

    /// 短于这个字数的片段不合成（并进相邻句子）。
    ///
    /// 取 4 是实测拐点：「他把。」3 字 6/6 失败，「他把书。」4 字 0/6 失败。
    static let minimumSpeakableCharacters = 4

    /// 成对引号：里面不切句，闭合时算一句结束。
    ///
    /// 一律写全 `Swift.Character`：本模块自己有个「小说角色」叫 `Character`
    /// （Reader/Models/Character.swift），同模块内它会遮蔽标准库的那个。
    private static let quoteOpeners: Set<Swift.Character> = ["“", "「", "『"]
    private static let quoteClosers: Set<Swift.Character> = ["”", "」", "』"]

    static func split(
        _ text: String,
        chapterIndex: Int = 0
    ) -> [Sentence] {

        var result: [Sentence] = []

        var buffer = ""

        // 引号内不切句：跨行对话（“…？\n…！”）保持为一句
        var quoteDepth = 0

        func flush() {
            append(
                buffer,
                to: &result,
                chapterIndex: chapterIndex
            )
            buffer = ""
        }

        for character in text {

            if quoteOpeners.contains(character), quoteDepth > 0 {
                // 上一段引号未闭合，就此截断，避免吞掉后续文本
                flush()
            }

            buffer.append(character)

            if character == "\"" {
                // 直角引号没有方向，只能按开/闭交替配对
                if quoteDepth == 0 {
                    quoteDepth = 1
                } else {
                    quoteDepth = 0
                    flush()
                }
                continue
            }

            if quoteOpeners.contains(character) {
                quoteDepth += 1
                continue
            }

            if quoteClosers.contains(character) {
                quoteDepth = max(0, quoteDepth - 1)
                flush()
                continue
            }

            if quoteDepth == 0,
               String(character).rangeOfCharacter(from: Self.sentenceEndings) != nil {
                flush()
            }
        }

        flush()

        // 独立成行的收尾符号（如 ” 』 ））属于上一句，合并回去而不是单独成句
        var merged: [Sentence] = []
        for sentence in result {
            let isPunctuationOnly =
                sentence.text.allSatisfy {
                    !$0.isLetter && !$0.isNumber
                }
            if isPunctuationOnly, var last = merged.popLast() {
                last.text += sentence.text
                merged.append(last)
            } else {
                merged.append(sentence)
            }
        }

        // 太短的片段（「走。」「嗯？」）合成必然坏掉，往后并；句尾只剩短的，就并回前一句。
        var packed: [String] = []
        var pending = ""

        for text in merged.flatMap({ capping($0.text) }) {
            pending += text

            if spokenCharacterCount(pending) >= minimumSpeakableCharacters {
                packed.append(pending)
                pending = ""
            }
        }

        if !pending.isEmpty {
            if var last = packed.popLast() {
                last += pending
                packed.append(last)
            } else {
                packed.append(pending)
            }
        }

        return packed
            .filter {
                !$0.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty
            }
            .enumerated()
            .map { index, value in
                Sentence(
                    index: index,
                    text: value,
                    chapterIndex: chapterIndex
                )
            }
    }

    /// 一句最多留多少个字，超了就在弱边界处裁开。
    ///
    /// 取 48：实测 Kokoro 的「秒/字」基本恒定（0.33s/字，见 kokoro-probe length），
    /// 所以**一句的等待时间和它的字数成正比**——设备侧一句 40 字就是一次
    /// 13s 音频、40s 的合成等待（首播 SLA 直接 MISS）。正常叙述句很少超过 48 字，
    /// 只有连续并列/整段引语才会，这条只治那一种病，不改普通句子的韵律。
    ///
    /// 注意它**不会**把 RTF 降下来（RTF 对句长是平的，Mac 上 21→183 字都稳定在
    /// 0.7~0.9），它省的是「等这一句听完之前要先等多久」和单次推理的工作集。
    static let maximumSpeakableCharacters = 48

    /// 裁长句时允许下刀的位置：并列停顿优先，冒号分号次之。
    private static let weakBoundaries: Set<Swift.Character> = [
        "，", ",", "、", "；", ";", "：", ":",
    ]

    /// 把超长句裁成几段；不足上限的原样返回。
    static func capping(_ text: String) -> [String] {
        let characters = Array(text)

        guard spokenCharacterCount(text) > maximumSpeakableCharacters else {
            return [text]
        }

        var pieces: [String] = []
        var start = 0

        while start < characters.count {
            var end = characters.count
            var counted = 0
            var cut = -1      // [start, 当前位置] 内最后一个可下刀的位置（含标点）

            for index in start..<characters.count {
                let character = characters[index]

                if character.isLetter || character.isNumber {
                    counted += 1
                } else if weakBoundaries.contains(character) {
                    cut = index
                }

                if counted > maximumSpeakableCharacters {
                    // 有弱边界就在它后面落刀（并列成分各自成句，不从中间劈字）；
                    // 一整段都没有标点才硬按上限切——宁可切得难看，也不能让
                    // 单次合成没有上界。
                    end = cut >= start ? cut + 1 : index + 1
                    break
                }
            }

            pieces.append(String(characters[start..<end]))
            start = end
        }

        return pieces
    }

    /// 实际要念出来的字数（标点不算）。
    static func spokenCharacterCount(_ text: String) -> Int {
        text.filter { $0.isLetter || $0.isNumber }.count
    }

    private static func append(
        _ value: String,
        to result: inout [Sentence],
        chapterIndex: Int
    ) {

        let text =
            value.trimmingCharacters(
                in: .whitespacesAndNewlines
            )

        guard !text.isEmpty else {
            return
        }

        result.append(
            Sentence(
                index: result.count,
                text: text
            )
        )
    }
}
