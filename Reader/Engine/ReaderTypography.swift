//
//  ReaderTypography.swift
//  Reader
//
//  排版内核之一：字号、行距、段距、页边距。只有数值和文本判定，不画任何东西。
//

import Foundation

/// 排版的唯一口径。正文渲染和分页测量必须共用这一组常量——
/// 两边各写一份的话，量出来 30 行、实际 31 行，字就会溢到下一页去。
enum ReaderTypography {

    static func bodySize(scale: Double) -> CGFloat {
        19 * CGFloat(scale)
    }

    /// 行距。`lineScale` 是用户在 Aa 面板里调的那一档：正文要能自己调疏密，
    /// 但必须和分页测量共用同一个数，否则量出来 30 行、实际 28 行，字溢到下一页。
    static func lineSpacing(size: CGFloat, scale: Double = 1.0) -> CGFloat {
        size * 0.42 * CGFloat(scale)
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

    /// 段与段之间**额外**多留的白。原来是每句之间都留 0.8 字，一段读起来是断开的好几条。
    static func paragraphGap(size: CGFloat) -> CGFloat {
        size * 0.35
    }

    static let horizontalMargin: CGFloat = 22
    static let verticalMargin: CGFloat = 18
}