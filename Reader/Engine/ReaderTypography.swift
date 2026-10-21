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

    // MARK: - 边距

    /// 设计边距：纸上那一块白**至少**让开这么多。纸上一条边距实际让多少问 `sideMargin`。
    static let horizontalMargin: CGFloat = 22
    static let verticalMargin: CGFloat = 18

    /// 一张纸左右**各**让开的宽：设计边距 + 一行让出的那一个字，摊成两半。
    ///
    /// 为什么不直接是 `horizontalMargin` 那一个数（#168）：读者要的「每行少一个字」得按
    /// 排版引擎量出来的推进抽（`ReaderBlock.letterWidth`），而抽掉的宽不许变成行尾的空洞，
    /// 要还给两条边距。这里只写上「一半」这一笔账：`columns` 栏就是 `columns` 行各少一个，
    /// 从版心抽走的总宽是一个字 × 栏数，对半摊到左右两条外边距，所以每边各多半个字 × 栏数。
    ///
    /// 恒对称（左右是同一个数），所以正文永远落在纸的正中。代数和闭合：
    /// `2 × sideMargin + 栏宽 × 栏数 + 栏空 × (栏数 − 1) = 纸宽`。
    ///
    /// 单栏和两栏的两个外边距本来就不该相等（22 + 半个字 vs 22 + 一个字）：两栏那张纸
    /// 一行要少两个字，宽是从版心里抽的，不是从纸的四边上凭空抠的。
    static func sideMargin(letter: CGFloat, columns: Int) -> CGFloat {
        horizontalMargin + letter * CGFloat(max(columns, 1)) / 2
    }

    /// 版心宽：纸上正文那一整块的宽，已经让开两条 `sideMargin`。
    ///
    /// 分页量高和渲染排栏都问这一个数。下限 40 是兜「纸窄过两条边距」的越界输入
    /// （分屏拖到最窄、转场中间那一帧），那种纸上排不出字，但不能给负宽。
    static func contentWidth(areaWidth: CGFloat, letter: CGFloat, columns: Int) -> CGFloat {
        max(
            40,
            areaWidth - sideMargin(letter: letter, columns: columns) * 2
        )
    }

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

    /// 一栏的宽。`columns` 栏加 `columns - 1` 条栏空正好铺满 `contentWidth`——
    /// 分栏切的是版心里面，不是纸的四边；两条外边距由 `sideMargin` 按栏数一起给。
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
    ///
    /// 判据问的是**摊成两栏之后**那一栏有多宽，也就是带着两栏那一条 `sideMargin` 账一起判
    /// （#168：两栏的纸每边各让一个字，不是 22pt）。拿收窄前的宽判会在临界纸宽上多开一栏，
    /// 而那一栏实际只剩 15 个字——正撞在 `minColumnLetters` 想挡住的那一档上。
    /// 先假设两栏、不合格退回单栏，所以这是一次定点，不用迭代。
    static func columnCount(areaWidth: CGFloat, body: CGFloat, letter: CGFloat) -> Int {
        columnWidth(
            contentWidth: contentWidth(areaWidth: areaWidth, letter: letter, columns: 2),
            columns: 2,
            body: body
        ) >= body * CGFloat(minColumnLetters) ? 2 : 1
    }

    // MARK: - 图

    /// 一张图在纸上占多大的框。**分页量和渲染画都问这一个函数**：两边各算一遍就是
    /// 「页里给图留了 200pt、纸上画了 240pt」，多出来那 40pt 会从页尾漏出去（页尾那条红线）。
    ///
    /// 两条上限各治一件事：
    ///
    /// 1. **宽**：不超过栏宽，也不按原图放大。`pixelWidth / 2` 是「视网膜屏上 1:1 的边长」——
    ///    源文件的像素按 2x 存，所以原图 980px 在 349pt 的栏里正好铺满；而一张 200px 的小图
    ///    只给 100pt，剩下那半截宽留着。拉满栏是给模糊让路：把小图放大到两倍，纸上就是一团马赛克。
    /// 2. **高**：不超过 `usableHeight × 0.7`，超了就**等比**缩（宽跟着一起缩，不裁切）。
    ///    留 30% 是给图注和它上面那一句的：一张图占满一整页时，读者翻页看见的是「一页纸、
    ///    一行字」，而图注被挤到下一页去——图和自己的图注分家比图小一点严重得多。
    ///
    /// 尺寸不知道（`pixelWidth/Height` 为 0）就不画：等比缩放没有基准，硬给一个方框只会把
    /// 排版撑成一块看不出所以然的白。解析端本来也已经在 `ChapterImage.minimumImageEdge` 那挡掉了这种。
    static func imageFrame(
        _ image: ChapterImage,
        columnWidth: CGFloat,
        usableHeight: CGFloat
    ) -> CGSize {

        guard image.pixelWidth > 0, image.pixelHeight > 0 else {
            return .zero
        }

        let aspect = CGFloat(image.pixelWidth) / CGFloat(image.pixelHeight)

        var width = min(columnWidth, CGFloat(image.pixelWidth) / 2)
        var height = width / aspect

        let cap = usableHeight * imageMaxHeightRatio
        if height > cap {
            // 等比缩：高顶到上限，宽跟着走。缩出来的宽必然还 ≤ 原来那个宽，不会再撞栏。
            height = cap
            width = cap * aspect
        }

        return CGSize(width: width, height: height)
    }

    /// 一张图最多占掉这一栏可用高的多少。见 `imageFrame` 第 2 条。
    static let imageMaxHeightRatio: CGFloat = 0.7

    // MARK: - 双页

    /// 一张纸摊成左右两面时，**每一面**一行至少要容得下这么多个字才许摊。
    ///
    /// 为什么按「摊开之后每一面一行的字数」判，而不是按设备型号、不按 idiom、也不按一条
    /// 屏幕宽度：双页要的观感是摊开一本书，而它的下限其实是可读性。摊开之后每一面如果比
    /// 手机上那一页还窄，读者就是在平板上看两页手机——中缝两边各剩十几个字，行尾那点洞
    /// 两端对齐补不平（`minColumnLetters` 要挡的就是那一档）。手机那一页现在排 17 个字
    /// （393pt 的纸），所以门槛定在「每一面都比手机那一页宽一截」：24 个字。
    ///
    /// 这条式子里只有「纸有多宽多高」和「一个字有多宽」，宽度那一条跟着字号走，所以大字号
    /// 自动退回单页（1.5× 那一档要 1500pt 上下的纸，没有机器够得着），分屏、台前调度、
    /// Mac 上那个可拉的窗口也自动按实际尺寸决定——不需要在任何地方判断「这是什么设备」
    /// （判据合起来在 `spreadAllowed`，形状那一条见它的第二段）。
    static let minSpreadLetters = 24

    /// 双页时一面有多宽。UIKit 在 `.mid` 那一档是把 `pager.view.bounds` 从中缝对半切给
    /// 两面纸（探针量过：1376 的纸给出 0…688 与 688…1376 两面），所以这里就是它的一半。
    ///
    /// **刻意不取整**：分页量的宽和那一面上 hosting 视图实测到的宽必须是同一个数，
    /// 差半pt 就是「量的排得下、纸上掉一行」（`renderGuard` 那笔账只有 0.5pt）。
    static func leafWidth(areaWidth: CGFloat) -> CGFloat {
        areaWidth / 2
    }

    /// 这张纸摊不摊得开两面。和 `columnCount` 同一个套路：先按摊开算，不合格就是不合格，
    /// 不用迭代。
    ///
    /// `letter` 必须是排版引擎量出来的实际推进宽（`ReaderBlock.letterWidth`），不是字号：
    /// 「一行几个字」只能按真正的推进数（19pt 在探针那台机器上实测 19.36pt）。
    ///
    /// 边距按**单栏**那一面算：摊开之后一面剩下的宽已经不容第二栏（两栏的条件
    /// `columnCount` 会在那一面的宽上再问一遍，量的是摊开后的纸），所以这里欠的
    /// 就是 `columns: 1` 那一份账——两条边距各 22 + 半个字。
    ///
    /// 两道闸门，都在问几何，没有一处问机型：
    ///
    /// 1. **一面容不容得下 `minSpreadLetters` 个字**——见上面那条。
    /// 2. **两面各自还是不是一页书的形状**（高 ≥ 宽）。为什么宽度那道闸不够：手机横过来
    ///    那张纸是 852×297，一刀两半得到两片 426×297 的**横条**——扁过任何一本书，那是
    ///    一条被腰斩的字幕，不是摊开的书。字号调到最小那档（0.7×）时那片横条每面能塞
    ///    27 个字，只按宽度判就会在手机上开双页，而要求四是「iPhone 保持单页」。
    ///    形状这道闸不认机型，任何又扁又宽的可拉窗口都走同一条式子；而真机摊得开的那几档
    ///    （iPad 11 横 597×738、iPad Pro 13 横 683×928、iPad mini 横 566×648）
    ///    高都大于宽，一条都没被它挡掉。
    static func spreadAllowed(
        areaWidth: CGFloat,
        areaHeight: CGFloat,
        letter: CGFloat
    ) -> Bool {
        let leaf = leafWidth(areaWidth: areaWidth)
        guard leaf <= areaHeight else { return false }
        return leaf
            - sideMargin(letter: letter, columns: 1) * 2
            >= letter * CGFloat(minSpreadLetters)
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