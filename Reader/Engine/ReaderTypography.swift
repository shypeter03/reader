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

    // MARK: - 分栏

    /// 一栏至少要容得下这么多个字，才许再开第二栏。
    ///
    /// 为什么按宽度判、不按 `userInterfaceIdiom` / sizeClass：iPad 的分屏、台前调度、Mac 上
    /// 那个可拉的窗口都是「同一个 App、各种各样的宽」，而真正会把读者绊倒的是**栏太窄**——
    /// 窄到一行只剩十来个字，两端对齐摊到 `justifyGapCap` 也补不平行尾那半格，纸上就是
    /// 「每行右边都在抖」。宽度是唯一真的判据，而且分页端和渲染端问的是同一条式子。
    static let minColumnLetters = 16

    /// 栏与栏之间的空。
    ///
    /// 给一栏半的字宽：两栏挨得太近，眼睛换栏时会串行；再宽就是版心里挖走一条大沟，
    /// 而分栏省下来的字宽本来就不多。
    static func columnGutter(body: CGFloat) -> CGFloat {
        body * 1.5
    }

    /// 一栏的宽。`columns` 栏加 `columns - 1` 条栏空正好铺满 `contentWidth`，
    /// 所以 `horizontalMargin` 那 22pt 一点没动——分栏切的是版心里面，不是纸的四边。
    static func columnWidth(
        contentWidth: CGFloat,
        columns: Int,
        body: CGFloat
    ) -> CGFloat {
        max(
            40,
            (contentWidth - columnGutter(body: body) * CGFloat(max(columns - 1, 0)))
                / CGFloat(max(columns, 1))
        )
    }

    /// 这一张纸摊成几栏。刻意封顶 2：要的是「从中间分成两边」，三栏在横屏上是把一页切三片，
    /// 读者的眼睛得先跨过一整栏的空白才接着读，那不是读书。
    static func columnCount(contentWidth: CGFloat, body: CGFloat) -> Int {
        columnWidth(contentWidth: contentWidth, columns: 2, body: body)
            >= body * CGFloat(minColumnLetters) ? 2 : 1
    }

    /// 一块字落纸占的高，比 `ReaderBlock.metrics` 量到的最多多出这么多（点）。
    ///
    /// 为什么要预留：每一块是自己一个 `Text`，它要把这一格抬到**屏幕像素网格**上才落纸，
    /// 于是每块都得往上圆一点。逐块量过（`.probe/main-render-check.swift`，266 块）：
    /// 落纸高 − 量到高 全在 +0.0 ~ +0.4，**一个负的都没有**（@3x 一格 0.33pt、@2x 一格 0.5pt）。
    /// 不留这一笔就是「量出来 30 行、纸上 31 行」，而纸不滚动（127 已去掉页内 ScrollView），
    /// 多出来的那一行读者永远看不见。
    ///
    /// 为什么是**加一个常数**而不是把整块 `ceil`：常数对行距严格线性（斜率不变、也不出台阶），
    /// 分页收尾把余量按缝摊进行距（`PageLayout.stretch(for:)`）才咬得住。从前这里是逐块
    /// `ceil`，那个取整台阶跟着行距一起动——一页 6 块偏 +1.6pt、13 块偏 +5.3pt，偏出去的
    /// 正好是「量着排得下、纸上掉一行」的那一行。
    static let renderGuard: CGFloat = 0.5
}