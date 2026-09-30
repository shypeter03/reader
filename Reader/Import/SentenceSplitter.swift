//
//  SentenceSplitter.swift
//  Reader
//
//  Created by 粟海洋 on 2026/8/26.
//

import Foundation

enum SentenceSplitter {

    /// 正文口径版本。**改动了任何一句正文的切法**（本文件的规则、`HTMLTextExtractor`
    /// 取文、`EPUBParser.clean`）都要 +1。
    ///
    /// 存在的理由：正文只在导入时后台解析一次并落库，打开章节不再跑 parser，
    /// 旧书的 chapter.json 里没有字段可对（读成 0），版本对不上才回落解析器重切一遍。
    static let textVersion = 2

    /// 句子边界。
    ///
    /// 刻意**不含**「：」「；」及半角形式：它们后面必然还有话，从那里切开只能得到
    /// 「他说：」这种说不出口的半截话。实测 Kokoro 对 ≤3 个字的输入失败率
    /// 83%~100%（整段 NaN，存成 WAV 就是满刻度爆音），而把
    /// 「他说：你好。」整句喂进去是 0% 失败、停顿也是对的。
    ///
    /// 也不含 `\n`：段落分隔符在 `split` 里就当硬边界用掉了，轮到这里的文本不会带换行。
    private static let sentenceEndings =
        CharacterSet(
            charactersIn: "。！？!?"
        )

    /// 短于这个字数的片段不合成（并进相邻句子）。
    ///
    /// 取 4 是实测拐点：「他把。」3 字 6/6 失败，「他把书。」4 字 0/6 失败。
    /// 只在**同一段内**并：跨段去并就见 ``split(_:chapterIndex:)`` 的注释。
    static let minimumSpeakableCharacters = 4

    /// 成对引号：里面不切句，闭合时算一句结束。
    ///
    /// 一律写全 `Swift.Character`：本模块自己有个「小说角色」叫 `Character`
    /// （Reader/Models/Character.swift），同模块内它会遮蔽标准库的那个。
    private static let quoteOpeners: Set<Swift.Character> = ["“", "「", "『"]
    private static let quoteClosers: Set<Swift.Character> = ["”", "」", "』"]

    /// 把一章正文切成可朗读的句子。
    ///
    /// **段落（`\n`）是硬边界**，一段一段单独切，引号状态每段从头算。整篇连着扫会出
    /// 三种毛病，都源自「句子」和「段落」被混成一件事：
    ///
    /// 1. 跨段的引语并成一句，`Sentence.text` 里带着原始 `\n`（诗行、多段引语最容易撞）；
    /// 2. 某段漏了后引号，之后所有段都被当成「引号内」不切句，一整章只剩 48 字硬裁的边界；
    /// 3. 不足字数下限的短句被**向前**并到下一段去。下一段往往是旁白，而
    ///    ``FastChapterAnalyzer`` 只要在一句里看见「“…”」就判成对白 ——
    ///    表现是整段旁白用角色的嗓子念出来。段内并句不会有这个问题，
    ///    因为同一段本来就是作者写在一起的一口气。
    ///
    /// 所以极短的一段（单独成段的「“嗯。”」）就让它自成一句：Edge TTS 念它是正常的，
    /// 而为了凑够 4 个字去粘邻居，代价是把邻居的身份改掉。
    static func split(
        _ text: String,
        chapterIndex: Int = 0
    ) -> [Sentence] {

        var result: [(text: String, startsParagraph: Bool)] = []
        // 只有「一个字的正文都没有」的片段（独立成段的收尾引号）才允许跨段并，
        // 它身上没有任何内容，并到哪儿都不会改归属；并进前一句最贴合原意。
        var danglingMark = ""

        for paragraph in text.split(separator: "\n", omittingEmptySubsequences: true) {

            var pieces = pack(fragments(in: String(paragraph)))
            guard !pieces.isEmpty else { continue }

            if !danglingMark.isEmpty {
                pieces[0] = danglingMark + pieces[0]
                danglingMark = ""
            }

            if pieces.count == 1, spokenCharacterCount(pieces[0]) == 0 {
                if var last = result.popLast() {
                    last.text += pieces[0]
                    result.append(last)
                } else {
                    danglingMark = pieces[0]
                }
                continue
            }

            // 每段的第一句才是段首。段内其余句子接着排，不再各自缩进。
            for (offset, piece) in pieces.enumerated() {
                result.append((piece, offset == 0))
            }
        }

        if !danglingMark.isEmpty { result.append((danglingMark, true)) }

        return result
            .enumerated()
            .map { index, value in
                Sentence(
                    index: index,
                    text: value.text,
                    chapterIndex: chapterIndex,
                    startsParagraph: value.startsParagraph
                )
            }
    }

    /// 一段之内的切分：引号感知的下刀 + 纯标点片段并回前一句。
    private static func fragments(in paragraph: String) -> [String] {

        var result: [String] = []
        var buffer = ""

        // 引号内不切句：一句台词里带几个「。」也应该是一次合成。
        // 用栈而不是计数器：得能分辨「嵌套开了第二层」和「上一段漏了后引号又开一段」。
        var openQuotes: [Swift.Character] = []
        // 当前这层引号里已经念了多少正文。超过一句的上限还没合上，就当它是漏配，
        // 从这里起恢复切句 —— 否则整段会糊成一句，边界全无。
        var spokenSinceQuote = 0

        func flush() {
            let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = ""
            guard !text.isEmpty else { return }

            // 单独出现的收尾符号（如只剩一个 ” 的一行）属于前一句，
            // 不能自成一句：它一个字的正文都没有。
            if text.allSatisfy({ !$0.isLetter && !$0.isNumber }), var last = result.popLast() {
                last += text
                result.append(last)
                return
            }
            result.append(text)
        }

        for character in paragraph {

            buffer.append(character)

            if character == "\"" {
                // 直引号没有方向，只能按开/闭交替配对
                if openQuotes.last == "\"" {
                    openQuotes.removeLast()
                    spokenSinceQuote = 0
                    flush()
                } else {
                    openQuotes.append("\"")
                }
                continue
            }

            if quoteOpeners.contains(character) {
                if openQuotes.last == character {
                    // 同一层引号还没合上就又开一枚：上一段按漏配截断，
                    // 这枚才算当前这段话的开头。嵌套（“ 里开 「）不走这条。
                    flush()
                    openQuotes.removeLast()
                    spokenSinceQuote = 0
                }
                openQuotes.append(character)
                continue
            }

            if quoteClosers.contains(character) {
                // 配不上对（书里引号混着用）也只能合上最里层，别让栈越来越深。
                if !openQuotes.isEmpty { openQuotes.removeLast() }
                spokenSinceQuote = 0
                // 合到最外层才算一句结束：「“他指着『这个』说好吗？”」里
                // 那个 』 只是嵌套的一层，从那里下刀会切出半截话。
                if openQuotes.isEmpty { flush() }
                continue
            }

            if openQuotes.isEmpty {
                if String(character).rangeOfCharacter(from: Self.sentenceEndings) != nil {
                    flush()
                }
            } else if character.isLetter || character.isNumber {
                spokenSinceQuote += 1
                if spokenSinceQuote > maximumSpeakableCharacters {
                    openQuotes.removeAll()
                    spokenSinceQuote = 0
                }
            }
        }

        flush()

        return result
    }

    /// 把一段里切出的片段按字数下限并句：太短的（「走。」「嗯？」）往后并；
    /// 段尾只剩短的，就并回前一句。
    private static func pack(_ fragments: [String]) -> [String] {

        var packed: [String] = []
        var pending = ""

        for fragment in fragments.flatMap({ capping($0) }) {
            pending += fragment

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
}
