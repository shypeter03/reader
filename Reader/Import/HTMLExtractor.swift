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

        // 清理空格

        text =
            text.replacingOccurrences(
                of: "[ \\t]+",
                with: " ",
                options: .regularExpression
            )

        text =
            text.replacingOccurrences(
                of: "\n\\s*\n+",
                with: "\n",
                options: .regularExpression
            )

        return text
            .trimmingCharacters(
                in: .whitespacesAndNewlines
            )
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
