//
//  PageLayout.swift
//  Reader
//
//  书本式分页：同段句子并成一块，按块量高，再按页的可用高度贪心装页。
//

import SwiftUI

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

/// 一块 = 同一段里连续句子并起来的渲染单元。分段流动的落地方式：
/// 一块一个 `Text`，句与句之间不再硬换行。
///
/// 为什么要并：以前一句一个 `Text`，于是①上一句剩下的小半行整片空白留着
/// （截图里「朱紫的贵人，」后面直接空了），②`lineSpacing` 只作用于一个 `Text` 内部，
/// 句内行疏、句间行密，看着就是行距不一致。并成一块之后这两个都是同一件事：
/// 一段就是一段，行距从头到尾一个值。
///
/// 渲染和分页共用这里的 `groups`/`runs`/尺寸：两边各自拼字符串的话，
/// 量的是一版、排的是一版，页高就会一路偏下去。
enum ReaderBlock {

    /// 零宽「不许在这儿断行」。只出现在测量端，见 `height` 的说明。
    private static let noBreak = "\u{2060}"

    /// 不许顶到行首的收尾标点。本模块有个「小说角色」叫 `Character`，所以一律写 `Swift.Character`。
    private static let noLineHead: Set<Swift.Character> = [
        "，", "。", "、", "；", "：", "？", "！", "）", "》", "」", "』", "】",
        "…", "‥", "·", "”", "’", "ー", "～", "％",
        ",", ".", "!", "?", ";", ":", ")", "]", "}", "%", "'", "\"",
    ]

    /// 不许孤在行尾的起始标点。
    private static let noLineTail: Set<Swift.Character> = [
        "（", "《", "「", "『", "【", "“", "‘", "(", "[", "{",
    ]

    /// 摊平后的一片：同一个 run 里、后面补着同一个宽度的连续字符。
    ///
    /// 为什么摊到「片」而不按 run 交出去：断点（`\n`）和行尾补齐都落在 run 内部
    /// （一句好长，中间断好几行），按 run 交就表达不了。渲染端和测量端都只从 `layout` 取片，
    /// 断点与补齐因此只有一份口径。
    struct Piece {

        /// 属于 `runs` 里的哪一个。字色、字号、link，以及「run 之间插 `noBreak`」都按它还原。
        let runIndex: Int

        var text: String

        /// 这片里每个字**后面**要补多宽（两端对齐摊开的字距）。0 = 不补。
        ///
        /// 行末那个字永远是独立一片、`kern` 为 0：把宽度补在行末字后面等于给这一行加了个
        /// 看不见的尾巴，TextKit 会按更宽判；判成装不下，它就自己再折一次，纸上多一行。
        let kern: CGFloat
    }

    /// 一块 → 要排的片：自己写硬换行，再把每行行尾的洞摊进字距（两端对齐）。
    ///
    /// **为什么要自己补**：真机截图（绍宋 第五十三章 9/10）逐行量过，左边界齐在 68~75px、
    /// 满行右边界 1107px，可同一段里的短行停在 973/1040/1066——最多空 2 格，读者看见的就是
    /// 「右边每行边距不一致」。像素取证的结论和我们最初的猜测相反：iOS 对中文本来就**逐字**
    /// 贪心断行，我们算的落点和引擎自己的落点一字不差（`.probe/flow-gap-probe.swift`，
    /// 21.5pt 与 19pt 的段各量一遍，断点全同）；那 2 格的洞是**标点禁则**留下的——
    /// 「，。）」这类不许顶行首，于是一整簇（「的……」三个字）得整体挪到下一行，
    /// 行尾就空出一截。
    ///
    /// 洞断不掉（把收尾标点甩在行尾是排版事故），只剩摊平这一条路：书上的中文就是两端对齐的。
    ///
    /// 三条约束：
    /// ① 只补**我们自己断出来的**那些行。段末那一行、章标题那一行一概不补——
    ///    那是天然的短行，拉开就成了字缝能塞进手指的花名册。
    /// ② 补到 `width - 0.5`，不补满分；补完这一行还要按落纸行回炉验一次（`lineBreaks` 里
    ///    那道「折半重试」的闸）。断点按 `width` 判定，补齐后正好顶满的一行在浮点上没人担保
    ///    还装得下；一旦判成装不下，引擎自己再折，量的与排的就此分家。
    /// ③ 每格最多补 0.26 字宽。洞再大也不硬拉，拉完那一行像被风吹散。
    ///
    /// **先试死的路**（模拟器像素实测，`.probe/justify-probe.swift`）：`.multilineTextAlignment(.justified)`
    /// 确实拉平（段3@21.5 的行尾极差 45.7pt→21.0pt），但它按自己的算法折行，每段比我们的断点多出一行，
    /// 而纸不滚动（127 已去掉页内 ScrollView），多出的那一行直接看不见。自己补字距没有这一笔账：
    /// 行数一根手指都没碰，探针 C 段逐块对过，渲染高 − 测量高 只有 0 ~ −0.7pt。
    ///
    /// 字宽取排版引擎自己算的推进（`penPositions`，和 `height` 同一个 TextKit），
    /// 不按「汉字=1em」估——标点和数字各有各的宽。断处守三条：收尾标点不顶行首、
    /// 起始标点不孤行尾、拉丁词和数字不劈开。
    static func layout(
        runs: [Run],
        width: CGFloat,
        body: CGFloat
    ) -> [Piece] {

        var letters: [Swift.Character] = []
        var owners: [Int] = []

        for (index, run) in runs.enumerated() {
            for letter in run.text {
                letters.append(letter)
                owners.append(index)
            }
        }

        var cutSet = Set<Int>()
        var stretch = [CGFloat](repeating: 0, count: letters.count)

        if width > 40, letters.count > 1 {
            self.lineBreaks(
                of: letters,
                owners: owners,
                runs: runs,
                body: body,
                width: width,
                cuts: &cutSet,
                stretch: &stretch
            )
        }

        var pieces: [Piece] = []

        for (position, letter) in letters.enumerated() {
            let owner = owners[position]

            if cutSet.contains(position) {
                appendPiece("\n", owner: owner, kern: 0, to: &pieces)
            }

            appendPiece(letter, owner: owner, kern: stretch[position], to: &pieces)
        }

        return pieces
    }

    /// 相邻的「同源同宽」的字并成一片。别一个字一个 `NSAttributedString`：一块几千字，
    /// 逐字建串要把分页的量高成本翻几十倍，点开一章那 1s 预算就没了。
    private static func appendPiece(
        _ letter: Swift.Character,
        owner: Int,
        kern: CGFloat,
        to pieces: inout [Piece]
    ) {
        if let last = pieces.last, last.runIndex == owner, last.kern == kern {
            pieces[pieces.count - 1].text.append(letter)
        } else {
            pieces.append(Piece(runIndex: owner, text: String(letter), kern: kern))
        }
    }

    /// 贪心断行，顺带算出每一行要补多少。写在一个函数里是因为「补多少」用的就是断行时的
    /// 那串笔位；拆成两处得把 `pen` 再问一遍（那是整块摊进超大容器逐字形问位置，不便宜）。
    private static func lineBreaks(
        of letters: [Swift.Character],
        owners: [Int],
        runs: [Run],
        body: CGFloat,
        width: CGFloat,
        cuts: inout Set<Int>,
        stretch: inout [CGFloat]
    ) {

        let pen = self.penPositions(of: letters, runs: runs, body: body)

        // 一行放到「正好等于版心」为止。这里不减余量：量的这一笔和 `height` 折行用的是
        // 同一个 TextKit，两个数本来就该一致；留余量的代价实测很贵——字号 21.5 时第 16 个字
        // 的笔位差是 348.9pt，版心 349pt，减掉 0.5pt 就把它判成装不下，一整行只排 15 个字，
        // 行尾空出整整一格（真机截图上「右边每行边距不一致」就是这个）。
        let limit = width

        var lineStart = 0
        var candidate = -1
        var index = 0
        var broken: [(start: Int, end: Int)] = []

        while index < letters.count {

            if letters[index] == "\n" {
                index += 1
                lineStart = index
                candidate = -1
                continue
            }

            if index > lineStart,
               canBreak(after: letters[index - 1], before: letters[index]) {
                candidate = index
            }

            if pen[index + 1] - pen[lineStart] > limit,
               index > lineStart {

                // 装不下了：退到最近一个允许断的地方；一个都没有（超长拉丁词）就断在这里。
                let cut = candidate > lineStart ? candidate : index
                cuts.insert(cut)
                broken.append((lineStart, cut))
                lineStart = cut
                candidate = -1
                continue
            }

            index += 1
        }

        // 把行尾的洞摊进这一行的字距。洞是禁则挪走一整簇留下的，见 `layout` 的说明。
        let target = width - 0.5
        let perGapCap = body * 0.26

        for line in broken {

            let gaps = line.end - line.start - 1
            guard gaps >= 1 else { continue }

            let deficit = target - (pen[line.end] - pen[line.start])
            guard deficit > 0 else { continue }

            var value = min(deficit / CGFloat(gaps), perGapCap)
            var chosen: CGFloat = 0

            // 补完要回炉按落纸行验一次：这一行在真版心里仍只占一行才要，占两行就折半重来；
            // 三次都不行这行干脆不补。折半而不是换算法——洞的八成来自禁则，补多少都是补，
            // 补不进总比补出一片对不上的行强。
            for _ in 0..<3 {
                guard value > 0.05 else { break }

                let rows = self.stretchedLineRects(
                    of: letters,
                    owners: owners,
                    runs: runs,
                    body: body,
                    width: width,
                    start: line.start,
                    end: line.end,
                    kern: value
                )

                if rows.count == 1 {
                    chosen = value
                    break
                }

                value /= 2
            }

            guard chosen > 0 else { continue }

            for position in line.start..<line.end - 1 {
                stretch[position] = chosen
            }
        }
    }

    /// 补了字距的这一行，在真版心里落纸要几行、每行多宽——走 `lineRects`，和 `height`
    /// 同一个排版器，所以它放行的一行，`height` 那边也就是一行。探针要用同一个判据取证，
    /// 所以它不是 private。
    ///
    /// 为什么不能拿 `pen` 的推进加「格数 × 字距」直接算：`.kern` 会把 TextKit 的中文标点
    /// 压缩关掉，一行里只要有「“」（」这类标点，它们就各自胖回将近半个字宽——按推进判
    /// 「装得下」的那一行，落笔时未必装得下。落笔比推进宽的那点差，多出来的就是引擎自己
    /// 折的一行：纸上多一行，`height` 也跟着多一行，页尾就此错位。
    /// 量级见探针 A 段的「拒」列（`.probe/justify-probe.swift`）：段4@21.5 有一行推进 316.9pt，
    /// 每格只补 0.01pt，落笔就跳到 350.1pt——版心才 349pt，这一档直接被闸门否掉。
    static func stretchedLineRects(
        of letters: [Swift.Character],
        owners: [Int],
        runs: [Run],
        body: CGFloat,
        width: CGFloat,
        start: Int,
        end: Int,
        kern: CGFloat
    ) -> [(width: CGFloat, height: CGFloat)] {
        lineRects(
            stretchedLineString(
                of: letters,
                owners: owners,
                runs: runs,
                body: body,
                start: start,
                end: end,
                kern: kern
            ),
            width: width
        )
    }

    /// 把一行字按它各自 run 的字体拼成串，`[start, end - 1)` 统一补 `kern`。
    /// 单独开出来给探针用：取证要「这一行补了字距长什么样」，不许再拼一条自己的。
    static func stretchedLineString(
        of letters: [Swift.Character],
        owners: [Int],
        runs: [Run],
        body: CGFloat,
        start: Int,
        end: Int,
        kern: CGFloat
    ) -> NSMutableAttributedString {

        let string = NSMutableAttributedString()

        // 行末那个字不补（补了它就在行尾多出一格空气）；`kern` 为 0 时整行都不加属性，
        // 免得一记 `.kern: 0` 把标点压缩判成「非默认排版」而悄悄改掉行宽。
        func wantsKern(_ position: Int) -> Bool {
            position < end - 1 && kern > 0
        }

        var index = start

        // 按「同一个 run + 同一片字距」成段地拼，别一个字建一个 `NSAttributedString`：
        // 整章几千行，逐字建串要把这点验证翻成主角。
        while index < end {

            let owner = owners[index]
            let kerned = wantsKern(index)

            var text = ""
            var next = index

            while next < end, owners[next] == owner, wantsKern(next) == kerned {
                text.append(letters[next])
                next += 1
            }

            string.append(
                NSAttributedString(
                    string: text,
                    attributes: kerned
                        ? [.font: uiFont(runs[owner], body: body), .kern: kern]
                        : [.font: uiFont(runs[owner], body: body)]
                )
            )

            index = next
        }

        return string
    }

    /// 这两个字之间让不让断。
    private static func canBreak(
        after previous: Swift.Character,
        before next: Swift.Character
    ) -> Bool {

        if previous == "\n" || next == "\n" { return false }

        // 空格自己不顶行首，断点只放在它后面。
        if next == " " || next == "\u{3000}" { return false }
        if previous == " " || previous == "\t" { return true }

        if noLineHead.contains(next) || noLineTail.contains(previous) { return false }

        // 汉字/全角符前面逐字可断；汉字后面接拉丁也给一个断点，否则整词挤下来一行。
        return isBreakTarget(next) || isBreakTarget(previous)
    }

    /// 每个字符的起笔位置（累加 x，多一位收尾）：`pen[i+1] - pen[j]` 就是「从第 j 个字排到
    /// 第 i 个字」占多宽。
    ///
    /// 为什么不能用 CoreText 的字形推进：那条链和 `height` 不是同一个排版器（`height` 走
    /// TextKit1 的行框，就是这里 `NSLayoutManager` 的同一条），
    /// 对中文标点（尤其「……」这种连排）给的宽度差到 3%。真机化出来的后果不是「略偏」而是
    /// 整行崩掉——按 CoreText 判「装得下」的那一行，TextKit/SwiftUI 落笔时装不下，于是它自己
    /// 再折一次，纸上凭空多出一个只有一两个字的孤行（模拟器像素量到：段3 第 2 行右界 37pt）。
    /// 断点必须和量高用同一个引擎，这一条没有商量余地。
    ///
    /// 做法：整块摊进一个不可能折行的宽容器，逐字符问笔位。两个必要的手脚——
    ///   ① 串里的 `\n` 换成一个全角空格（`height` 那边它照样换行，这里只是不让它把容器切断，
    ///      否则后面的字符位置全归零）；
    ///   ② 结尾补一个字当哨兵，最后一个真字的收笔位置才问得到。
    private static func penPositions(
        of letters: [Swift.Character],
        runs: [Run],
        body: CGFloat
    ) -> [CGFloat] {

        let storage = NSMutableAttributedString()

        for run in runs {
            storage.append(
                NSAttributedString(
                    string: String(
                        run.text.map { $0 == "\n" ? "\u{3000}" : $0 }
                    ),
                    attributes: [.font: uiFont(run, body: body)]
                )
            )
        }

        storage.append(
            NSAttributedString(
                string: "一",
                attributes: [.font: uiFont(runs[runs.count - 1], body: body)]
            )
        )

        let textStorage = NSTextStorage(attributedString: storage)
        let manager = NSLayoutManager()
        textStorage.addLayoutManager(manager)

        let container = NSTextContainer(
            size: CGSize(width: 1_000_000, height: 1_000_000)
        )
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        manager.ensureLayout(for: container)

        var pen = [CGFloat](
            repeating: 0,
            count: letters.count + 1
        )

        for index in 0...letters.count {
            pen[index] = manager.location(
                forGlyphAt: manager.glyphIndexForCharacter(at: index)
            ).x
        }

        return pen
    }

    /// 这个字符算不算「汉字/全角」这一类。ASCII 一律不算，拉丁词整块交给引擎。
    private static func isBreakTarget(_ character: Swift.Character) -> Bool {

        let scalars = character.unicodeScalars

        guard scalars.count == 1, let scalar = scalars.first else { return false }

        switch scalar.value {
        case 0x2018, 0x2019, 0x201C, 0x201D, 0x2026, 0x00B7:
            return true
        default:
            break
        }

        switch scalar.value {
        case 0x3000...0x303F,   // CJK 标点与空白（、。《》「」【】　）
            0x3400...0x4DBF,    // 扩展 A
            0x4E00...0x9FFF,    // 基本汉字
            0xF900...0xFAFF,    // 兼容汉字
            0xFF00...0xFFEF:    // 全角形式
            return true
        default:
            return false
        }
    }

    enum RunKind {
        case body
        case heading
    }

    struct Run {

        /// 这一片段属于哪一句。点某一句时靠它把高亮落到正确的句子上。
        let position: Int

        let text: String

        let kind: RunKind
    }

    /// 一片字 → 块。
    ///
    /// 断块的两条规则：新段落开头、章标题之后。
    /// 分页端和渲染端都调这一个函数，所以「一页里的块」完全由 `pages: [[PageSlice]]` 决定，
    /// 不需要另存一份块结构。
    ///
    /// 页尾切下来的后半截（`continues`）永远是一片自成一块：它上面那半截在上一页，
    /// 这一页它就是开头，既不该再吃段前白，也不该被当成新段落断开。
    static func groups(
        in slices: [PageSlice],
        sentences: [Sentence],
        chapterTitle: String
    ) -> [[PageSlice]] {

        var groups: [[PageSlice]] = []

        var previousWasHeading = false

        // 换章那一瞬可能还拿着上一章算出来的页码，越界的下标先丢掉，别在这儿崩。
        for slice in slices where sentences.indices.contains(slice.position) {

            let sentence = sentences[slice.position]

            let breaks = groups.isEmpty
                || previousWasHeading
                || (!slice.continues && sentence.startsParagraph)

            previousWasHeading = !slice.continues
                && ReaderTypography.isChapterHeading(
                    sentence,
                    chapterTitle: chapterTitle
                )

            if breaks {
                groups.append([slice])
            } else {
                groups[groups.count - 1].append(slice)
            }
        }

        return groups
    }

    /// 一块要排的片段：一句一片，段首缩进已经在 `PageSlice.text` 里的那两个全角空格上。
    ///
    /// 分页按「句」装，所以一片就是一句，不再往句子上挂别的东西（从前那句首会多顶一行角色名，
    /// 于是「同一段里莫名空出一块」和「名字根本不是名字」两类事故都从那里来。对白靠引号认，
    /// 说话人只留给语音用）。
    static func runs(
        for group: [PageSlice],
        sentences: [Sentence],
        chapterTitle: String
    ) -> [Run] {

        group.map { slice in

            Run(
                position: slice.position,
                text: slice.text,
                kind: !slice.continues
                    && ReaderTypography.isChapterHeading(
                        sentences[slice.position],
                        chapterTitle: chapterTitle
                    ) ? .heading : .body
            )
        }
    }

    /// 字重的唯一出处。UIKit 和 SwiftUI 两边都从这儿换算，别各写一份。
    static func weight(_ run: Run) -> RunWeight {
        switch run.kind {
        case .heading: return .semibold
        case .body: return .regular
        }
    }

    enum RunWeight {
        case regular
        case semibold
    }

    /// 字号只有正文一个值（章标题靠字重和居中区分，不放大：放大了行高就得再算一份）。
    static func uiFont(
        _ run: Run,
        body: CGFloat
    ) -> UIFont {

        switch weight(run) {
        case .regular: return .systemFont(ofSize: body)
        case .semibold: return .systemFont(ofSize: body, weight: .semibold)
        }
    }

    static func font(
        _ run: Run,
        body: CGFloat
    ) -> Font {

        switch weight(run) {
        case .regular: return .system(size: body)
        case .semibold: return .system(size: body, weight: .semibold)
        }
    }

    /// 这一块前面吃多少段前白。
    ///
    /// 同一段被页边界拆开的后半截不吃（`continues`，它接着上一页排），本页第一块也不吃
    /// （页边距已经给了空隙）。
    ///
    /// **要加上 `lineSpacing` 一起给**：`Text` 的行距只作用在它自己的行与行之间，
    /// 最后一行下面不留；两块之间夹的是 `VStack(spacing: 0)`，所以段间距=这一段 padding，
    /// 而行距=行距+padding。只给 `paragraphGap`（0.35 字）时它比行距（0.42 字）还小，
    /// 真机截图量过：一页 22 行，行顶间距几乎全是 92px，段落边界那一道一点也不更大——
    /// 段与段只看首行缩进能分出来，读者就说「行距和段距不一致」。
    /// 现在段前白 = 行距 + 额外留白，段间那道正好比行内多出一个 `paragraphGap`。
    static func gap(
        first slice: PageSlice,
        firstOnPage: Bool,
        sentences: [Sentence],
        size: CGFloat,
        lineSpacing: CGFloat
    ) -> CGFloat {

        guard !firstOnPage,
              !slice.continues,
              sentences.indices.contains(slice.position),
              sentences[slice.position].startsParagraph
        else { return 0 }

        return lineSpacing + ReaderTypography.paragraphGap(size: size)
    }

    /// 这一块的实测高度。
    ///
    /// 行距走 `paragraphStyle.lineSpacing`：SwiftUI 那边只认 `.lineSpacing` 修饰符，
    /// 串里带的 `paragraphStyle` 它压根不采纳（量过：带与不带的渲染高度一样），
    /// 所以这里加了它也不会和渲染端叠成两倍。
    ///
    /// **句界插 `noBreak`（U+2060）**：渲染端每句是一个带 `link` 的 run，而 SwiftUI
    /// 不肯在两个 link 域之间断行。探针实测（`.probe/split-bias-probe.swift`）：
    /// 「「你看这画。」墨居仁忽然说。」+「韩立抬头，…画了什么。」」在 28.5pt、349pt 版心下
    /// 不带 link 排 3 行（126pt）、带 link 排 4 行（172pt），而在句界插一个零宽 U+2060
    /// 之后两边都变 172——一字不差。CoreText 把 U+2060 当作「此处禁止断行」，正是渲染端
    /// 的行为。不这么做就是「量的比排的矮」：大字号下每页最后可能溢出一行，
    /// 表现是底部少一行、或者最后一行掉到纸外。
    ///
    /// `layout` 摊的那点字距**参与**测量（`.kern` 是串属性，TextKit 认）。它只把行尾的洞
    /// 摊进这一行，每行仍顶到 `width - 0.5` 为止——行数一根手指都没碰，所以高度和从前一样。
    /// 真要让高度动了，那就是页尾溢出，页序得整本重算。
    static func height(
        runs: [Run],
        body: CGFloat,
        lineSpacing: CGFloat,
        width: CGFloat
    ) -> CGFloat {
        ceil(
            lineRects(
                measureString(
                    runs: runs,
                    body: body,
                    lineSpacing: lineSpacing,
                    width: width
                ),
                width: width
            )
            .reduce(0) { total, row in total + row.height }
        )
    }

    /// 这串字在 `width` 宽的纸面上断成了哪几行（每行的用宽与行框高）。
    ///
    /// 为什么不走 `boundingRect`：它报的高和它自己断出的行对不上。同一段带 `.kern` 的字，
    /// 逐行摊开是 3 行、行框高合计 84.0pt（和 SwiftUI 那版的渲染高一字不差），
    /// `boundingRect` 却报 114.6pt——多算了一整行。行框才是排版器真正落纸的东西。
    ///
    /// 容器 `lineFragmentPadding = 0`，和 `penPositions` 同一个数：SwiftUI 的 `Text` 不认
    /// 那 5pt 内边距（像素量过，行末的墨能顶到 347 / 版心 349）。量的、断的、排的必须同宽。
    ///
    /// 行框高里已经含了 `lineSpacing`（除末行），逐行相加就是这一块的总高。
    static func lineRects(
        _ string: NSAttributedString,
        width: CGFloat
    ) -> [(width: CGFloat, height: CGFloat)] {

        let storage = NSTextStorage(attributedString: string)
        let manager = NSLayoutManager()
        storage.addLayoutManager(manager)

        let container = NSTextContainer(
            size: CGSize(width: width, height: .greatestFiniteMagnitude)
        )
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        manager.ensureLayout(for: container)

        var rows: [(width: CGFloat, height: CGFloat)] = []

        manager.enumerateLineFragments(
            forGlyphRange: NSRange(location: 0, length: storage.length)
        ) { rect, used, _, _, _ in
            rows.append((used.width, rect.height))
        }

        return rows
    }

    /// `height` 要量写的那个串：`layout` 的硬换行与字距，加上句界的 `noBreak`。
    ///
    /// 单独开出来是给探针使的——取证时要看 TextKit 在这一串里到底断成了哪几行，
    /// 判据和被量的串必须同一份，探针不许再拼一条自己的。
    static func measureString(
        runs: [Run],
        body: CGFloat,
        lineSpacing: CGFloat,
        width: CGFloat
    ) -> NSMutableAttributedString {

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing

        let string = NSMutableAttributedString()

        var previousRun = -1

        for piece in layout(runs: runs, width: width, body: body) {

            let run = runs[piece.runIndex]

            if piece.runIndex != previousRun {
                if previousRun >= 0 {
                    string.append(
                        NSAttributedString(
                            string: noBreak,
                            attributes: [
                                .font: uiFont(run, body: body),
                                .paragraphStyle: paragraph,
                            ]
                        )
                    )
                }
                previousRun = piece.runIndex
            }

            var attributes: [NSAttributedString.Key: Any] = [
                .font: uiFont(run, body: body),
                .paragraphStyle: paragraph,
            ]

            if piece.kern > 0 { attributes[.kern] = piece.kern }

            string.append(
                NSAttributedString(
                    string: piece.text,
                    attributes: attributes
                )
            )
        }

        return string
    }

    /// 渲染用的串。颜色由调用方逐句给（把上色写进测量端只会让「改了字色页就跳」）。
    ///
    /// `width` 是版心宽，用来算硬换行的落点——**必须和 `height` 拿到的是同一个数**，
    /// 否则量的是一版、排的是一版，页尾就溢出了。
    ///
    /// 每句一个 `link` run 是给点读定位用的。注意副作用：SwiftUI 不肯在两个 link 域
    /// 之间断行，所以「一句能不能和上一句挤在同一行」在这里和测量端必须算同一种——
    /// 测量端靠句界插零宽 U+2060 对齐，见 `height`。
    ///
    /// 每句一个 `link` run 是给点读定位用的：并成一块以后「点到哪一句」不再是哪个
    /// `Text` 被点了，只能靠 run。探针实测：run 上显式给的前景色不会被链接色盖掉，
    /// 也不会画下划线，所以「当前句上色、其余淡一档」照旧成立。
    static func attributedString(
        runs: [Run],
        body: CGFloat,
        width: CGFloat,
        color: (Run) -> Color
    ) -> AttributedString {

        var result = AttributedString()

        for piece in layout(runs: runs, width: width, body: body) {

            let run = runs[piece.runIndex]

            var part = AttributedString(piece.text)

            part.font = font(run, body: body)

            // 两端对齐摊开的那点字距。`layout` 保证每行补到 `width - 0.5` 就收手，
            // 所以补完还是装得下，引擎不会再自己折一次。
            if piece.kern > 0 { part.kern = Double(piece.kern) }

            part[AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self] = color(run)

            part.link = URL(string: "reader://sentence/\(run.position)")

            result.append(part)
        }

        return result
    }
}

/// 阅读主题：底色 + 字色。
///
/// 颜色刻意**不进**分页测量——它一个像素都不影响行高，进去只会让「改了颜色页就跳」
/// 这类bug 有藏身地方。要调疏密走 `ReaderTypography.lineSpacing`，那条才参与。
enum ReaderTheme: String, CaseIterable, Identifiable {

    case paper
    case cream
    case sepia
    case night
    case system

    static let storageKey = "readerTheme"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .paper: return "宣纸"
        case .cream: return "米黄"
        case .sepia: return "羊皮"
        case .night: return "夜间"
        case .system: return "跟随"
        }
    }

    /// 底色的两份 RGB：浅色一套、深色一套。固定档两边给同一个值，只有「跟随」真的分家。
    /// `background`（SwiftUI）和 `uiBackground`（UIKit）都从这里出，
    /// 免得改了纸色忘了卷页那张纸。
    private var backgroundRGB: (
        light: (Double, Double, Double),
        dark: (Double, Double, Double)
    ) {
        switch self {
        case .paper: return ((0.99, 0.99, 0.98), (0.99, 0.99, 0.98))
        case .cream: return ((0.96, 0.94, 0.87), (0.96, 0.94, 0.87))
        case .sepia: return ((0.93, 0.87, 0.76), (0.93, 0.87, 0.76))
        case .night: return ((0.08, 0.08, 0.10), (0.08, 0.08, 0.10))
        case .system: return ((0.99, 0.99, 0.98), (0.07, 0.07, 0.09))
        }
    }

    var background: Color {
        Color(uiColor: uiBackground)
    }

    /// 同一份纸色的 UIColor 版。卷页那层是 UIKit（`UIPageViewController` 和它缓存的
    /// `UIHostingController.view`），只认 UIColor：喂不进 Color，纸就是白的——
    /// 深色模式下翻起页来一张亮纸，正是用户报的那个样子。
    var uiBackground: UIColor {
        let rgb = backgroundRGB
        return UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? rgb.dark : rgb.light
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        }
    }

    var text: Color {
        switch self {
        case .paper: return Color(red: 0.13, green: 0.13, blue: 0.14)
        case .cream: return Color(red: 0.22, green: 0.20, blue: 0.15)
        case .sepia: return Color(red: 0.29, green: 0.22, blue: 0.13)
        case .night: return Color(red: 0.80, green: 0.80, blue: 0.83)
        case .system: return adaptive(
            light: (0.13, 0.13, 0.14),
            dark: (0.85, 0.85, 0.88)
        )
        }
    }

    /// 这一档纸在视觉上属于哪套外观——卷页那层（UIKit）照着它把 traits 钉死。
    ///
    /// 为什么不由系统外观裸决定：`uiBackground` 是动态色，取值要看宿主视图的
    /// traits，而翻页的纸是缓存里的 `UIHostingController`，脱离视图树时系统从浅
    /// 切深它收不到更新——表现就是「底色已经黑了，翻起来那张纸还是亮的」。
    /// 另一层：夜间档配系统浅色时，页眉那些 `.secondary` 语义色会解成深灰，
    /// 落在深纸上就是看不见。固定档自己说死深浅，「跟随」才把决定权交回系统。
    /// 判据和 `backgroundRGB` 同一份：那里只有 `.system` 真的分了 light/dark 两套纸。
    func userInterfaceStyle(
        matching systemStyle: UIUserInterfaceStyle
    ) -> UIUserInterfaceStyle {
        switch self {
        case .paper, .cream, .sepia: return .light
        case .night: return .dark
        case .system: return systemStyle
        }
    }

    /// 由系统 traits 现算的颜色。
    ///
    /// 不用 `@Environment(\.colorScheme)` 在读的地方判断：那样每个用到 theme 的视图
    /// 都得自己接一遍环境值，漏一处就是「切深色了正文还是白底」。
    private func adaptive(
        light: (Double, Double, Double),
        dark: (Double, Double, Double)
    ) -> Color {
        Color(
            uiColor: UIColor { traits in
                let c = traits.userInterfaceStyle == .dark ? dark : light
                return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
            }
        )
    }

    /// 没在播的句子淡一档。用透明度而不是换个颜色：主题给的字色只有一种，
    /// 淡档跟着它走，夜间模式才不会出现「黑底上一片灰字看不见」。
    var inactiveOpacity: Double { 0.72 }
}

/// 一页上的一片字。绝大多数情况一片就是一整句；一句太长、页尾塞不下整句时它被切成两片——
/// 前一片留在这页把页尾填满，后一片 `continues = true` 到下一页开头接着排。
///
/// 存的是**切好的文本**，不是「句下标 + 字符区间」：渲染端和测量端都直接拿这一份字去排，
/// 谁也没机会再切出第二个版本。切分口径只存在于 `paginate` 里一次。
struct PageSlice: Equatable, Hashable {

    /// 这一片属于哪一句（`chapter.sentences` 的数组下标，和 PlayerManager 同一口径，
    /// 不然点到A句播B句）。
    let position: Int

    /// 这一片要排的字。段首缩进那两个全角空格在句首那一片的开头。
    let text: String

    /// true = 上一页断下来的后半截：不吃段前白、不再缩进、不当成新段落开头。
    let continues: Bool

    init(
        position: Int,
        text: String,
        continues: Bool = false
    ) {
        self.position = position
        self.text = text
        self.continues = continues
    }
}

struct PageLayout: Equatable {

    /// `pages[p]` = 第 p 页承载的那几片字，按排版顺序。
    let pages: [[PageSlice]]

    let bodySize: CGFloat

    var pageCount: Int { pages.count }

    static let placeholder = PageLayout(pages: [[]], bodySize: 19)

    /// 一页给正文用的高度。**这个减法只写在这里**：分页端用它，探针也问它。
    ///
    /// 从前它藏在 `paginate` 里、末尾还乘了 0.95，于是三份探针各自抄了一遍那个数——
    /// 改了生产忘了探针，探针量到的就是上一页的几何，正好看见不到「每页少一行」。
    /// 上下各让 18pt 是渲染端那层 `.padding(.vertical,)` 的账，两边必须是同一个数。
    static func usableHeight(area: CGSize, body: CGFloat) -> CGFloat {
        max(
            area.height - ReaderTypography.verticalMargin * 2,
            body * 3
        )
    }

    /// 该句落在第几页。一句被切成两片时算**前**一片那页：跟读要在这一句开口时就把页翻过去，
    /// 不能等它念完。句子比页数「超范围」时（比如刚重排、或播放已推进到未渲染的句子）
    /// 返回最后一页，而不是崩掉。
    func page(containing sentence: Int) -> Int {
        var last = 0
        for (index, page) in pages.enumerated() {
            if let first = page.first?.position, sentence < first {
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
        lineScale: Double,
        chapterTitle: String
    ) -> PageLayout {

        guard area.width > 40, area.height > 40 else {
            return placeholder
        }

        let body = ReaderTypography.bodySize(scale: scale)

        let lineSpacing = ReaderTypography.lineSpacing(size: body, scale: lineScale)

        let contentWidth = max(
            area.width - ReaderTypography.horizontalMargin * 2,
            40
        )
        // 量高走 TextKit1 的行框（`ReaderBlock.lineRects`），和渲染端同一个排版器、同一个
        // padding=0 的容器：探针把同一段画两遍逐块对过，渲染高 − 测量高 落在 0 ~ −0.7pt，
        // 没有正的（`.probe/justify-probe.swift` C 段）。从前这里是 CoreText 的 `boundingRect`，
        // 它报的高和它自己断出的行对不上，最多虚高一整行——那才是「分页高比纸上多」的根。
        //
        // 不打折（见 `usableHeight`）：那层 0.95 是给 `boundingRect` 的虚高兜底的，量法换正
        // 之后它只剩一个效果——真机口径下版心 693pt、行距 28pt，658.35 只够 23 行，而纸上
        // 放得下 24 行，于是「页尾莫名空一行」每页都发生。测量端报矮的方向已被探针堵死，
        // 用满不会溢到纸外；真溢出一行也只是被 `clipped()` 剪掉，换回来的是每章少翻几页。
        let usableHeight = Self.usableHeight(area: area, body: body)

        func measure(
            _ runs: [ReaderBlock.Run]
        ) -> CGFloat {
            ReaderBlock.height(
                runs: runs,
                body: body,
                lineSpacing: lineSpacing,
                width: contentWidth
            )
        }

        // 整章先摊成「一片 = 一整句」，按同段并成块，再贪心装页。
        // 页边界怎么切（含句内切）在下面那个循环里。
        let blocks = ReaderBlock.groups(
            in: sentences.indices.map {
                PageSlice(
                    position: $0,
                    text: ReaderTypography.displayText(
                        sentences[$0],
                        chapterTitle: chapterTitle
                    )
                )
            },
            sentences: sentences,
            chapterTitle: chapterTitle
        )

        var pages: [[PageSlice]] = []
        var current: [PageSlice] = []

        /// 本页上已经收尾的那些块的总高。
        var committed: CGFloat = 0

        /// 当前块在本页已经排上的片段。
        ///
        /// 量高必须连着量：同段的句子渲染时在一个 `Text` 里连着走，一片一片各量各的
        /// 会在每个折行处多算一行，页尾就溢出去。
        var blockRuns: [ReaderBlock.Run] = []

        var blockGap: CGFloat = 0

        var blockIndex = 0

        /// 当前块排到第几片。一段跨页时它不为 0：后半截要在下一页开头。
        var entryIndex = 0

        /// 当前这一片已经被上一页切走了多少个字。0 = 还是一片完整的句子。
        var entryOffset = 0

        func blockHeight() -> CGFloat {
            blockRuns.isEmpty ? 0 : blockGap + measure(blockRuns)
        }

        func closePage() {
            pages.append(current)
            current = []
            committed = 0
            blockRuns = []
            blockGap = 0
        }

        /// 这一片最多能切多少个字进本页剩下的空间。nil = 切不动（不到一行、太短、章标题）。
        ///
        /// 页尾留白的真身不是「下一段太长」，是「下一句比剩下的空间高」：整句挪走，
        /// 这页就空出一片（真机截图量到过 175pt，占了版心四分之一）。书是照行断的，
        /// 这里也照行断。
        func splitPoint(
            _ rest: String,
            continues: Bool,
            position: Int,
            spare: CGFloat
        ) -> Int? {

            // 章标题居中排，切开就是两行半截标题。
            guard !ReaderTypography.isChapterHeading(
                sentences[position],
                chapterTitle: chapterTitle
            ) else { return nil }

            // 前后各留几个字：本页末尾只挂一个字、或者下一页开头孤零零两三个字，
            // 比留白还难看。
            let minHead = 4
            let minTail = 6

            guard rest.count >= minHead + minTail else { return nil }

            func heightOf(_ count: Int) -> CGFloat {
                let pieceRuns = ReaderBlock.runs(
                    for: [
                        PageSlice(
                            position: position,
                            text: String(rest.prefix(count)),
                            continues: continues
                        )
                    ],
                    sentences: sentences,
                    chapterTitle: chapterTitle
                )
                return measure(blockRuns + pieceRuns)
            }

            // 高度随字数单调不降，二分找塞得下的最长前缀。
            var low = minHead
            var high = rest.count - minTail
            var best = 0

            while low <= high {
                let mid = (low + high) / 2
                if heightOf(mid) <= spare {
                    best = mid
                    low = mid + 1
                } else {
                    high = mid - 1
                }
            }

            guard best > 0 else { return nil }

            // 切点再收一下：别断在英文单词中间，别把「。」这类收尾标点甩到下一页开头，
            // 也别让「「」这类开头标点吊在本页末尾。三种都只是难看，不影响高度
            // ——往前收只会更矮，所以不用再量一遍。
            let cut = tidy(best, in: Array(rest))

            guard cut >= minHead else { return nil }

            return cut
        }

        while blockIndex < blocks.count {

            let block = blocks[blockIndex]
            let entry = block[entryIndex]

            let rest = String(entry.text.dropFirst(entryOffset))
            let continues = entryOffset > 0

            let slice = PageSlice(
                position: entry.position,
                text: rest,
                continues: continues
            )

            let runs = ReaderBlock.runs(
                for: [slice],
                sentences: sentences,
                chapterTitle: chapterTitle
            )

            if blockRuns.isEmpty {
                blockGap = ReaderBlock.gap(
                    first: slice,
                    firstOnPage: current.isEmpty,
                    sentences: sentences,
                    size: body,
                    lineSpacing: lineSpacing
                )
            }

            let spare = usableHeight - committed - blockGap

            if measure(blockRuns + runs) <= spare {

                current.append(slice)
                blockRuns += runs

                entryIndex += 1
                entryOffset = 0

                // 这一块排完了：交账，下一块另起一份累计。
                if entryIndex == block.count {
                    committed += blockHeight()
                    blockRuns = []
                    blockGap = 0
                    blockIndex += 1
                    entryIndex = 0
                }

                continue
            }

            if current.isEmpty {
                // 空页都装不下这一句（超长引用、极小屏）：让它先占着这一页，
                // 宁可溢出让滚动兜底，也不能反复往空页里塞同一句（那是死循环）。
                current.append(slice)

                entryIndex += 1
                entryOffset = 0

                if entryIndex == block.count {
                    blockIndex += 1
                    entryIndex = 0
                }

                closePage()
                continue
            }

            if let cut = splitPoint(
                rest,
                continues: continues,
                position: entry.position,
                spare: spare
            ) {
                current.append(
                    PageSlice(
                        position: entry.position,
                        text: String(rest.prefix(cut)),
                        continues: continues
                    )
                )

                // 这一片剩下的半截 nextPage 开头接着排，块和条目都不动。
                entryOffset += cut

                closePage()
                continue
            }

            // 切不动（剩下的空间不到一行、太短、或者是章标题）：本页收尾，整片挪下一页。
            closePage()
        }

        if !current.isEmpty {
            pages.append(current)
        }
        if pages.isEmpty {
            pages.append([])
        }

        return PageLayout(pages: pages, bodySize: body)
    }

    /// 把二分找到的切点往前挪到一处不难看的位置。
    ///
    /// 只往前退、不往后扩，所以「塞得下」这个前提一直成立，不用再量一遍高度。
    ///
    /// 这里一律写 `Swift.Character`：本模块有个「小说角色」就叫 `Character`，
    /// 光写裸名拿到的是那个模型结构体，不是排版意义上的一个字。
    private static func tidy(_ cut: Int, in rest: [Swift.Character]) -> Int {

        var k = cut

        if k < rest.count,
           isLatin(rest[k]),
           isLatin(rest[k - 1]) {
            // 断在了英文单词中间：整个词让给下一页。最多让 24 个字，再长就是个网址
            // 之类的东西，宁可断在词中也不要退到没字可排。
            var back = 0
            while back < 24, k - back - 1 >= 0, isLatin(rest[k - back - 1]) {
                back += 1
            }
            k -= back
        }

        // 收尾标点不能顶在下一页第一格，开头标点不能吊在本页最后一格。
        let opening = "「『（《“‘【"
        let closing = "。，、；：？！」』）》”’】…"

        while k > 1 {
            let danglingOpen = opening.contains(String(rest[k - 1]))
            let leadingClose = k < rest.count && closing.contains(String(rest[k]))
            guard danglingOpen || leadingClose else { break }
            k -= 1
        }

        return k
    }

    /// ASCII 字母与数字，也就是「一个英文词」的边界。中文一个字一格，没有词中间可断。
    private static func isLatin(_ c: Swift.Character) -> Bool {
        guard c.unicodeScalars.count == 1,
              let scalar = c.unicodeScalars.first
        else { return false }

        switch scalar.value {
        case 0x41...0x5A, 0x61...0x7A, 0x30...0x39: return true
        default: return false
        }
    }
}
