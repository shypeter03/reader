//
//  ReaderBlock.swift
//  Reader
//
//  排版内核之二：断行、两端对齐补齐、量高、分块。
//
//  这里唯一的平台依赖是测量：`penPositions` 和 `lineRects` 都走 TextKit1 的
//  `NSLayoutManager`。这不是随手选的——断点必须和落纸的排版器同一个引擎，换成
//  CoreText 的字形推进就偏 3%，整行崩掉（见 `penPositions` 的说明）。要接第二个端，
//  替身必须给出同样的行框口径，而不是把这里的数抄走。
//
//  渲染侧那两段（SwiftUI 的 `Font` 与 `attributedString`）在
//  `Reader/Render/ReaderPageText.swift`：内核里不许出现 Color / SwiftUI 的 Font。
//

import UIKit

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

    /// 两端对齐摊给**每一格**的字距上限，按字宽算。探针断言用的也是这一个数，别处不许另抄。
    ///
    /// 为什么是 0.06：满行十七八个缝，每个缝最多动 0.06 字宽，整行最多多摊出约一个字宽——
    /// 正好吃得掉最常见的洞（禁则挪走「。」一整簇留下的那一格），于是绝大多数行照样顶到
    /// 右边界；而相邻两行的字间距之差被这个数封死（19pt 字号 ≈1.15pt，21.5pt ≈1.3pt），
    /// 肉眼分不出「这行密、那行散」。从前给的是 0.26 字宽，模拟器实测（`.probe/justify-probe.swift`
    /// 改前基线）94 行里 21 行每格补过 1.5pt、最大 7.9pt（30pt 字号那一档），
    /// 那才是读者说「为了填满整行，字间距被迫明显变化」的出处。
    ///
    /// 洞比这个上限大就**不硬拉**：那点余量留在行尾，右边界宁可少一个字。
    static let justifyGapCap: CGFloat = 0.06

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
    /// 洞断不掉（把收尾标点甩在行尾是排版事故），只能摊，但**摊不平就让它空着**：
    /// 读者要的是每一行字间距都一样，不是每一行都顶到右边界。这两件事从前被当成一件，
    /// 于是补字距的上限给到 0.26 字宽，两格的洞就每个缝张开 5pt 以上——右边界齐了，
    /// 换来的是「这一行散、那一行密」。现在上限收到 `justifyGapCap`（0.06 字宽），
    /// 补不平的那点余量留在行尾，宁可行尾少一个字。
    ///
    /// 四条约束：
    /// ① 只补**我们自己断出来的**那些行。段末那一行、章标题那一行一概不补——
    ///    那是天然的短行，拉开就成了字缝能塞进手指的花名册。
    ///    唯一的例外写在 `Run.endsParagraph`：段落跨页时，页末那一行不是段末，是正文中间的一行，
    ///    照补。判据只看「这一块的最后一片是不是整段的收尾」，两端都不许各自判一遍。
    /// ② 顶到 `width - 0.5` 为止，不补满分；补完这一行还要按落纸行回炉验一次（`lineBreaks` 里
    ///    那道「折半重试」的闸）。断点按 `width` 判定，补齐后正好顶满的一行在浮点上没人担保
    ///    还装得下；一旦判成装不下，引擎自己再折，量的与排的就此分家。
    /// ③ 每格最多补 `justifyGapCap` 字宽。洞再大也不硬拉，缺口留在行尾——
    ///    行尾空半格看得见，字缝里的空气更难看。
    /// ④ 段的最后一行整行只剩标点时，把上一个断点往前退一格，直到尾行头上是个真字：
    ///    「……这是一个测试」断在「。」之前（尾行只有「。」）不行，退一格排成
    ///    「……这是一个测 / 试。」。这一格是从上一行**少排一个字**来的，和 ③ 同一个取向：
    ///    少一个字，不换字间距。
    ///
    /// 普通行的行尾只剩一个字是允许的（③④ 都只动断点，不动字距，也不给一行设字数下限）：
    /// 一整段排到末尾本来就常常只剩一个字，为了凑满去压前面那些字的间距才是错。
    ///
    /// **先试死的路**（模拟器像素实测，`.probe/justify-probe.swift`）：`.multilineTextAlignment(.justified)`
    /// 确实拉平（段3@21.5 的行尾极差 45.7pt→21.0pt），但它按自己的算法折行，每段比我们的断点多出一行，
    /// 而纸不滚动（127 已去掉页内 ScrollView），多出的那一行直接看不见。自己补字距没有这一笔账：
    /// 行数一根手指都没碰，探针 C 段逐块对过，渲染高 − 测量高 只有 0 ~ −0.7pt。
    ///
    /// 字宽取排版引擎自己算的推进（`penPositions`，和 `height` 同一个 TextKit），
    /// 不按「汉字=1em」估——标点和数字各有各的宽。断处守三条：收尾标点不顶行首、
    /// 起始标点不孤行尾、拉丁词和数字不劈开。字距**只放大不缩小**（缺口为负就整行不补），
    /// 所以「为了多塞一个字而把整行压紧」这件事在这一版里没有任何代码路径。
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
                justifyTail: runs.last.map { $0.kind == .body && !$0.endsParagraph } ?? false,
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
        justifyTail: Bool,
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

        // 段落还在下一页：这一块的最后一条线不是段末，是正文中间的一行，跟着一起拉平。
        // 断点正好压在最后一个字上时（`lineStart == letters.count`）已经没这一行了，跳过。
        if justifyTail, lineStart < letters.count {
            broken.append((lineStart, letters.count))
        }

        // ④ 段末那一行不许整行只剩标点。
        //
        // 正常中文走不到这里：`canBreak` 不许断在「，。）」这类字之前，所以尾行头上必然跟着
        // 一个真字（「试。」）。唯一漏得进来的是上面那句兜底——整行没有一个允许断的地方
        // （超长拉丁词、整串「……」），断点被硬压在 `index` 上，尾行就可能只剩一个标点。
        // 治法是退一格：上一行少排一个字，尾行带上一个真字。
        //
        // 只管段末（`!justifyTail`）：页末那一行不是段的收尾，它的「最后一行」在下一页那一块里，
        // 那一块走到这里会自己判。
        //
        // 退完必须验新尾行在真版心里仍只占一行（`pen` 的推进就是断行用的那把尺）：
        // 尾行本来快满了、再吞一个字就要折第二行，那等于凭空多一行，页尾就此错位。
        if !justifyTail,
           lineStart > 0,
           lineStart < letters.count,
           noLineHead.contains(letters[lineStart]),
           var previous = broken.last,
           previous.end == lineStart {

            var head = lineStart

            while head > previous.start + 1,
                  noLineHead.contains(letters[head]),
                  pen[letters.count] - pen[head - 1] <= width {

                cuts.remove(head)
                head -= 1
                cuts.insert(head)
            }

            if head != lineStart {
                previous.end = head
                broken[broken.count - 1] = previous
            }
        }

        // 把行尾的洞摊进这一行的字距。洞是禁则挪走一整簇留下的，见 `layout` 的说明。
        //
        // 上限只给 `justifyGapCap`（0.06 字宽）：洞比「每格 0.06 × 缝数」大就补不平，
        // 缺口留在行尾。这是刻意的——字间距稳定比右边界齐更值钱，见 ③。
        // 反向（洞为负、行已经顶满）一概不补，也从不往里压：压缩字距在这版里没有路径。
        let target = width - 0.5
        let perGapCap = body * Self.justifyGapCap

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

        /// 这一个 run 是不是它所在段落的**收尾**（整句都在、下一句另起一段，或本章读完）。
        ///
        /// 内核算的是块里最后一个 run，它决定「这一块是不是以段落收尾行结束」。
        /// 为什么要专门记它：两端对齐只该补「我们自己断出来的行」，段末那一行短得理直气壮，
        /// 拉开就成了字缝能塞进手指的花名册。可**页末那一行**常常不是段末——后半截在下一页，
        /// 它就是正文中间的一行，书上是要拉平的。不分这一格，读者看见的就是
        /// 「一行莫名空了半截，字却在下一页继续」（真书普查：14 章 154 页里 50 处，最大 7 格）。
        ///
        /// 默认 `false` = 当成「段落还没收尾」，末行照补：手搓 `Run` 的取证代码量的正是
        /// 段落跨页时页末那一行（`.probe/justify-probe.swift` A/B 段）；判得出真段末的
        /// 只有走 `runs(for:...)` 的生产路径。
        var endsParagraph: Bool = false
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

        var runs = group.map { slice in

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

        guard !runs.isEmpty, let last = group.last else { return runs }

        runs[runs.count - 1].endsParagraph = closesParagraph(
            last,
            sentences: sentences,
            chapterTitle: chapterTitle
        )

        return runs
    }

    /// 这一片是不是它所在段落的收尾。
    ///
    /// 两条都要成立：这片是那句的**全部**（页尾切下来的前半截不算——后半截还在下一页），
    /// 且下一句另起一段（或者它已经是本章最后一句）。
    ///
    /// 为什么只看句子不看页：分页是「一句一片」，同段的片永远并进同一个块，所以
    /// 「这一块的最后一片」和「这一段的最后一句」是同一件事的两种说法。装页途中逐句
    /// 累加时也走这里，那时最后一片多半还在段中——给它末行补字距不会改动行数
    /// （`lineBreaks` 里那道「折半重试」的闸担保），所以量到的高和纸上排的高不会分家。
    private static func closesParagraph(
        _ slice: PageSlice,
        sentences: [Sentence],
        chapterTitle: String
    ) -> Bool {

        guard sentences.indices.contains(slice.position) else { return true }

        guard slice.text == ReaderTypography.displayText(
            sentences[slice.position],
            chapterTitle: chapterTitle
        ) else { return false }

        let next = slice.position + 1
        guard next < sentences.count else { return true }

        return sentences[next].startsParagraph
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
        metrics(
            runs: runs,
            body: body,
            lineSpacing: lineSpacing,
            width: width
        ).height
    }

    /// 这一块的实测高度**和**行数，一次排版两样都拿到。
    ///
    /// 为什么还要行数：分页收尾做垂直对齐（把末行压到版心底）时，摊余量按「行距缝」算，
    /// 缝数 = 行数 − 1。量高本来就走 `lineRects`，行数顺手一起交出来，别为一个 count 再排
    /// 一遍——整章几千行，多排一遍就是「点开一章 1s」预算里的大头。`height` 也走这里，
    /// 那个 `ceil(Σ 行框高)` 的口径因此只写在这一处。
    static func metrics(
        runs: [Run],
        body: CGFloat,
        lineSpacing: CGFloat,
        width: CGFloat
    ) -> (height: CGFloat, lines: Int) {
        let rows = lineRects(
            measureString(
                runs: runs,
                body: body,
                lineSpacing: lineSpacing,
                width: width
            ),
            width: width
        )
        return (
            ceil(rows.reduce(0) { total, row in total + row.height }),
            rows.count
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

}