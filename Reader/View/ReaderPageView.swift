//
//  ReaderPageView.swift
//  Reader
//
//  一页正文。渲染口径必须与 `PageLayout` 的测量口径逐字对应——字号、行距、
//  段首缩进、块怎么切、页边距、图框多大全部走 `ReaderTypography` 和 `ReaderBlock`，
//  任何一处只在一边改，页高就会算错，表现是「字溢到下一页」或整页空一半。
//

import SwiftUI
import ImageIO

/// 不带滚动的一页内容。单独拆出来是为了能被脱离滚动容器量出固有高度
/// （测量/校验用），`ReaderPageView` 只是给它定位并剪掉溢出的那一行。
struct ReaderPageBody: View {

    /// 整章句子
    let sentences: [Sentence]

    /// 本页承载的那几片字（一页尾切下来的半句也在里面）
    let slices: [PageSlice]

    let bodySize: CGFloat

    /// 行距档位。必须和 `PageLayout.paginate` 喂的是同一个数，否则页高算错。
    let lineScale: Double

    /// 每栏在 `slices` 里的起始下标（`PageLayout.columnCuts`），一项一栏。
    ///
    /// 栏数由分页端按纸宽判一次，渲染端只跟着这一项数走，**不再自己按宽判一遍**——
    /// 判两遍就会出现「分页按两栏切、纸上按一栏排」。
    var columnCuts: [Int] = [0]

    /// 垂直对齐：每栏在**基础行距**上再挪这么多，把这一栏的末行落到版心底。
    /// 来自 `PageLayout.columnStretch`（分页时按这一栏剩下的余量算出来），正 = 抬、负 = 压；
    /// 章末那一栏只会拿到 0 或负数（它下面本来就该留白，不许往上抬）。
    /// 渲染端把它同时加到 `.lineSpacing` 和段前白 `gap` 里含的那个 `lineSpacing` 上——
    /// 分页摊余量时正是按「这两类缝一起挪」数的缝，两边必须一致，否则末行落不到底。
    ///
    /// 为什么按栏给而不是整页一个数：两栏的余量是两笔独立的账，共用一个挪量的话两栏的
    /// 底边最多差出一行，读者看见的就是「两栏没对齐」。
    var columnStretch: [CGFloat] = [0]

    /// 版心宽（纸上正文那一整块的宽，已经让开左右边距）。分栏时它是各栏宽加栏空的和，
    /// 一栏多宽由 `columnWidth` 从这一个数算出来。必须和 `ReaderBlock.height` 量的是同一个
    /// 口径——两边各算各的，栏尾就溢出。
    let contentWidth: CGFloat

    /// 左右**各**让开的宽，由分页端算好随页交过来（`PageLayout.sideMargin`）。
    /// 渲染端不再自己量字宽：它垫的这一条和分页端抽掉的那一条必须是同一个数，
    /// 不然版心就对不上纸宽，正文就此偏一边（#168）。
    /// 双页时它是**这一面**的边距，靠中缝那一条就是中缝阴影的宽（见 `crease`）。
    let sideMargin: CGFloat

    /// 一张纸给正文用的高，由分页端随页交过来（`PageLayout.usableHeight`）。
    ///
    /// 它只有一处在纸上被问：一张图框多大（`ReaderTypography.imageFrame` 的高上限是它的 0.7）。
    /// 不许渲染端按 `GeometryReader` 实测的那一份自己算——那是第二把尺，纸面比分页那块地方
    /// 矮一点时纸上就画得比页里留的高，多出来那几 pt 就是页尾掉出去的那一行。
    let usableHeight: CGFloat

    /// 这一章的 XHTML 在机器上的位置。图存的是相对本章目录的 `href`（不落绝对路径，理由见
    /// `ChapterImage.href`），纸上要用时才由这里现解成文件路径。
    ///
    /// 它不参与测量，只参与取图：解错了顶多画出一块白，不会改一行的高。
    let chapterURL: URL

    /// 底色与字色。不参与测量，只参与渲染。
    let theme: ReaderTheme

    /// 章标题。正文第一句常常就是它本身，要按标题排而不是跟着正文走。
    let chapterTitle: String

    /// 正在朗读的句子下标；nil 表示本页没有正在播的句子
    let activePosition: Int?

    /// 这是不是一张有意留白的补位纸（双页摊不满时那半张）。
    ///
    /// 要单独说一声，因为「页上没字」在这一层有两种：空章（图片页）和补位白纸。
    /// 前者要告诉读者这一章真的没有可朗读的正文，后者什么都不必说——它就该是
    /// 一张白纸，冒出那行提示就成了 bug。
    var blank = false

    /// 卷扉页要印的那行卷名（「第一卷 在澹州」）。nil = 这不是扉页。
    ///
    /// 扉页是零句的一章（判据与成因见 `EPUBParser.isVolumeDivider`），所以它和「真·空章」
    /// 在句数上长得一模一样——没有这一声说明，纸上就会印出「这一章没有可朗读的正文」那句提示，
    /// 读者看见的就是「这一卷坏了」。有这一行就居中印卷名：那是一页书的扉页，不是一页故障。
    var dividerTitle: String? = nil

    let tap: (Int) -> Void

    var body: some View {

        // 一栏一栏并排放。左右那条边距是分页端量完随页交过来的 `sideMargin`（设计边距
        // 加上一行让出的那一个字，左右各一半），上下还是那 18pt：分栏切的是版心里面，
        // 栏宽 + 栏空正好等于 `contentWidth`，所以纸的四边和正文的宽对得上、正文在正中。
        HStack(
            alignment: .top,
            spacing: ReaderTypography.columnGutter(body: bodySize)
        ) {

            ForEach(
                Array(columnCuts.enumerated()),
                id: \.offset
            ) { index, _ in

                columnView(index)
            }
        }
        .padding(
            .horizontal,
            sideMargin
        )
        .padding(
            .vertical,
            ReaderTypography.verticalMargin
        )
        .frame(
            maxWidth: .infinity,
            alignment: .leading
        )
        // run 上的 link 只用来定位「点到了哪一句」，哪儿也不跳。
        // 并成一块以后点句不再是「哪个 Text 被点了」，只能这么问排版引擎。
        .environment(
            \.openURL,
            OpenURLAction { url in

                // [Tap] 取证（#162）：这一路报了吗？没报就是落点没交成 link。
                print("[Tap] 路=link url=\(url)")

                guard url.scheme == "reader",
                      url.host == "sentence",
                      let position = Int(url.lastPathComponent),
                      sentences.indices.contains(position)
                else { return .systemAction }

                tap(position)

                return .handled
            }
        )
    }

    /// 一栏多宽。栏数取 `columnCuts.count`，也就是分页端判定的那个数：两边都走
    /// `ReaderTypography` 这一条式子，「量的那一栏」和「画的那一栏」才会是同一个宽。
    private var columnWidth: CGFloat {
        ReaderTypography.columnWidth(
            contentWidth: contentWidth,
            columns: max(columnCuts.count, 1),
            body: bodySize
        )
    }

    /// 第 `index` 栏在 `slices` 里占的那一段（`columnCuts` 是给整页摊平的下标表）。
    /// 两头都夹进范围：换章那一瞬可能还拿着上一章算出来的栏位表，越界只能丢掉，不能崩。
    private func columnRange(
        _ index: Int
    ) -> Range<Int> {

        func clamp(_ value: Int) -> Int {
            min(max(value, 0), slices.count)
        }

        let start = clamp(
            columnCuts.indices.contains(index) ? columnCuts[index] : slices.count
        )
        let end = columnCuts.indices.contains(index + 1)
            ? max(clamp(columnCuts[index + 1]), start)
            : slices.count

        return start..<end
    }

    /// 这一栏：属于它的那一片字，一块一个 `Text`，末行按这一栏自己的挪量落到版心底。
    @ViewBuilder
    private func columnView(
        _ index: Int
    ) -> some View {

        let column = Array(slices[columnRange(index)])

        let groups = ReaderBlock.groups(
            in: column,
            sentences: sentences,
            chapterTitle: chapterTitle
        )

        let extra = columnStretch.indices.contains(index)
            ? columnStretch[index]
            : 0

        VStack(
            alignment: .leading,
            spacing: 0
        ) {

            if column.isEmpty, sentences.isEmpty, !blank {

                if let dividerTitle, !dividerTitle.isEmpty {

                    volumeDivider(
                        dividerTitle
                    )
                } else {

                    // 只在「这一章真的没有正文」时说这句话。首次布局还没跑完时
                    // 页也是空的，那种时候留白，别闪一下提示。
                    Text(
                        "这一章没有可朗读的正文（图片页或空白页）"
                    )
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(
                        maxWidth: .infinity,
                        alignment: .center
                    )
                    .padding(.top, 40)
                }
            }

            ForEach(
                Array(groups.enumerated()),
                id: \.offset
            ) { blockIndex, group in

                blockView(
                    group,
                    firstOnColumn: blockIndex == 0,
                    afterImage:
                        blockIndex > 0
                        && groups[blockIndex - 1][0].image != nil,
                    lineSpacingExtra: extra
                )
            }
        }
        .frame(
            width: columnWidth,
            alignment: .top
        )
    }

    /// 卷扉页：整面纸只印一行卷名，居中。
    ///
    /// 不参与测量——扉页那一面纸分页端按「零句」交出来（`PageLayout.paginate` 的
    /// `pages.isEmpty` 那条兜底就是一面），印什么、印多大都不改页数，所以这里想居中
    /// 就直接撑满这一栏的高，不必和行距账发生关系。
    @ViewBuilder
    private func volumeDivider(
        _ title: String
    ) -> some View {

        Text(
            title
        )
            .font(
                .system(
                    size: bodySize * 1.6,
                    weight: .semibold
                )
            )
            .foregroundStyle(
                theme.text
            )
            .multilineTextAlignment(
                .center
            )
            .fixedSize(
                horizontal: false,
                vertical: true
            )
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: .center
            )
    }

    /// 一块一个 `Text`：同段的句子连着走，行距从头到尾一个值。
    ///
    /// 图那一块不是一条 `Text`，是纸上的一个框：高宽一律现问 `ReaderTypography.imageFrame`
    /// （和分页端同一个函数、同两个输入），框里那张图什么时候解出来都不改这一块的高——
    /// 改了读者就看见栏底跳一下，而分页端留的那份白当场就不作数了。
    @ViewBuilder
    private func blockView(
        _ group: [PageSlice],
        firstOnColumn: Bool,
        afterImage: Bool,
        lineSpacingExtra: CGFloat
    ) -> some View {

        let runs = ReaderBlock.runs(
            for: group,
            sentences: sentences,
            chapterTitle: chapterTitle
        )

        let heading = runs.first?.kind == .heading

        // 基础行距 + 这一栏的垂直对齐拉伸。段前白 `gap` 里含不含一个 `lineSpacing`，
        // 由 `gap` 自己交回的 `lineSpacingSeams` 说（分页端数缝用的是同一个数）：
        // 含的那一种把抬过的 `spacing` 喂进去就跟着一起抬，纯段距那一种（紧跟图的图注）
        // 怎么挪行距都纹丝不动——分页端若把它当成能挪的缝，收尾就永远差那一条缝的量。
        let spacing = ReaderTypography.lineSpacing(
            size: bodySize,
            scale: lineScale
        ) + lineSpacingExtra

        let gap = ReaderBlock.gap(
            first: group[0],
            firstOnPage: firstOnColumn,
            sentences: sentences,
            size: bodySize,
            lineSpacing: spacing,
            afterImage: afterImage
        ).height

        if let image = group[0].image {

            figure(
                image
            )
            .padding(
                .top,
                gap
            )
        } else {

            Text(
                ReaderBlock.attributedString(
                    runs: runs,
                    body: bodySize,
                    width: columnWidth,
                    color: color(for:)
                )
            )
                .lineSpacing(spacing)
                .multilineTextAlignment(
                    heading ? .center : .leading
                )
                .frame(
                    maxWidth: .infinity,
                    alignment: heading ? .center : .leading
                )
                .fixedSize(
                    horizontal: false,
                    vertical: true
                )
                .padding(
                    .top,
                    gap
                )
        }
    }

    /// 一张图在纸上占的那一块。位置按书的规矩居中：一张比栏窄的图贴在左边看着就是没排完。
    private func figure(
        _ image: ChapterImage
    ) -> some View {

        ReaderFigureView(
            url: EPUBHref.resolve(
                href: image.href,
                relativeTo: chapterURL.deletingLastPathComponent()
            ),
            // 和分页端 `PageLayout.imageHeight` 同一个式子、同两个输入：那一面留了多少高，
            // 这里就画多大。`renderGuard` 那半 pt 是留给落纸的余量，不画进去。
            size: ReaderTypography.imageFrame(
                image,
                columnWidth: columnWidth,
                usableHeight: usableHeight
            )
        )
        .frame(
            maxWidth: .infinity,
            alignment: .center
        )
    }

    /// 当前句只换颜色，不换字号/字重：换了这页的行数就和测量结果对不上，
    /// 播到某一句字却掉到下一页去。
    private func color(
        for run: ReaderBlock.Run
    ) -> Color {

        let isActive = run.position == activePosition

        return isActive || activePosition == nil
            // 整页没有「正在读的那一句」时一律正常上色：关掉语音播报后
            // activePosition 是 nil，只判 isActive 会把每一行都涂成灰的，
            // 看起来像整页被压了透明度
            ? theme.text
            : theme.text.opacity(theme.inactiveOpacity)
    }
}

/// 纸上的一张图。
///
/// 框是死的：`.frame(width:height:)` 用的就是分页端那一份 `imageFrame`，图有没有解出来、
/// 解得多快都不改这一块的高。这一条不是讲究——栏高跟着解码走的话，读者看见的是「字先在那儿，
/// 图一到又挤走一行」，而分页端给这一张留的那份白当场作废（页尾那条红线反了）。
/// 所以没解出来之前这里就是一块纸色，什么都不画。
///
/// 解码一律走 ImageIO 的缩略图接口、并且挪出主线程：EPUB 里的插图常常是打印稿尺寸
/// （一张 2480×3508 的 JPEG 全量解码就是二十几兆内存），而纸上要的框最宽不过一栏。
/// 口径和封面那一条一样（`CoverFace.load`），按 2x 边长解、不放大——`imageFrame` 给出的宽
/// 本来就是 `pixelWidth / 2` 那一格，解到这一格刚好是屏幕上的 1:1。
struct ReaderFigureView: View {

    let url: URL

    let size: CGSize

    /// 解出来的那一份，连着它是**哪个 url** 解的：`CurlPageTurner` 的纸面缓存会拿同一个视图
    /// 换内容，只比 `url` 不比图就会把上一页的图印在这一页的框里。
    @State private var loaded: ReaderFigureLoader.Result?

    var body: some View {

        ZStack {
            if loaded?.url == url, let image = loaded?.image {

                Image(uiImage: image)
                    .resizable()
                    // 框本身等比（`imageFrame` 担保），装进去不拉伸；用 fit 而不是 fill 是
                    // 给「缩略图边长和框差一个取整零头」留白——fill 会把那一圈裁掉，还会溢出。
                    .scaledToFit()
            }
        }
        .frame(
            width: size.width,
            height: size.height
        )
        .task(id: ReaderFigureLoader.key(url: url, size: size)) {

            guard size.width >= 1, size.height >= 1 else { return }

            loaded = await ReaderFigureLoader.load(url: url, size: size)
        }
    }
}

/// 一张纸上的图从磁盘到位图这一段路：按需下采样 + 按「路径 × 目标边长」缓存。
///
/// 为什么按边长也进 key：同一张图在单栏那一档要 349pt 宽、双栏那一档只要 174pt。
/// 拿 174pt 那份去填 349pt 的框就是放大一倍，纸上是一团马赛克；反过来白解一倍像素。
enum ReaderFigureLoader {

    struct Key: Hashable {
        let path: String
        let maxPixelSize: Int
    }

    struct Result {
        let url: URL
        let image: UIImage
    }

    /// 命中与否都只问一次 JSON 之外的东西：NSCache 自己在内存告急时清，这一层的图
    /// 随时能从文件重解，所以不另设上限，也不需要「清空缓存」那类手动口径。
    private static let cache = NSCache<NSString, UIImage>()

    static func key(
        url: URL,
        size: CGSize
    ) -> Key {
        Key(
            path: url.path,
            maxPixelSize: Int(
                (max(size.width, size.height) * 2)
                    .rounded(.up)
            )
        )
    }

    static func load(
        url: URL,
        size: CGSize
    ) async -> Result? {

        let maxPixelSize = CGFloat(key(url: url, size: size).maxPixelSize)
        let cacheKey = "\(url.path)|\(Int(maxPixelSize))" as NSString

        if let hit = cache.object(forKey: cacheKey) {
            return Result(url: url, image: hit)
        }

        // 解码留在主线程之外：一张 3000px 的书内彩图原地解就是几十毫秒的账，压在
        // 翻页那一拍上就是「纸面卡一下」。（注：operation 必须走尾闭包，
        // `Task.detached(priority:, { … })` 这种把闭包写在括号里的形式，SDK 上
        // 重载匹配不上，报的是 `Success could not be inferred`。）
        let image = await Task.detached(priority: .userInitiated) {
            decode(url: url, maxPixelSize: maxPixelSize)
        }.value

        guard let image else {
            // [Images] 取证：解不出来在纸上就是一块白，屏上看不出是「文件不在了」还是「这张图坏了」。
            // #29 那一类（⌘R 之后解压出来的 EPUB 不在容器里）就是从这一行认出来的。
            print("[Images] 解不出 \(url.lastPathComponent)：\(url.path)")
            return nil
        }

        cache.setObject(image, forKey: cacheKey)

        return Result(url: url, image: image)
    }

    private static func decode(
        url: URL,
        maxPixelSize: CGFloat
    ) -> UIImage? {

        guard let source = CGImageSourceCreateWithURL(
            url as CFURL,
            nil
        ) else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(maxPixelSize, 1),
        ]

        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else {
            return nil
        }

        return UIImage(cgImage: thumbnail)
    }
}

/// 中缝贴着这一面的哪条竖边。
///
/// 不叫 SwiftUI 的 `Edge`：那个枚举在这个 SDK 上只给 `Edge.Horizontal` 做参数用，
/// 类型本身拿不到（`.Horizontal` 不是它的成员），而这里要的本来就只是「左右」这一对。
enum ReaderSpineEdge: Equatable {

    /// 缝在我左边：我是摊的右半。
    case leading

    /// 缝在我右边：我是摊的左半。
    case trailing
}

/// 一张纸上「正文那一块」的边界。
///
/// 分页量的高度和纸上渲染的高本来就是同一个数，所以只在这里写一次减法：
/// 两边各写一份的话，改了纸忘了量，表现是每页最后两行掉到纸外面——纸不滚动，
/// 掉出去的那一行就是看不见（`ReaderPageView` 直接剪掉）。
@MainActor
enum ReaderPageBox {

    /// 屏幕顶 → 正文顶。页眉那一条，含它自己让开的灵动岛。
    static var textTop: CGFloat {
        ChapterRunningHead.totalHeight
    }

    /// 正文底 → 屏幕底：页码那一行 + home 指示条那一段。
    /// 顶上那段是 `textTop`（页眉行 + 灵动岛），这里和它同构。
    static var textBottom: CGFloat {
        PageNumberBar.reservedHeight
    }

    /// `size` 是 `readerContent` 那个 GeometryReader 的整屏尺寸（外层已经
    /// `ignoresSafeArea()`，探针量下来 852pt，不是安全区那份 759pt）。
    static func bodyArea(
        _ size: CGSize
    ) -> CGSize {

        CGSize(
            width: size.width,
            height: max(0, size.height - textTop - textBottom)
        )
    }
}

/// 这一屏的纸摊成几面，以及**交给分页器的那一块地方**。
///
/// 判据只有这张纸自己的尺寸，一处都不看设备型号（要求四）：`spreadAllowed` 问摊开以后每一面
/// 还容不容得下 `minSpreadLetters` 个字、以及每一面还是不是一页书的形状（高 ≥ 宽，
/// 手机横过来那条扁字幕就是被后一条挡住的）。所以转屏、分屏、台前调度、Mac 上那个能拉的
/// 窗口都自动按实际尺寸换档——同一条式子也保证换档用的宽和分页用的宽是同一个数，
/// 不会出现「判成双页了，可每一面排不下」。
///
/// 单独写一处是因为这个结论有三个问它的地方：卷页容器（`isSpread`，决定中缝在纸正中还是
/// 左边缘）、分页（吃 `leaf` 那份宽）、点两侧翻页（一翻是一面还是一摊）。各算各的迟早分家。
@MainActor
struct ReaderPaper {

    /// 一面纸的地方：双页时是整块地方对半切出来的那半张，单页时就是整块。
    ///
    /// 分页器和纸上渲染的都取它。`ReaderPageView` 那边不用传宽：hosting 视图实测到的
    /// 就是 UIKit 分给这一面的那段，两边本来就是同一个数。
    let leaf: CGSize

    /// 摊成左右两面，还是一面。
    let isSpread: Bool

    /// 双页时一次翻过的面数：一摊两面。
    ///
    /// 点两侧翻页按它走步长——只走一面的话，落点还在同一摊里，容器比的是摊，
    /// 一看「纸已经在这摊上了」就什么也不演，表现是「点了没反应」。
    var leafStep: Int {
        isSpread ? 2 : 1
    }

    init(
        size: CGSize,
        body: CGFloat
    ) {

        let area = ReaderPageBox.bodyArea(size)

        let spread = ReaderTypography.spreadAllowed(
            areaWidth: area.width,
            areaHeight: area.height,
            letter: ReaderBlock.letterWidth(body: body)
        )

        self.isSpread = spread
        self.leaf = CGSize(
            width: spread
                ? ReaderTypography.leafWidth(areaWidth: area.width)
                : area.width,
            height: area.height
        )
    }
}

/// 一张纸。翻页在 `CurlPageTurner` 手里：卷起来那一瞬间这一面是被单独摘出去渲染的
/// 一张纸，所以整屏都得是纸——灵动岛和 home 指示条那两段也跟着卷，
/// 不然翻起来像「只有正文在动」。
///
/// 块的位置全按「离屏幕边的绝对距离」写，最外层 `ignoresSafeArea()`。探针量过：
/// 铺满整屏的 hosting controller 会把窗口安全区原样传进 SwiftUI（`.probe/embed-frame-probe.swift`
/// 里那台机器：GeometryReader 只拿到 320x384，也就是上下各让掉 62/34），
/// 不显式忽略就会被再往下推一个安全区 —— 正文起点一偏，分页量的高度和渲染就对不上，页尾溢出。
/// 忽略之后 `.probe/safearea-probe.swift` 量到正文块起点和写进去的数一字不差
/// （写进去的那个数现在归 `ReaderPageBox`，`.probe/page-text-top-probe.swift` 接着量落点）。
struct ReaderPageView: View {

    let sentences: [Sentence]

    let slices: [PageSlice]

    let bodySize: CGFloat

    let lineScale: Double

    /// 这一页摊成几栏、每栏从 `slices` 的哪个下标起（`PageLayout.columnCuts`），
    /// 连同每栏的行距挪量（`columnStretch`）。透传给 `ReaderPageBody`。
    /// 默认单栏、不挪行距——探针的基线口径和章末页就是这一档。
    var columnCuts: [Int] = [0]
    var columnStretch: [CGFloat] = [0]

    /// 左右各让开的宽（`PageLayout.sideMargin`）。这一页的版心宽就是从纸宽里减掉它两遍，
    /// 所以它必须和分页端量高时用的是同一个数。
    let sideMargin: CGFloat

    /// 分页端那一份可用高（`PageLayout.usableHeight`）和这一章的 XHTML 位置，两样都只为
    /// 「画一张图」而穿过来：图框的高上限问前者，`href` 解成文件路径问后者。
    let usableHeight: CGFloat
    let chapterURL: URL

    let theme: ReaderTheme

    let chapterTitle: String

    let activePosition: Int?

    let tap: (Int) -> Void

    /// 页眉那行章名。画在纸上，翻页时和正文同方向走。
    let runningHead: String

    /// 顶栏唤出来时让它淡掉：同一位置摆两行章名看着就是糊的。
    let headOpacity: Double

    /// 这是不是一张有意留白的补位纸（双页摊不满时那半张，见 `CurlPageTurner` 口径 ④）。
    var blank = false

    /// 卷扉页的卷名（`ReaderPageBody.dividerTitle`）。nil = 正常那一页。
    var dividerTitle: String? = nil

    /// 中缝在我这一面的哪一条边上；单页时 nil。
    ///
    /// 有了它才画得出那道阴影：`.mid` 那一档 UIKit **不给静态的中缝阴影**（探针量过：
    /// 两面纸摊平时中缝是平的，只有卷起来过程中弧上有一道高光）。真书两面之间是有那道
    /// 凹下去的灰的，所以这一层得自己画。
    ///
    /// 它只盖自己那一条边距：宽就是 `sideMargin`，版心里的墨一条都不碰——中缝阴影压在字上
    /// 就成了「靠中缝那一列字发暗」。
    var spineEdge: ReaderSpineEdge?

    /// 屏幕顶 → 正文顶、正文底 → 屏幕底：全部走 `ReaderPageBox`，
    /// 和 `pageReader` 量的分页高是同一个数。以前这里写作
    /// `ChromeInsets.top + ChapterRunningHead.totalHeight`，把灵动岛让了两遍，
    /// 正文首行掉到 169.7pt（真机截图量的）。
    var body: some View {

        ZStack(alignment: .top) {
            // 底色铺满整屏：卷起来那一面得自己盖得住，不能透出背后那页的字。
            theme.background
                .ignoresSafeArea()

            // 这一页不许上下滑。以前这里套一层 `ScrollView`，兜的是「量矮了溢出一行」：
            // 那一行滚得到、翻不到。但套上滚动的代价是整页成了网页——手指竖着划一下
            // 纸就跟着走，而翻页、下拉关闭、左边缘返回三条手势都得先让开竖着的位移
            // （见 `ReaderView.swipeChanged` 那句「竖着划是给页内滚动和下拉关闭的」）。
            // 纸不该滚：字排不下是分页端的事。分页量高走的是和这里同一个排版器的行框
            // （渲染高从不比测量高矮），扣掉的正好是纸放得下的那么多，溢出的那一行剪掉。
            //
            // `GeometryReader` 不是多余的：`frame(maxHeight: .infinity)` **不封顶**——
            // 块上的 `fixedSize(vertical:)` 会无视提议把子视图撑到自己的固有高，
            // 于是 frame 跟着长高，`clipped()` 剪的就是那个已经变大的框。探针实测
            // （`.probe/page-text-top-probe.swift` 的 `PAGE_OVERFLOW=1`：四页字塞一面）：
            // 那样写墨一直画到 851.7pt，越过了 818pt 那条纸底。这里要的正是「纸多高
            // 就只画多高」，所以得把实测到的可用高当成硬边界喂回去。
            GeometryReader { paper in

                ReaderPageBody(
                    sentences: sentences,
                    slices: slices,
                    bodySize: bodySize,
                    lineScale: lineScale,
                    columnCuts: columnCuts,
                    columnStretch: columnStretch,
                    contentWidth: paper.size.width - sideMargin * 2,
                    sideMargin: sideMargin,
                    usableHeight: usableHeight,
                    chapterURL: chapterURL,
                    theme: theme,
                    chapterTitle: chapterTitle,
                    activePosition: activePosition,
                    blank: blank,
                    dividerTitle: dividerTitle,
                    tap: tap
                )
                .frame(
                    width: paper.size.width,
                    height: paper.size.height,
                    alignment: .top
                )
                .clipped()
            }
            .padding(.top, ReaderPageBox.textTop)
            .padding(.bottom, ReaderPageBox.textBottom)

            // 让开灵动岛的那一段在它自己内部（`ChapterRunningHead` 顶部那条 clear），
            // 这里再补一个 `ChromeInsets.top` 就是让两遍——页眉会掉到屏幕中间去。
            ChapterRunningHead(
                title: runningHead,
                color: theme.text.opacity(0.5)
            )
            .opacity(headOpacity)
            .animation(
                .easeOut(duration: 0.22),
                value: headOpacity
            )

            // 中缝那道凹下去的灰：只在双页时画，压在靠中缝的那一条边距上。
            // 排在最后（页眉之上）是有意的——它 `allowsHitTesting(false)`，不吃点击，
            // 而压在章名那行的边上比让字浮在阴影之上更像书。
            if let spineEdge {
                crease(
                    edge: spineEdge
                )
            }
        }
        .ignoresSafeArea()
    }

    /// 靠中缝那一条边的阴影：从缝那儿最深，往版心方向淡出去，宽度就是这一面的 `sideMargin`。
    ///
    /// 只写这一处，两面纸各画各的一半：左边那面的黑贴着它的右边、右边那面的黑贴着它的左边，
    /// 在中缝正好接上——不需要有一面纸知道自己是「左边那面」。
    private func crease(
        edge: ReaderSpineEdge
    ) -> some View {

        LinearGradient(
            stops: [
                .init(
                    color: theme.crease,
                    location: 0
                ),
                .init(
                    color: theme.crease.opacity(0.45),
                    location: 0.35
                ),
                .init(
                    color: .clear,
                    location: 1
                )
            ],
            startPoint: edge == .leading ? .leading : .trailing,
            endPoint: edge == .leading ? .trailing : .leading
        )
        .frame(
            width: sideMargin
        )
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: edge == .leading ? .leading : .trailing
        )
        .allowsHitTesting(
            false
        )
    }
}
