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

    /// `columnCuts[p]` = 第 p 页各栏在 `pages[p]` 里的**起始下标**，一项一栏。
    ///
    /// 为什么页还是摊平成一片字：`pages` 这个契约被翻页页序、进度、`page(containing:)`
    /// 和六份探针使着，它们都只关心「这一页有哪些字」。栏是**纸面**的属性，不是内容的属性，
    /// 所以它记成一份下标表，而不是把 `[[PageSlice]]` 套成三层。
    /// 每页的项数恒等于这张纸摊的栏数（章末摊不满的那些栏交空栏），渲染端就按这一项数算栏宽——
    /// 栏宽只由分页端判一次，两边各判一遍会出现「分页两栏、纸上一栏」。
    let columnCuts: [[Int]]

    /// `columnStretch[p][c]` = 第 p 页第 c 栏在**基础行距**上每条行距缝要挪多少，把这一栏的
    /// 末行落到版心底（垂直对齐）。正 = 抬，负 = 压。与 `columnCuts` 一一对应；章末**那一页的每一栏**
    /// 都只压不抬，空栏是 0。
    ///
    /// 为什么要挪：贪心装页 + 句内切之后，一栏末尾总剩一点装不下一整行的余量 `slack`
    /// ——再塞一行就溢出，少一行就留白，离散地消不掉。唯一的办法是把这点余量摊进这一栏
    /// 所有的行距缝里：每缝多 `e = slack / 缝数`。满栏二十几条缝，`e` 恒在 1pt 上下
    /// （行距 ~30.7pt → ~32pt，5%），肉眼看不出，末行却正好落在版心底。
    /// 渲染端 `ReaderPageBody` 拿这个数一起抬 `lineSpacing` 和段前白。
    ///
    /// 为什么按**栏**给而不是按页给：一栏的余量和另一栏的余量是两笔独立的账。共用一个 `e`
    /// 的话，两栏的末行下面各差最多一行，读者看见的就是「两栏底边没对齐」——那是比页尾留白
    /// 更醒目的事故。
    ///
    /// 负的那一半才是「多提一行」的那一步：装栏时允许这一栏按基础行距**超出**版心
    /// `stretchCap × 缝数`（见 `fillBudget`），于是「差一点点就装得下」的那一行真能装上，
    /// 收尾再把每缝压回去 ≤`stretchCap`。从前只有正向的抬，栏尾剩四十几 pt 时
    /// 既装不下下一段（段前白 + 一行 = 四十六 pt）、又摊不平（上限 1.5×16 缝 = 24pt），
    /// 纸上就留着一条看得见的白。
    let columnStretch: [[CGFloat]]

    let bodySize: CGFloat

    var pageCount: Int { pages.count }

    static let placeholder = PageLayout(
        pages: [[]],
        columnCuts: [[0]],
        columnStretch: [[0]],
        bodySize: 19
    )

    /// 每条行距缝最多多抬、也最多压多少。满页的余量不到一行、缝有二十几条，`e` 自然落在
    /// 1.3pt 以下，这个上限根本碰不到；它只兜「缝特别少的短页」（超长引用挤出的那种），那种页
    /// 宁可末行下面留点白，也不把行距挪到看得见的程度。
    ///
    /// 两个方向共用同一个数是有讲究的：装页时那一页能超出的预算正是 `stretchCap × 缝数`
    /// （`fillBudget`），收尾再按同一个上限压回来，两边必须咬合，否则压不平就是末行掉到纸外。
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

    /// 第 `index` 页摊成几栏：每栏从 `pages[index]` 的哪个下标起、每栏的行距要挪多少。
    /// 越界（刚重排、或播放已推进到没渲染的页）退回「单栏、不挪行距」，不崩——
    /// 和 `page(containing:)` 一个道理。
    func columns(onPage index: Int) -> (cuts: [Int], stretch: [CGFloat]) {
        guard columnCuts.indices.contains(index),
              columnStretch.indices.contains(index)
        else { return (cuts: [0], stretch: [0]) }
        return (cuts: columnCuts[index], stretch: columnStretch[index])
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

        /// 这张纸摊几栏、一栏多宽。断行与量高一律按 `columnWidth` 走，渲染端按 `columnCuts`
        /// 的项数算出同一个数（两边各判一遍宽，就是「分页两栏、纸上一栏」）。
        ///
        /// 栏宽跟着字号走（见 `ReaderTypography.minColumnLetters`），所以大字档在 iPhone 横屏上
        /// 会退回单栏——这不是妥协，是那一档一行只剩十一个字，两端对齐根本补不平。
        let columns = ReaderTypography.columnCount(
            contentWidth: contentWidth,
            body: body
        )
        let columnWidth = ReaderTypography.columnWidth(
            contentWidth: contentWidth,
            columns: columns,
            body: body
        )
        // 量高走 `ReaderBlock.metrics`：行数问 TextKit1（和渲染端同一个排版器、同一个 padding=0
        // 的容器），每行多高按**字体行高**算——TextKit 的行框高到 20pt 以上会截成 1em，直接
        // 拿它相加会在大字号下少量半行（`metrics` 里有那张实测表）。
        // 探针把同一段画两遍逐块对过，渲染高 − 测量高 落在 0 ~ −0.7pt，
        // 没有正的（`.probe/justify-probe.swift` C 段）。从前这里是 CoreText 的 `boundingRect`，
        // 它报的高和它自己断出的行对不上，最多虚高一整行——那才是「分页高比纸上多」的根。
        //
        // 不打折（见 `usableHeight`）：那层 0.95 是给 `boundingRect` 的虚高兜底的，量法换正
        // 之后它只剩一个效果——真机口径下版心 693pt、行距 28pt，658.35 只够 23 行，而纸上
        // 放得下 24 行，于是「页尾莫名空一行」每页都发生。测量端报矮的方向已被探针堵死，
        // 用满不会溢到纸外；真溢出一行也只是被 `clipped()` 剪掉，换回来的是每章少翻几页。
        let usableHeight = Self.usableHeight(area: area, body: body)

        /// 一次排版同时拿高度和行数（垂直对齐摊余量要按行距缝算，缝数 = 行数 − 1）。
        ///
        /// 只留这一个量法：高度和行数出自同一次断行，分开量会出现「高按一版、缝按另一版」。
        func metricsOf(
            _ runs: [ReaderBlock.Run]
        ) -> (height: CGFloat, lines: Int) {
            ReaderBlock.metrics(
                runs: runs,
                body: body,
                lineSpacing: lineSpacing,
                width: columnWidth
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
        var columnCuts: [[Int]] = []
        var columnStretch: [[CGFloat]] = []

        var current: [PageSlice] = []

        /// 本页上**已经收尾**的那些栏：`spread` 摊平就是 `pages` 里那一片字，
        /// `spreadCuts[c]` 是第 c 栏在其中的起点，`spreadStretch[c]` 是那一栏的行距挪量。
        ///
        /// 这三个和 `pages` / `columnCuts` / `columnStretch` 是一一对应的，每交出一整页
        /// 就得三样一起清 —— 错一位，垂直对齐就贴到别的页、甚至别的栏上去。
        var spread: [PageSlice] = []
        var spreadCuts: [Int] = []
        var spreadStretch: [CGFloat] = []

        /// 本页上已经收尾的那些块的总高。
        var committed: CGFloat = 0

        /// 那些块留下的行距缝数（每块「行数 − 1」，再加它自己那条段前白）。装栏的预算按
        /// 缝数算，所以这两个数得一起记、一起在 `closeColumn` 清零。
        var committedSeams = 0

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

        /// 排到 `lines` 行为止，这一栏能给多高。
        ///
        /// 收尾时 `stretch(for:)` 最多能把每条缝压 `stretchCap`，也就是整栏还能再多出
        /// `stretchCap × 缝数`。装栏时不把这块地方留给自己，就会白留一条栏尾：真机那一页
        /// 末行下面空了二十几 pt，是因为下一段要「段前白 + 一行」≈46pt 而栏尾只剩 43pt，
        /// 按基础行距判是装不下——可那 43pt 摊到 16 条缝上每缝才压 0.2pt，纸上看不出来。
        /// 于是「一行都提不上来」和「压得动这一行」两件事被基础行距一刀切掉了。
        func fillBudget(seams: Int) -> CGFloat {
            usableHeight + Self.stretchCap * CGFloat(seams)
        }

        /// 交出一整页：本页攒下的那些栏连同栏位表、行距表一起归档。
        func flushPage() {
            pages.append(spread)
            columnCuts.append(spreadCuts)
            columnStretch.append(spreadStretch)
            spread = []
            spreadCuts = []
            spreadStretch = []
        }

        /// 一栏收尾：算出这一栏该挪的行距、并进本页；栏攒够了就交出一整页。
        ///
        /// 为什么以栏为单位收尾：`current`、`committed`、`blockRuns` 这些累计全是**一栏**的账。
        /// 两栏的余量各是各的（见 `columnStretch` 上那段），所以每次抬量都只能按当前这一栏算，
        /// 攒够 `columns` 栏才翻页——中途翻不得。
        func closeColumn() {
            spreadCuts.append(spread.count)
            spreadStretch.append(stretch(for: current))
            spread += current

            current = []
            committed = 0
            committedSeams = 0
            blockRuns = []
            blockGap = 0

            if spreadCuts.count == columns {
                flushPage()
            }
        }

        /// 这一栏每条行距缝要挪多少，才能把末行落到版心底（垂直对齐）。正 = 抬，负 = 压。
        ///
        /// 拿最终的 `current` 重新分块、逐块量：这就是渲染端会排出来的东西——`ReaderPageBody`
        /// 收同一份 `slices`、走同一个 `ReaderBlock.groups`、`gap` 也喂同一个数，所以这里量到的
        /// 高度和缝数就是纸上落的那一份。刻意不用装页过程里的 `committed + 块高`：
        /// 句内切那一下，切出来的前半片只进了 `current` 没进 `blockRuns`，那套临时状态在这里是缺的。
        ///
        /// 缝数把段前白那条也算进去（`gap > 0` 时）：渲染端挪 `lineSpacing` 时连 `gap` 里含的那个
        /// `lineSpacing` 一起挪了，所以每条缝都恰好挪 `e`。这样缝数 ≈ 全页行数 − 1，和分了几段无关
        /// ——对白多的页（段多、每段行少）也不会因为「块内缝少」而被迫把 `e` 拉大。
        ///
        /// 这里的 `e` 和装页时那份 `fillBudget` 是同一枚硬币的两面：预算按「每缝最多挪
        /// `stretchCap`」给出去，收尾就按同一个上限收回来，两边必须咬合，否则压不平的那
        /// 半行就是掉到纸外的一行。
        ///
        /// 咬合成立的前提是「页高对行距严格线性」：这里量的是**基础行距**那一版，落纸高 =
        /// 这一版 + `e × 缝数`，所以取整（`.rounded(.up)`）不随 `e` 出台阶，封顶 1pt 且是往矮里
        /// 取，落纸高恒 ≤ 可用高。按块的那份余量另算，见 `ReaderTypography.renderGuard`——
        /// 从前把它写成逐块 `ceil`，台阶就跟着 `e` 一起动，咬合当场散架。
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

            let slack = usableHeight - height.rounded(.up)

            guard seams > 0, abs(slack) > 0.5 else { return 0 }

            return max(
                -Self.stretchCap,
                min(slack / CGFloat(seams), Self.stretchCap)
            )
        }

        /// 这一片最多能切多少个字进本页剩下的空间。nil = 切不动（连一个字都塞不下、章标题）。
        ///
        /// 页尾留白的真身不是「下一段太长」，是「下一句比剩下的空间高」：整句挪走，
        /// 这页就空出一片（真机截图量到过 175pt，占了版心四分之一）。书是照行断的，
        /// 这里也照行断。
        ///
        /// 「照行断」要断到底：切点只由「这一行还塞不塞得下」决定，不给本页末尾、也不给
        /// 下一页开头预留字数，理由写在下面那道 `guard` 旁边。
        ///
        /// `seamsBefore` = 这一页在切点之前已经数好的行距缝（含这一块那条段前白）。
        /// 判「塞得下」要按 `fillBudget` 给的那份预算，和装页主循环同一个口径——两边各用
        /// 一份的话，主循环说装得下、切分说切不动，这一行就谁都不管了。
        func splitPoint(
            _ rest: String,
            continues: Bool,
            position: Int,
            spare: CGFloat,
            seamsBefore: Int
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

            func metricsOfPrefix(_ count: Int) -> (height: CGFloat, lines: Int) {
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
                return metricsOf(blockRuns + pieceRuns)
            }

            // 高度随字数单调不降，二分找塞得下的最长前缀。多出一行只多一条缝（预算
            // +`stretchCap`），行框本身十几 pt 起，所以「塞得下」一路单调，不会来回跳。
            var low = 1
            var high = rest.count - 1
            var best = 0

            while low <= high {
                let mid = (low + high) / 2
                let m = metricsOfPrefix(mid)
                if m.height
                    <= spare
                    + Self.stretchCap * CGFloat(seamsBefore + max(m.lines - 1, 0)) {
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

            let placed = metricsOf(blockRuns + runs)

            let blockSeams = (blockGap > 0 ? 1 : 0) + max(placed.lines - 1, 0)

            if placed.height <= fillBudget(seams: committedSeams + blockSeams) - committed - blockGap {

                current.append(slice)
                blockRuns += runs

                entryIndex += 1
                entryOffset = 0

                // 这一块排完了：交账，下一块另起一份累计。
                if entryIndex == block.count {
                    committed += blockGap + placed.height
                    committedSeams += blockSeams
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
                spare: spare,
                seamsBefore: committedSeams + (blockGap > 0 ? 1 : 0)
            ) {
                current.append(
                    PageSlice(
                        position: entry.position,
                        text: String(rest.prefix(cut)),
                        continues: continues
                    )
                )

                // 这一片剩下的半截下一栏开头接着排，块和条目都不动。
                entryOffset += cut

                closeColumn()
                continue
            }

            if current.isEmpty {
                // 切不动、这一栏又还是空的：整片让它占着这一栏，不能反复往空栏里塞同一句
                // （那是死循环）。走到这里的是「一个字都塞不下」或章标题那种不许切的。
                //
                // 这道兜底必须写在「切一刀」试过之后。从前它写在前面，于是「这一句比一栏
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

                closeColumn()
                continue
            }

            // 切不动（这一栏剩下的空间不到一行、太短、或者是章标题）：本栏收尾，整片挪下一栏。
            closeColumn()
        }

        if !current.isEmpty {
            // 章末那一栏不往上抬：它末行下面本来就该留白，抬到版心底反而像没排完。
            // 往下压却必须允许——那一栏同样花掉了 `fillBudget` 那份弹性预算，不压就是
            // 有一行掉到纸外（自检「小字 + 密行」末页量出 723.9 > 可用 720，#127 之后纸不滚动，
            // 那行字谁也看不见）。
            spreadCuts.append(spread.count)
            spreadStretch.append(min(0, stretch(for: current)))
            spread += current
            current = []
        }

        if !spread.isEmpty {
            // 章末这一页摊不满一整张的栏数：剩下的栏交**空栏**，不交「少一栏」。
            // 栏数是这张纸的几何（宽度定的），不是「这一页还剩多少字」的函数——渲染端拿
            // `columnCuts.count` 算栏宽，少一项它就会把半页字铺满整幅纸，那一页的每一行
            // 都比分页端量的宽，读者看见的是最后两页莫名变成通栏。
            while spreadCuts.count < columns {
                spreadCuts.append(spread.count)
                spreadStretch.append(0)
            }
            flushPage()
        }

        if pages.isEmpty {
            pages.append([])
            columnCuts.append([0])
            columnStretch.append([0])
        }

        // 章末那一页的每一栏都只压不抬。上面那条 `min(0, …)` 只管得住「还在手里的那一栏」，
        // 而章末页的前几栏是走 `closeColumn()` 交出去的——那时还不知道这是最后一页，
        // 抬量按正常页给过。所以这里对最后一页整表再收一遍。
        //
        // 为什么必须整页收：一栏抬、隔壁那栏不抬，两栏的底边就错开一行以内的一段距离，
        // 读者看见的是「最后两页两栏没对齐」；而且章末页下面本来就该留白，抬上去那一栏
        // 看着像没排完。收掉抬量只会让字更短，不会溢出——量高时按 `slack / 缝数` 给的是
        // 向上摊，不摊就是留白。
        if let last = columnStretch.indices.last {
            columnStretch[last] = columnStretch[last].map { min(0, $0) }
        }

        return PageLayout(
            pages: pages,
            columnCuts: columnCuts,
            columnStretch: columnStretch,
            bodySize: body
        )
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