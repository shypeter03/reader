//
//  HtmlExtractor.swift
//  Reader
//
//  Created by 粟海洋 on 2026/8/26.
//

import Foundation

enum HTMLTextExtractor {

    /// 正文里一处 `<img>` 的替身：一个私用区字符，占一个「字」的位置。
    ///
    /// 为什么要它：往下第三步就把所有标签删光了，图在那之前不留痕迹，事后没人知道
    /// 图上纸该站在哪一段之后。换成这一个字符，段落边界（`\n`）照旧由 `<p>` 提供，
    /// 于是「独占一段的图」洗出来就是一行只有哨兵——锚点从这一行来（见 `EPUBParser.imageAnchors`）。
    ///
    /// 私用区（U+E000…）正常文本里不会出现，`SentenceSplitter` 认它不是可朗读字符，
    /// 摘掉它之后剩下的句子和「书里根本没有图」那一份逐字相同。
    ///
    /// 为什么从标量造而不是写 `"\u{E000}"`：那种纯转义字面量在 Swift 里只当 String 看，
    /// 标成 `Character` 编译器直接拒（实测 `cannot convert value of type 'String'`），
    /// 而摘哨兵那一趟是按**字符**过滤的。String 由这一个字符生成，两头必然是同一个东西。
    ///
    /// 名字必须带 `Swift.`：这个 target 里有一个表示「人物」的 `Character`（见 `Models/Character.swift`），
    /// 不写限定就撞上它，编译器给你的报错是「参数不 conform Decoder」——完全看不出为什么的那种。
    static let imageMarkerCharacter: Swift.Character = Swift.Character(UnicodeScalar(0xE000)!)

    static let imageMarker = String(imageMarkerCharacter)

    /// 认 `<img>` 与 SVG 的 `<image>` 的**唯一**一条正则：换哨兵（``markingImages``）
    /// 和数重复率（``imageHrefs``）必须走同一个口径，否则「送去排图的张数」和
    /// 「书单上记的张数」会从根上分家——该跳的 logo 没跳、该画的图没画。
    private static let imageTagPattern = "<(?:img|image)\\b[^>]*>"

    private static let imageTagRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: imageTagPattern,
        options: [.caseInsensitive]
    )

    /// XHTML → 正文，外加「这一章有哪些图、按出现顺序」。
    static func extractBody(
        from html: String
    ) -> (text: String, imageHrefs: [String]) {

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

        // 图片换成哨兵。必须在换行标签那一步**之前**：那时 `<p>` 还在，
        // 图段才会连着自己的段落边界一起留下来；也必须在删标签那一步之前，
        // 否则 src 跟着标签一起没了。

        let marked = markingImages(text)
        text = marked.text

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

        // 中文之间的字面空格：源文件自带的，不是排版造出来的。
        text = removingSpacesBetweenCJK(text)

        // 换行分两种：段内折行要接上，段落边界才留作句界。
        // 见 ``joiningSoftLineBreaks``。
        text = joiningSoftLineBreaks(text)

        return (
            text.trimmingCharacters(
                in: .whitespacesAndNewlines
            ),
            marked.imageHrefs
        )
    }

    /// 只要正文、不要图的那一层薄壳（取证代码与老调用方走这条）。
    static func extractText(
        from html: String
    ) -> String {
        extractBody(from: html).text
    }

    /// 把每一个带 href 的 `<img>`/`<image>` 换成一个 ``imageMarker``，src 按文档顺序交出去。
    ///
    /// `<image>` 也管：固定版式（漫画、画集）用 SVG 那一个，`<img>` 是普通正文用的。
    /// 认不出 src 的那种（背景图 `style="background-image:url(...)"` 之类）原样删掉，
    /// 不留哨兵——留了也画不出东西，反倒占掉一个段落位。
    static func markingImages(
        _ text: String
    ) -> (text: String, imageHrefs: [String]) {

        guard let regex = imageTagRegex else {
            return (text, [])
        }

        let range = NSRange(
            text.startIndex..<text.endIndex,
            in: text
        )

        var output = ""
        output.reserveCapacity(text.count)

        var hrefs: [String] = []
        var cursor = text.startIndex

        for match in regex.matches(in: text, options: [], range: range) {
            guard let matchRange = Range(match.range, in: text) else { continue }

            let tag = String(text[matchRange])

            guard let href = imageHref(in: tag) else {
                // 没有 src 的 img 不是图，是一个占位的空标签：删掉，等价于从前。
                output.append(contentsOf: text[cursor..<matchRange.lowerBound])
                cursor = matchRange.upperBound
                continue
            }

            output.append(contentsOf: text[cursor..<matchRange.lowerBound])

            if occupiesOwnBlock(text, at: matchRange) {
                // 独占一块的图要自己占一行：见 ``occupiesOwnBlock``。
                output.append("\n\n")
                output.append(imageMarker)
                output.append("\n\n")
            } else {
                output.append(imageMarker)
            }

            hrefs.append(href)
            cursor = matchRange.upperBound
        }

        output.append(contentsOf: text[cursor...])

        return (output, hrefs)
    }

    /// 这一张图是不是**独占一个块**：往前、往后各跳过空白，撞到的第一个字符必须是
    /// 标签的尾（`>`）或头（`<`），中间不许有一个字。
    ///
    /// 为什么要分这一档：`joiningSoftLineBreaks` 只承认「两个及以上连续换行」为段落边界，
    /// 而 `</p><img/><p>` 这种不写空行的源文件（calibre 生成的网文普遍如此）前后各只有
    /// 一个换行——哨兵一插，那两个单换行都被当成段内折行接掉，于是两段并成一段，
    /// 图的锚点还退到**它前面**那一段的头顶（我欲封天实测 117 处，锚=本章最后一段的段首句）。
    /// 判成独占块就多铺两个换行，段落边界一定保住；图混在字里那一类（inline）原样插哨兵，
    /// 因为「书里根本没有图」的那份在这一处也没有边界，多铺反而把一段劈成两段。
    private static func occupiesOwnBlock(
        _ text: String,
        at range: Range<String.Index>
    ) -> Bool {

        let whitespaces: Set<Swift.Character> = [" ", "\t", "\n", "\u{00A0}"]

        // 往前跳空白，取撞到的**第一个非空白字符**（注意：不能拿 `back` 位置上的字符去比，
        // 那个位置在没跳过任何空白时就是 `<img>` 自己的 `<`，判据会永远不成立）。
        var back = range.lowerBound
        var before: Swift.Character?
        while back > text.startIndex {
            let previous = text.index(before: back)
            if whitespaces.contains(text[previous]) {
                back = previous
            } else {
                before = text[previous]
                break
            }
        }
        // 一路都是空白（图就在正文最前）：前面没有字，按独占算。
        let beforeIsTagEnd = before == nil || before == ">"

        var forward = range.upperBound
        while forward < text.endIndex, whitespaces.contains(text[forward]) {
            forward = text.index(after: forward)
        }
        let afterIsTagStart = forward == text.endIndex || text[forward] == "<"

        return beforeIsTagEnd && afterIsTagStart
    }

    /// 这一页 html 里所有图的 src，按出现顺序。**要保留哨兵、要洗正文的场合别用它**，
    /// 那是 ``markingImages`` 的活；这里只为「数一张图重复了几章」那一趟而不再洗一遍正文。
    static func imageHrefs(in html: String) -> [String] {

        guard let regex = imageTagRegex else { return [] }

        let range = NSRange(
            html.startIndex..<html.endIndex,
            in: html
        )

        var hrefs: [String] = []

        for match in regex.matches(in: html, options: [], range: range) {
            guard let matchRange = Range(match.range, in: html),
                  let href = imageHref(in: String(html[matchRange]))
            else { continue }

            hrefs.append(href)
        }

        return hrefs
    }

    /// 一个 `<img>` 开标签里的图地址。`src` 优先，SVG 的 `xlink:href` / `href` 兜底。
    private static func imageHref(in tag: String) -> String? {

        for name in ["src", "xlink:href", "href"] {
            let pattern = "\(name)\\s*=\\s*[\"']([^\"']+)[\"']"
            guard let regex = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive]
            ), let match = regex.firstMatch(
                in: tag,
                options: [],
                range: NSRange(tag.startIndex..<tag.endIndex, in: tag)
            ), match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: tag)
            else { continue }

            let value = String(tag[valueRange]).trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if !value.isEmpty { return value }
        }

        return nil
    }

    /// 删掉**两侧都是中文语境**的行内空格（半角空格、制表符、nbsp）。
    ///
    /// 为什么要有这一步：盗版/转换出来的 EPUB 正文里就带着空格，实测十本里九本有——
    /// 「偷出救命之药 ，而被青罗宗以魂炼」「位列榜首 ；《将夜》」「后 山海战 爆发」。
    /// 它们是一个个真字符，落在中文句子中间，渲染出来就是段里一截莫名的白；
    /// 阅读页没法把它当排版，因为中文一个字一格，多空一格就多看得见的一格。
    ///
    /// 判据写成「左右都不该有空格」而不是「把空格都清掉」：`第 5 章`、`ISBN 978-…`、
    /// `Perfect Unknow able` 这些一侧是 ASCII 的空格是该留的，那是词与词之间。
    /// 全角空格 U+3000 也不碰——中文书里它是版权页对齐、扉页作者行分隔用的排版空格
    /// （「出　　版　北京出版集团公司」），删了就把一版排好的字挤成一团；
    /// 而正文段首那两个全角空格轮不到这里，`SentenceSplitter` 收尾时 trim 掉了。
    ///
    /// 换行不参与（段落边界全靠它），见 `joiningSoftLineBreaks`。
    static func removingSpacesBetweenCJK(_ text: String) -> String {

        let spaces: Set<Swift.Character> = [" ", "\t", "\u{00A0}"]
        let characters = Array(text)

        var output = ""
        output.reserveCapacity(text.count)

        var index = 0
        while index < characters.count {

            guard spaces.contains(characters[index]) else {
                output.append(characters[index])
                index += 1
                continue
            }

            var scan = index
            while scan < characters.count, spaces.contains(characters[scan]) {
                scan += 1
            }

            let previous = output.last ?? " "
            let next = scan < characters.count ? characters[scan] : " "
            // 两侧都是中文（含全角标点、弯引号）→ 这个空格没有存在的理由
            if !(isCJKContext(previous) && isCJKContext(next)) {
                output.append(" ")
            }

            index = scan
        }

        return output
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

    /// 章节标题专用：清洗完再把换行压成一个空格。
    ///
    /// 正文必须留着换行，标题不行——`<span>第2章</span><br/>李火旺` 洗出来是
    /// 「第2章\n李火旺」，谁按单行显示就把后面那截整条切掉。落库前就并好，
    /// 不留给每个显示处各自猜一次。
    static func cleanHTMLTitle(_ html: String) -> String {

        cleanHTMLText(html)
            .replacingOccurrences(
                of: "[ \t\r\n\u{3000}]+",
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(
                in: .whitespacesAndNewlines
            )
    }

}
