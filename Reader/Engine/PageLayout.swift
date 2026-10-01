//
//  PageLayout.swift
//  Reader
//
//  排版内核之三：贪心装页 + 句内切。
//
//  书本式分页：同段句子并成一块，按块量高，再按页的可用高度贪心装页。
//  一页的几何从外面进来（`area`），这里只回答「这一页装得下哪几片」。
//

import Foundation

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

    /// `pageStretch[p]` = 第 p 页在**基础行距**上每条行距缝要再多加多少，把这一页的末行
    /// 压到版心底（垂直对齐）。与 `pages` 一一对应；章节最后一页和空页是 0（不拉）。
    ///
    /// 为什么要拉：贪心装页 + 句内切之后，一页末尾总剩一点装不下一整行的余量 `slack`
    /// ——再塞一行就溢出，少一行就留白，离散地消不掉。唯一的办法是把这点余量摊进这一页
    /// 所有的行距缝里：每缝多 `e = slack / 缝数`。缝数 = Σ(每块行数 − 1) + 段前白那条缝，
    /// 满页二十几条缝，`e` 恒在 1pt 上下（行距 ~30.7pt → ~32pt，5%），肉眼看不出，
    /// 末行却正好落在版心底。渲染端 `ReaderPageBody` 拿这个数一起抬 `lineSpacing` 和段前白。
    let pageStretch: [CGFloat]

    let bodySize: CGFloat

    var pageCount: Int { pages.count }

    static let placeholder = PageLayout(pages: [[]], pageStretch: [0], bodySize: 19)

    /// 每条行距缝最多多抬多少。满页的余量不到一行、缝有二十几条，`e` 自然落在 1.3pt 以下，
    /// 这个上限根本碰不到；它只兜「缝特别少的短页」（超长引用挤出的那种），那种页宁可末行
    /// 下面留点白，也不把行距拉到看得见的程度。
    static let stretchCap: CGFloat = 1.5

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

    /// 第 `index` 页要多加的行距（垂直对齐用）。越界（刚重排、或播放已推进到没渲染的页）
    /// 返回 0，不崩——和 `page(containing:)` 一个道理。
    func stretch(forPage index: Int) -> CGFloat {
        pageStretch.indices.contains(index) ? pageStretch[index] : 0
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

        /// 一次排版同时拿高度和行数（垂直对齐摊余量要按行距缝算，缝数 = 行数 − 1）。
        func metricsOf(
            _ runs: [ReaderBlock.Run]
        ) -> (height: CGFloat, lines: Int) {
            ReaderBlock.metrics(
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

        /// 和 `pages` 一一对应的那份行距拉伸。每次 `pages.append` 都得跟着 append 一个，
        /// 两个数组错一位，垂直对齐就贴到别的页上去了。
        var pageStretch: [CGFloat] = []

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
            pageStretch.append(stretch(for: current))
            pages.append(current)
            current = []
            committed = 0
            blockRuns = []
            blockGap = 0
        }

        /// 这一页每条行距缝要多加多少，才能把末行压到版心底（垂直对齐）。
        ///
        /// 拿最终的 `current` 重新分块、逐块量：这就是渲染端会排出来的东西——`ReaderPageBody`
        /// 收同一份 `slices`、走同一个 `ReaderBlock.groups`、`gap` 也喂同一个数，所以这里量到的
        /// 高度和缝数就是纸上落的那一份。刻意不用装页过程里的 `committed + blockHeight()`：
        /// 句内切那一下，切出来的前半片只进了 `current` 没进 `blockRuns`，那套临时状态在这里是缺的。
        ///
        /// 缝数把段前白那条也算进去（`gap > 0` 时）：渲染端抬 `lineSpacing` 时连 `gap` 里含的那个
        /// `lineSpacing` 一起抬了，所以每条缝都恰好多 `e`。这样缝数 ≈ 全页行数 − 1，和分了几段无关
        /// ——对白多的页（段多、每段行少）也不会因为「块内缝少」而被迫把 `e` 拉大。
        func stretch(for slices: [PageSlice]) -> CGFloat {

            guard !slices.isEmpty else { return 0 }

            var height: CGFloat = 0
            var seams = 0

            for (index, group) in ReaderBlock.groups(
                in: slices,
                sentences: sentences,
                chapterTitle: chapterTitle
            ).enumerated() {

                let runs = ReaderBlock.runs(
                    for: group,
                    sentences: sentences,
                    chapterTitle: chapterTitle
                )

                let gap = ReaderBlock.gap(
                    first: group[0],
                    firstOnPage: index == 0,
                    sentences: sentences,
                    size: body,
                    lineSpacing: lineSpacing
                )

                let m = metricsOf(runs)

                height += gap + m.height
                seams += max(m.lines - 1, 0) + (gap > 0 ? 1 : 0)
            }

            let slack = usableHeight - height

            guard seams > 0, slack > 0.5 else { return 0 }

            return min(slack / CGFloat(seams), Self.stretchCap)
        }

        /// 这一片最多能切多少个字进本页剩下的空间。nil = 切不动（连一个字都塞不下、章标题）。
        ///
        /// 页尾留白的真身不是「下一段太长」，是「下一句比剩下的空间高」：整句挪走，
        /// 这页就空出一片（真机截图量到过 175pt，占了版心四分之一）。书是照行断的，
        /// 这里也照行断。
        ///
        /// 「照行断」要断到底：切点只由「这一行还塞不塞得下」决定，不给本页末尾、也不给
        /// 下一页开头预留字数，理由写在下面那道 `guard` 旁边。
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

            // 切点只看「这一行还塞不塞得下」，前后一概不预留。
            //
            // 从前这里有两道情面：本页末尾至少挂 4 个字、下一页开头至少留 6 个字。两道都在
            // 页末行上挖洞——少塞进来的那几个字，到了下一页也填不满任何东西：段落收尾那一行
            // 本来就该是短的（读者口径允许普通行只剩一个字），而页末这一行是段落还在往下走的
            // 地方，右边空着就是事故。真机 3/22 页末行「…的经济实力也是」空了三格就是这么来的：
            // 那一句 16 个字、行里还剩 13 个位置，「留 6 个字给下一页」把切点钉死在第 10 个字。
            //
            // 只留一个字：整片都切进本页会让 `entryOffset` 正好吃掉这一片，下一页开头就多出
            // 一片空 slice。
            guard rest.count >= 2 else { return nil }

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
            var low = 1
            var high = rest.count - 1
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

            // 收标点/退英文词能把切点一路退到 0（整串拉丁词就是开头那个词）。退到 0 等于
            // 什么都没切，下一页会拿到完全相同的一片——这一页永远填不满，循环也不往前走。
            guard cut >= 1 else { return nil }

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

            if current.isEmpty {
                // 切不动、这一页又还是空的：整片让它占着这一页，不能反复往空页里塞同一句
                // （那是死循环）。走到这里的是「一个字都塞不下」或章标题那种不许切的。
                //
                // 这道兜底必须写在「切一刀」试过之后。从前它写在前面，于是「这一句比一页
                // 还高」压根没走到切分——自检探针（`.probe/main-paginate.swift` 的「单句超长」：
                // 200×120 的屏、900 字一句）量出来 2751pt 全压在可用 84pt 的一页上，一页装了
                // 33 页的字。#127 之后纸不滚动了，溢出纸外的那些字就是看不见。
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

            // 切不动（剩下的空间不到一行、太短、或者是章标题）：本页收尾，整片挪下一页。
            closePage()
        }

        if !current.isEmpty {
            // 章节最后一页不拉：它末行下面本来就该留白，压到版心底反而像没排完。
            pages.append(current)
            pageStretch.append(0)
        }
        if pages.isEmpty {
            pages.append([])
            pageStretch.append(0)
        }

        return PageLayout(pages: pages, pageStretch: pageStretch, bodySize: body)
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