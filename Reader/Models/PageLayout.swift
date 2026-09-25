//
//  PageLayout.swift
//  Reader
//
//  书本式分页：先把每句量一遍，再按页的可用高度贪心装页。
//

import SwiftUI

/// 排版的唯一口径。正文渲染和分页测量必须共用这一组常量——
/// 两边各写一份的话，量出来 30 行、实际 31 行，字就会溢到下一页去。
enum ReaderTypography {

    static func bodySize(scale: Double) -> CGFloat {
        19 * CGFloat(scale)
    }

    static func lineSpacing(size: CGFloat) -> CGFloat {
        size * 0.42
    }

    /// 段首缩进的两个全角空格。
    ///
    /// 不用「给整块加左内边距」：内边距会把折行的第二行一起推进去，一段三行
    /// 就成了一段阶梯，而中文书只有首行缩进，折回来的那行要贴版心。
    /// 全角空格在中文字体里正好一个字宽，所以缩进量跟着字号走；渲染和测量
    /// 都喂同一个字符串给排版引擎，折行结果自然一致。
    static let firstLineIndent = "\u{3000}\u{3000}"

    /// 这一句实际排出来长什么样（含段首缩进）。渲染与测量必须都走这里。
    static func displayText(_ sentence: Sentence, chapterTitle: String) -> String {
        if isChapterHeading(sentence, chapterTitle: chapterTitle) || !sentence.startsParagraph {
            return sentence.text
        }
        return firstLineIndent + sentence.text
    }

    /// 正文第一句常常就是章标题本身——EPUB 的 `<h1>` 抽成纯文本后就排在第一段。
    /// 它要按标题排（居中、不缩进），不能跟着正文走。
    ///
    /// 目录标签和正文里的 `<h1>` 常常只差一个「第9章」这样的编号（一边有、一边没有），
    /// 所以两边都剥掉编号再比。刻意不用「互相包含」：正文第一句里提到书名太常见了，
    /// 那样会把一整段正文当标题居中。
    static func isChapterHeading(_ sentence: Sentence, chapterTitle: String) -> Bool {
        guard sentence.index == 0 else { return false }
        let title = bareTitle(chapterTitle)
        return !title.isEmpty && bareTitle(sentence.text) == title
    }

    /// 去掉空白与开头的「第9章 / 第九回」这类编号，只留标题本身。
    static func bareTitle(_ text: String) -> String {
        // 本模块有个「小说角色」叫 Character，这里一律用全名拼字符串
        let compact = String(text.filter { !$0.isWhitespace })
        let pattern = "^第[0-9零〇一二三四五六七八九十百千两]{1,8}[章节回卷篇]"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return compact }
        return regex.stringByReplacingMatches(
            in: compact,
            range: NSRange(compact.startIndex..., in: compact),
            withTemplate: ""
        )
    }

    /// 段与段之间。原来是每句之间都留 0.8 字，一段读起来是断开的好几条。
    static func paragraphGap(size: CGFloat) -> CGFloat {
        size * 0.35
    }

    /// 该句前面额外留多少白。段首才留；本页第一句不留（页边距已经给了空隙）。
    /// 渲染和测量必须走这一个函数，否则页高算错。
    static func gap(before sentence: Sentence, startsPage: Bool, size: CGFloat) -> CGFloat {
        if startsPage || !sentence.startsParagraph {
            return 0
        }
        return paragraphGap(size: size)
    }

    static func labelSize(size: CGFloat) -> CGFloat {
        size * 0.72
    }

    static func labelHeight(size: CGFloat) -> CGFloat {
        size * 1.1
    }

    static let horizontalMargin: CGFloat = 22
    static let verticalMargin: CGFloat = 18

    /// 该句要不要单独占一行角色名。只取决于「LLM 有没有认出说话人」，
    /// 不能掺进 audioURL 之类的流式状态：那样音频一到齐，整页高度就变了，
    /// 分页结果却还没重算。
    static func showsLabel(for sentence: Sentence) -> Bool {
        sentence.speaker == .character && sentence.characterName != nil
    }
}

struct PageLayout: Equatable {

    /// `pages[p]` = 第 p 页承载的句子在 `chapter.sentences` 里的下标。
    /// 用数组下标而不是 `Sentence.index`：PlayerManager 也是按数组下标取句子的，
    /// 两边口径一致才不会点到A句播B句。
    let pages: [[Int]]

    let bodySize: CGFloat

    var pageCount: Int { pages.count }

    static let placeholder = PageLayout(pages: [[]], bodySize: 19)

    /// 该句落在第几页。句子比页数「超范围」时（比如刚重排、或播放已推进到
    /// 未渲染的句子）返回最后一页，而不是崩掉。
    func page(containing sentence: Int) -> Int {
        var last = 0
        for (index, page) in pages.enumerated() {
            if let first = page.first, sentence < first {
                return max(index - 1, 0)
            }
            last = index
        }
        return last
    }

    // MARK: - Paginate

    static func paginate(
        _ sentences: [Sentence],
        in area: CGSize,
        scale: Double,
        chapterTitle: String
    ) -> PageLayout {

        guard area.width > 40, area.height > 40 else {
            return placeholder
        }

        let body = ReaderTypography.bodySize(scale: scale)
        let font = UIFont.systemFont(ofSize: body)

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = ReaderTypography.lineSpacing(size: body)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: paragraph,
        ]

        let contentWidth = max(
            area.width - ReaderTypography.horizontalMargin * 2,
            40
        )
        // 量高用的是 CoreText 的 boundingRect，SwiftUI 的 Text 行高由字体度量
        // 自己算，两者差几个百分点。留 5% 余量，把误差固定朝安全方向偏：
        // 宁可页尾略空，也不要字溢到下一页去（那只能靠滚动兜底）。
        let usableHeight = max(
            (area.height - ReaderTypography.verticalMargin * 2) * 0.95,
            body * 3
        )

        var pages: [[Int]] = []
        var current: [Int] = []
        var used: CGFloat = 0

        for (position, sentence) in sentences.enumerated() {

            // 段首缩进是字符串里的两个全角空格，不改变可用宽度：每句都按整幅量，
            // 折行位置由排版引擎算，和渲染端喂的字符串完全一致。
            let bounds = NSAttributedString(
                string: ReaderTypography.displayText(sentence, chapterTitle: chapterTitle),
                attributes: attributes
            ).boundingRect(
                with: CGSize(width: contentWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil
            )

            func blockHeight(startsPage: Bool) -> CGFloat {
                var height = ceil(bounds.height)
                height += ReaderTypography.gap(
                    before: sentence,
                    startsPage: startsPage,
                    size: body
                )
                if ReaderTypography.showsLabel(for: sentence) {
                    height += ReaderTypography.labelHeight(size: body)
                }
                return height
            }

            var height = blockHeight(startsPage: current.isEmpty)

            // 装不下就另起一页。整页装不下一句时让它独占一页：
            // 宁可溢出，也不能反复往空页里塞同一句（那会死循环）。
            if !current.isEmpty, used + height > usableHeight {
                pages.append(current)
                current = []
                used = 0
                // 换页之后它成了本页第一句，段距不再吃
                height = blockHeight(startsPage: true)
            }

            current.append(position)
            used += height
        }

        if !current.isEmpty {
            pages.append(current)
        }
        if pages.isEmpty {
            pages.append([])
        }

        return PageLayout(pages: pages, bodySize: body)
    }
}
