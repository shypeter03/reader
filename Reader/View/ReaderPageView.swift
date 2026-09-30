//
//  ReaderPageView.swift
//  Reader
//
//  一页正文。渲染口径必须与 `PageLayout` 的测量口径逐字对应——字号、行距、
//  段首缩进、块怎么切、页边距全部走 `ReaderTypography` 和 `ReaderBlock`，
//  任何一处只在一边改，页高就会算错，表现是「字溢到下一页」或整页空一半。
//

import SwiftUI

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

    /// 版心宽（纸上正文那一块的宽，已经让开左右边距）。硬换行的落点按它算，
    /// 必须和 `ReaderBlock.height` 量的是同一个数——两边各算各的，页尾就溢出。
    let contentWidth: CGFloat

    /// 底色与字色。不参与测量，只参与渲染。
    let theme: ReaderTheme

    /// 章标题。正文第一句常常就是它本身，要按标题排而不是跟着正文走。
    let chapterTitle: String

    /// 正在朗读的句子下标；nil 表示本页没有正在播的句子
    let activePosition: Int?

    let tap: (Int) -> Void

    var body: some View {

        let groups = ReaderBlock.groups(
            in: slices,
            sentences: sentences,
            chapterTitle: chapterTitle
        )

        VStack(
            alignment: .leading,
            spacing: 0
        ) {

            if slices.isEmpty, sentences.isEmpty {

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

            ForEach(
                Array(groups.enumerated()),
                id: \.offset
            ) { index, group in

                blockView(
                    group,
                    firstOnPage: index == 0
                )
            }
        }
        .padding(
            .horizontal,
            ReaderTypography.horizontalMargin
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

    /// 一块一个 `Text`：同段的句子连着走，行距从头到尾一个值。
    @ViewBuilder
    private func blockView(
        _ group: [PageSlice],
        firstOnPage: Bool
    ) -> some View {

        let runs = ReaderBlock.runs(
            for: group,
            sentences: sentences,
            chapterTitle: chapterTitle
        )

        let heading = runs.first?.kind == .heading

        Text(
            ReaderBlock.attributedString(
                runs: runs,
                body: bodySize,
                width: contentWidth,
                color: color(for:)
            )
        )
            .lineSpacing(
                ReaderTypography.lineSpacing(size: bodySize, scale: lineScale)
            )
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
                ReaderBlock.gap(
                    first: group[0],
                    firstOnPage: firstOnPage,
                    sentences: sentences,
                    size: bodySize,
                    lineSpacing: ReaderTypography.lineSpacing(
                        size: bodySize,
                        scale: lineScale
                    )
                )
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

    /// 正文底 → 屏幕底：home 指示条那一段。
    static var textBottom: CGFloat {
        ChromeInsets.bottom
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

    let theme: ReaderTheme

    let chapterTitle: String

    let activePosition: Int?

    let tap: (Int) -> Void

    /// 页眉那行章名。画在纸上，翻页时和正文同方向走。
    let runningHead: String

    /// 顶栏唤出来时让它淡掉：同一位置摆两行章名看着就是糊的。
    let headOpacity: Double

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
                    contentWidth: paper.size.width - ReaderTypography.horizontalMargin * 2,
                    theme: theme,
                    chapterTitle: chapterTitle,
                    activePosition: activePosition,
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
        }
        .ignoresSafeArea()
    }
}
