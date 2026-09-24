//
//  HtmlExtractor.swift
//  Reader
//
//  Created by 粟海洋 on 2026/8/26.
//

import Foundation

enum HTMLTextExtractor {

    static func extractText(
        from html: String
    ) -> String {

        // 只解析 <body> 内容：
        // CSS / <style> / <link> / <meta> 都在 <head> 中，
        // 正文只在 <body> 内，避免把样式读进文本。

        var text =
            bodyContent(of: html) ?? html

        // 删除 XML 声明、CDATA、注释

        text = removingPattern(
            "<\\?[^>]*\\?>",
            from: text
        )

        text = removingPattern(
            "<!DOCTYPE[^>]*>",
            from: text
        )

        text = removingPattern(
            "<!\\[CDATA\\[[\\s\\S]*?\\]\\]>",
            from: text
        )

        text = removingPattern(
            "<!--[\\s\\S]*?-->",
            from: text
        )

        // 删除 script（含 body 内联脚本）

        text =
            removing(
                tag: "script",
                from: text
            )

        // 删除 style（含 body 内联样式）

        text =
            removing(
                tag: "style",
                from: text
            )

        // 换行标签

        let lineBreakTags = [
            "br",
            "p",
            "div",
            "section",
            "article",
            "h1",
            "h2",
            "h3",
            "h4",
            "h5",
            "h6",
            "li"
        ]

        for tag in lineBreakTags {

            text =
                text.replacingOccurrences(
                    of: "<\(tag)[^>]*>",
                    with: "\n",
                    options: .regularExpression
                )

            text =
                text.replacingOccurrences(
                    of: "</\(tag)>",
                    with: "\n",
                    options: .regularExpression
                )
        }

        // 删除剩余 HTML 标签

        text =
            text.replacingOccurrences(
                of: "<[^>]+>",
                with: "",
                options: .regularExpression
            )

        // HTML entities

        text =
            decodeEntities(text)

        // 软连字符（&shy; / &#173;）只是「这里可以换行」的排版提示，
        // 留在文本里会被当成一个非中文片段送去 espeak，念出杂音。
        text = text.replacingOccurrences(of: "\u{00AD}", with: "")

        // 清理空格

        text =
            text.replacingOccurrences(
                of: "[ \\t]+",
                with: " ",
                options: .regularExpression
            )

        // 换行分两种：段内折行要接上，段落边界才留作句界。
        // 见 ``joiningSoftLineBreaks``。
        text = joiningSoftLineBreaks(text)

        return text
            .trimmingCharacters(
                in: .whitespacesAndNewlines
            )
    }

    /// 只有一个换行的地方是**段内折行**（XHTML 源码为了排版折的行、单个 `<br>`），
    /// 直接接回同一句；两个及以上连续换行才是段落边界，压成一个 `\n` 留给断句当句界。
    ///
    /// 这一步非做不可：以前任何换行都被当成句末，
    /// `<p>他把书轻轻放在\n桌上。</p>` 会切成「他把书轻轻放在」+「桌上。」，
    /// 一个词从中间劈开，后一半只有 3 个字 —— 实测 Kokoro 对不足 4 字的输入
    /// 大概率吐不出有效音频（3 字 6/6 次失败），整句就只能降级到 Edge。
    static func joiningSoftLineBreaks(_ text: String) -> String {

        let characters = Array(text)
        let blanks: Set<Swift.Character> = ["\n", " ", "\t", "\u{00A0}"]

        var output = ""
        output.reserveCapacity(text.count)

        var index = 0
        while index < characters.count {

            let character = characters[index]

            guard character == "\n" else {
                output.append(character)
                index += 1
                continue
            }

            // 吃掉一整段空白，顺便数里面有几个换行
            var newlines = 0
            var scan = index
            while scan < characters.count, blanks.contains(characters[scan]) {
                if characters[scan] == "\n" { newlines += 1 }
                scan += 1
            }

            if newlines >= 2 {
                output.append("\n")
            } else if !output.isEmpty, scan < characters.count {
                let previous = output.last ?? " "
                let next = characters[scan]
                if previous == "-", next.isLetter, next.isASCII, isWordBreakHyphen(output) {
                    // 英文断词连字符：`infor-\nmation` 必须把连字符一起吃掉再接上。
                    // 留着一个孤零零的「- 」会让 espeak 把 infor / mation 当两个词念，
                    // 句尾就冒出一个来历不明的怪词。
                    output.removeLast()
                } else if !(isCJKContext(previous) || isCJKContext(next)) {
                    // 中文两侧不留空格，英文之间要留一个，否则单词粘在一起
                    output.append(" ")
                }
            }
            // 段首/段尾的单个换行直接丢掉

            index = scan
        }

        return output
    }

    /// 连字符是不是「英文断词」用的：前面紧跟 ASCII 字母才算。
    /// 中文破折号「——」、行首的列表符「- 」都不算，别误删。
    private static func isWordBreakHyphen(_ output: String) -> Bool {
        guard output.last == "-" else { return false }
        let hyphen = output.index(before: output.endIndex)
        guard hyphen > output.startIndex else { return false }
        let previous = output[output.index(before: hyphen)]
        return previous.isLetter && previous.isASCII
    }

    /// 汉字符号（含全角标点、中日韩标点、弯引号）——它旁边不需要空格。
    private static func isCJKContext(_ character: Swift.Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x2E80...0x303F,   // 部首、中日韩符号与标点（。、「』）
             0x3040...0x30FF,   // 假名
             0x3100...0x312F,   // 注音
             0x3400...0x4DBF,   // 扩展 A
             0x4E00...0x9FFF,   // 汉字
             0xF900...0xFAFF,   // 兼容汉字
             0xFE30...0xFE4F,   // 兼容标点
             0xFF00...0xFFEF,   // 全角形式
             0x20000...0x2A6DF, // 扩展 B
             0x2010...0x201F:   // 连字符与弯引号 “ ” ‘ ’——中文小说里成片出现
            return true
        default:
            return false
        }
    }

    private static func removing(
        tag: String,
        from text: String
    ) -> String {

        // [\s\S]*? 跨行匹配（replacingOccurrences 无法开启 dotMatchesLineSeparators）

        text.replacingOccurrences(
            of:
                "<\(tag)[^>]*>[\\s\\S]*?</\(tag)>",
            with: "",
            options: [
                .regularExpression,
                .caseInsensitive
            ]
        )
    }

    /// 按正则删除（忽略大小写；跨行需使用 [\s\S] 而非 .）
    private static func removingPattern(
        _ pattern: String,
        from text: String
    ) -> String {

        text.replacingOccurrences(
            of: pattern,
            with: "",
            options: [
                .regularExpression,
                .caseInsensitive
            ]
        )
    }

    /// 提取 <body>...</body> 之间的内容；没有 body 时返回 nil
    private static func bodyContent(
        of html: String
    ) -> String? {

        let pattern = "<body[^>]*>(.*?)</body[^>]*>"

        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [
                .caseInsensitive,
                .dotMatchesLineSeparators
            ]
        ) else {
            return nil
        }

        let range = NSRange(
            html.startIndex..<html.endIndex,
            in: html
        )

        guard let match = regex.firstMatch(
            in: html,
            options: [],
            range: range
        ), match.numberOfRanges > 1,
            let contentRange = Range(match.range(at: 1), in: html)
        else {
            return nil
        }

        return String(html[contentRange])
    }

    static func decodeEntities(_ text: String) -> String {

        var result = text

        // MARK: - 常见 HTML Entity

        let entities: [String: String] = [
            "&nbsp;": " ",
            "&amp;": "&",
            "&lt;": "<",
            "&gt;": ">",
            "&quot;": "\"",
            "&apos;": "'",
            "&#39;": "'",
            "&#160;": " "
        ]

        for (entity, replacement) in entities {
            result = result.replacingOccurrences(
                of: entity,
                with: replacement
            )
        }

        // MARK: - 十进制 Entity
        //
        // 例如：
        // &#20013; → 中
        // &#20320; → 你

        let decimalPattern = "&#([0-9]+);"

        if let regex = try? NSRegularExpression(
            pattern: decimalPattern
        ) {

            let range = NSRange(
                result.startIndex..<result.endIndex,
                in: result
            )

            let matches = regex.matches(
                in: result,
                range: range
            )

            // 倒序替换，避免修改字符串后导致 range 失效
            for match in matches.reversed() {

                guard match.numberOfRanges > 1 else {
                    continue
                }

                guard
                    let valueRange = Range(
                        match.range(at: 1),
                        in: result
                    )
                else {
                    continue
                }

                let numberString =
                    String(result[valueRange])

                guard
                    let value = UInt32(numberString),
                    let scalar = UnicodeScalar(value)
                else {
                    continue
                }

                guard
                    let fullRange = Range(
                        match.range,
                        in: result
                    )
                else {
                    continue
                }

                result.replaceSubrange(
                    fullRange,
                    with: String(scalar)
                )
            }
        }

        // MARK: - 十六进制 Entity
        //
        // 例如：
        // &#x4E2D; → 中
        // &#x4F60; → 你

        let hexPattern = "&#x([0-9A-Fa-f]+);"

        if let regex = try? NSRegularExpression(
            pattern: hexPattern
        ) {

            let range = NSRange(
                result.startIndex..<result.endIndex,
                in: result
            )

            let matches = regex.matches(
                in: result,
                range: range
            )

            for match in matches.reversed() {

                guard match.numberOfRanges > 1 else {
                    continue
                }

                guard
                    let valueRange = Range(
                        match.range(at: 1),
                        in: result
                    )
                else {
                    continue
                }

                let numberString =
                    String(result[valueRange])

                guard
                    let value = UInt32(
                        numberString,
                        radix: 16
                    ),
                    let scalar = UnicodeScalar(value)
                else {
                    continue
                }

                guard
                    let fullRange = Range(
                        match.range,
                        in: result
                    )
                else {
                    continue
                }

                result.replaceSubrange(
                    fullRange,
                    with: String(scalar)
                )
            }
        }

        return result
    }
    
    static func firstTagValue(
        _ tag: String,
        in xml: String
    ) -> String? {

        let escapedTag =
            NSRegularExpression
                .escapedPattern(
                    for: tag
                )

        let pattern =
            "<\(escapedTag)[^>]*>(.*?)</\(escapedTag)>"

        guard let regex =
                try? NSRegularExpression(
                    pattern: pattern,
                    options: [
                        .caseInsensitive,
                        .dotMatchesLineSeparators
                    ]
                )
        else {
            return nil
        }

        let range =
            NSRange(
                xml.startIndex..<xml.endIndex,
                in: xml
            )

        guard let match =
                regex.firstMatch(
                    in: xml,
                    range: range
                )
        else {
            return nil
        }

        guard let valueRange =
                Range(
                    match.range(at: 1),
                    in: xml
                )
        else {
            return nil
        }

        return HTMLTextExtractor
            .decodeEntities(
                String(xml[valueRange])
            )
            .trimmingCharacters(
                in: CharacterSet.whitespacesAndNewlines
            )
    }
    
    // MARK: - HTML Cleaning
    static func cleanHTMLText(_ html: String) -> String {

        var text = html

        // HTML 换行标签
        text = text.replacingOccurrences(
            of: "<br\\s*/?>",
            with: "\n",
            options: .regularExpression
        )

        text = text.replacingOccurrences(
            of: "</p\\s*>",
            with: "\n",
            options: .regularExpression
        )

        text = text.replacingOccurrences(
            of: "</div\\s*>",
            with: "\n",
            options: .regularExpression
        )

        text = text.replacingOccurrences(
            of: "</li\\s*>",
            with: "\n",
            options: .regularExpression
        )

        // 删除所有 HTML/XML 标签
        text = text.replacingOccurrences(
            of: "<[^>]+>",
            with: "",
            options: .regularExpression
        )

        // HTML entities
        text = HTMLTextExtractor.decodeEntities(text)

        // 统一换行
        text = text.replacingOccurrences(
            of: "\r\n",
            with: "\n"
        )

        text = text.replacingOccurrences(
            of: "\r",
            with: "\n"
        )

        // 清理连续空格
        text = text.replacingOccurrences(
            of: "[ \\t]+",
            with: " ",
            options: .regularExpression
        )

        // 清理连续空行
        text = text.replacingOccurrences(
            of: "\\n{3,}",
            with: "\n\n",
            options: .regularExpression
        )

        return text
    }

}
