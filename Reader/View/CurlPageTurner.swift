//
//  CurlPageTurner.swift
//  Reader
//
//  书本式翻页容器： UIKit `UIPageViewController` 的 `.pageCurl` 转场。
//  卷页的弧形折痕、纸的背面、贴边阴影都由它渲染，这一层只负责供页和把页码同步回 SwiftUI。
//
//  纸有多大由这层的 frame 说：卷页照着 `pager.view.bounds` 画，所以阅读页那边把它
//  撑到整屏（见 `ReaderView.readerContent` 的 `ignoresSafeArea`），整屏就是一张纸，
//  灵动岛和 home 指示条那两段也跟着卷。撑不满的表现就是「只有中间在翻」。
//

import SwiftUI
import UIKit

/// 一屏一页的卷页容器。喂进来的还是 `PageLayout` 那一份「一页一面」。
///
/// 口径三处，都不打算绕回去：
/// ① 一面纸只印一面：走的是 `isDoubleSided` 的默认值 false，卷起来露的是 **UIKit 自己那张
///    白卡纸**（不是我们的纸）。模拟器抓飞行帧量过：黑底页那一张是 0.777 的亮灰，
///    把 `host.view.backgroundColor` 从黑改成 clear 一点没变（0.737），钉 traits 也治不到。
///    想自己供纸背也不行——竖排单页只能走 spine `.min`，那里递 1 个控制器报「要 2 个」、
///    递 2 个报「要 1 个」。所以深色档那一层亮纸目前就是亮着翻过去，没有兜住它。
///    压暗盖层这条路试过并撤掉：α=0.75 的黑确实把飞行帧从 0.777 压到 0.192（模拟器抓帧量的，
///    且必须挂 window——挂 `pager.view` 压不住，curl 图层排在它的子视图之上），
///    代价是那 0.4s 整屏一起暗（正文 0.091 → 0.025），真机上看着比那张亮纸还碍事。
///    真机上若发现落页错开一格，说明要按书帖重排页序，不是改一行开关。
/// ② 页序由外面定义（`startIndex` + `pageCount` + `content`），这里只认连续整数。
///    阅读页把「本章 + 已经预取好的相邻那一章」拼成同一段页序递进来（见 `ReaderView.TurnSpine`），
///    所以章边界不再是一堵墙：拖到本章最后一页还能往外拖，那一下就是普通的卷页，
///    落到相邻那一章的第一面上。跨章另有两条路：点屏幕两侧、音频播到章末自动推进。
/// ③ 纸换版（`revision`）就整份缓存作废重来。所以换版只许发生在「下标的含义真的整体变了」
///    的时候（目录跳章、字号/页宽变了重排）；跨章不算——那一段页序里两边都在，
///    每个下标对应的还是同一面纸。把跨章也算成换版的话，落点会被重新供页，
///    纸刚卷到底就被一张新生成的同类纸顶掉，看着就是闪一下白。
///
/// 翻页的节奏（`isRapidTurn`）：单独一下演完整卷页，连着点就不演了——第一下起手，
/// 后面每一下直接落页。理由很直白：卷页一段 0.35s，连着点五下要等将近两秒，
/// 而读者点得比纸快的时候，看到的就是「点了没反应」。宁可少演几段动画，
/// 也不要让手等纸。
struct CurlPageTurner<Sheet: View>: UIViewControllerRepresentable {

    /// 这一段页序的第一面是第几面。默认 0（一整份页序从头开始）。
    ///
    /// 它存在的唯一理由：跨章那一下要让纸连续，而纸连续就意味着页序不能每章都从 0 数起
    /// ——新章的第一面接在本章最后一面后面（下标 +1），本章前面还留着上一章的纸（下标为负）。
    /// 只有「不进新纸、也不丢旧纸」的挪动才允许下标不动，所以这里是一段带起点的区间，
    /// 而不是 `0..<pageCount`。
    var startIndex: Int = 0

    let pageCount: Int

    /// 这一批页属于哪一版页序。换版时整份缓存作废重来——同一个下标可能正好撞得上，
    /// 内容却是另一本书的另一章。
    let revision: String

    /// 纸上这一面的全部输入（正文、字号、高亮那一句、页眉让没让位……）。
    ///
    /// 缓存里的页只在这个值变了以后才重画。以前每次 `updateUIViewController` 都无条件
    /// 重排整窗口那 4~5 页文本，而触发更新的常常只是页码动了一格：动画起手的那一帧
    /// 全花在重排上，点两侧翻页就看着卡一下。
    let contentRevision: String

    /// 纸色。UIKit 那层只认 `UIColor`：卷起来的那一面、以及它背后的 pager 视图，
    /// 都得自己刷一遍，不然深色模式下翻起页来是一张亮纸。
    let paper: UIColor

    /// 这一层按哪套 traits 上色（由主题定，见 `ReaderTheme.userInterfaceStyle(matching:)`）。
    ///
    /// 光喂动态色不够：动态色是「 drawing 时问一次宿主视图的 traits」，而翻页的纸
    /// 是字典里缓存的那些 `UIHostingController`——它们大多数时刻不在视图树里，
    /// 系统从浅色切到深色时没人通知它们，traits 就停在切之前那一档。于是底色已经
    /// 黑了，翻起来那张纸还是亮的（用户报的样子）。这里把 traits 钉到主题那一档，
    /// pager 自己、缓存里的每一面纸、以及 UIKit 卷页内部拿它算的纸背与贴边阴影
    /// 一起跟着走，不存在「某一处忘了刷」。
    let appearance: UIUserInterfaceStyle

    @Binding
    var page: Int

    /// 读者自己拖出来的那一下，带上落在第几面。外层拿它判「这一页在声音的哪一边」，
    /// 决定音频接下来还能不能把页码带走（见 `ReaderView.noteManualTurn`）。
    var onUserTurn: ((Int) -> Void)? = nil

    /// 第 index 面。控制器按窗口缓存复用，所以它必须是纯函数。
    let content: (Int) -> Sheet

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(
        context: Context
    ) -> UIPageViewController {

        let pager = UIPageViewController(
            transitionStyle: .pageCurl,
            navigationOrientation: .horizontal,
            options: nil
        )

        pager.dataSource = context.coordinator
        pager.delegate = context.coordinator

        // 纸色刷到 pager 自己那层：卷页时四周露出来的就是它。
        pager.view?.backgroundColor = paper

        // 先把外观钉上再供页：第一面纸是在 `attach` 里现造的，晚一步它就按
        // 继承来的（可能还是上一档的）traits 渲染出来了。
        context.coordinator.attach(self, showing: clampedIndex, in: pager)

        return pager
    }

    func updateUIViewController(
        _ pager: UIPageViewController,
        context: Context
    ) {
        context.coordinator.reconcile(self, showing: clampedIndex, in: pager)
    }

    private var clampedIndex: Int {
        let last = startIndex + pageCount - 1

        guard pageCount > 0 else { return startIndex }

        return min(max(page, startIndex), last)
    }
}

extension CurlPageTurner {

    @MainActor
    final class Coordinator: NSObject,
        UIPageViewControllerDataSource,
        UIPageViewControllerDelegate {

        private var parent: CurlPageTurner?

        private var revision = ""

        private var contentRevision = ""

        /// 缓存里的页还留着旧内容，等纸停下来再换。
        private var contentDirty = false

        /// 已经落在纸上的那一面。只有动画演完了才改它，所以它是「纸上现在是哪页」的唯一说法。
        private var settled = -1

        /// 正在演的那一次翻页的目标页；nil = 纸上没在动。
        ///
        /// 它非空的时候绝不能再来一次 `setViewControllers`：演到一半按下去会把纸弹回原地，
        /// 读者看到的就是「划了没反应」。那种要求先攒进 `queued`。
        private var inFlight: Int?

        /// 演着的时候又收到的那一个页码，落定以后接上。
        private var queued: Int?

        /// 我们自己按下去的那一次落页。UIKit 要是把它当成「用户翻的」报回来，
        /// 靠它挡掉 `onUserTurn`——那一下会把跟随的口径改成人手定的，误报就等于
        /// 「页自己翻了一下，之后再也不跟音频了」。
        private var ours: Int?

        /// 落页回调的兜底计时。回调没来（页面切走、动画被系统掐掉）时，
        /// `inFlight` 会一直挂着，之后每一次翻页都被攒进队列——那是永久卡住。
        private var settleTimer: DispatchWorkItem?

        /// 上一次「要翻页」的请求什么时候到的。连点判据就靠它。
        private var lastTurnRequestAt = Date.distantPast

        /// 两下点击挨得比这个近就算连点：后到的那一下不再演整段卷页，直接落页。
        ///
        /// 卷页本身 0.35s 上下，所以这个数比它略大一点——正好卡在
        /// 「上一下的纸刚落地又来一下」这个手感上。再短就抓不到连点，
        /// 再长就成了「正常速度翻页也没动画」。
        ///
        /// 写成计算属性而不是 `static let`：这个 Coordinator 是泛型类型
        /// （`Coordinator<Sheet>`），泛型里不许有 static 存储属性。
        private var rapidWindow: TimeInterval { 0.4 }

        private var pages: [Int: UIHostingController<Sheet>] = [:]

        /// 已经钉给这一层子树的外观。只有它变了才去刷 pager 和缓存里的每一面纸。
        private var appliedAppearance: UIUserInterfaceStyle = .unspecified

        // MARK: 供页

        private func controller(at index: Int) -> UIViewController? {

            guard let parent,
                  index >= parent.startIndex,
                  index < parent.startIndex + parent.pageCount
            else { return nil }

            if let hit = pages[index] {
                return hit
            }

            let host = UIHostingController(
                rootView: parent.content(index)
            )

            // 纸色刷两遍，各管一件事：`view.backgroundColor` 是给卷页那层用的
            // （翻起来露出的纸背照它上色，`.clear` 就是白的），正文那层自己还会
            // 再铺一遍 `theme.background`（见 `ReaderPageView`）：卷起来那一瞬间
            // 这一面是被单独摘出去渲染的一张纸，得自己盖得住，不能透出底下那页的字。
            host.view.backgroundColor = parent.paper
            host.overrideUserInterfaceStyle = parent.appearance

            pages[index] = host

            return host
        }

        private func index(of controller: UIViewController) -> Int? {
            pages.first { $0.value === controller }?.key
        }

        // MARK: 生命周期

        func attach(
            _ parent: CurlPageTurner,
            showing index: Int,
            in pager: UIPageViewController
        ) {

            self.parent = parent
            self.revision = parent.revision
            self.contentRevision = parent.contentRevision

            applyAppearance(parent.appearance, in: pager)
            present(index, direction: .forward, animated: false, in: pager)
            suppressEdgeTap(in: pager)
        }

        func reconcile(
            _ parent: CurlPageTurner,
            showing index: Int,
            in pager: UIPageViewController
        ) {

            let changedRevision = parent.revision != revision

            self.parent = parent

            // 换深浅档（系统切了、或主题从「跟随」换成夜间）走这条：外观先钉上，
            // 再把缓存里那几面纸的 traits 一起改过来。这一步不能并入 `rehostCachedPages`
            // ——那条只看内容口径，而「系统切了深浅」在 `themeRaw` 里根本不留痕迹。
            applyAppearance(parent.appearance, in: pager)

            // 换主题（含切深浅色）只改纸色，这里跟着刷一层。
            pager.view?.backgroundColor = parent.paper

            if changedRevision {
                revision = parent.revision
                contentRevision = parent.contentRevision
                contentDirty = false
                pages.removeAll()
                inFlight = nil
                queued = nil
                ours = nil
                settleTimer?.cancel()
                settleTimer = nil
                present(index, direction: .forward, animated: false, in: pager)
                suppressEdgeTap(in: pager)
                return
            }

            // 一章的正文会被补好几次（AI 标注、音频落进来），已缓存的每页都得跟着换。
            // 但「补了好几次」不等于「纸上的字变了」：只有输入真变了才重排。
            if parent.contentRevision != contentRevision {
                contentRevision = parent.contentRevision
                contentDirty = true
            }

            if inFlight != nil {
                if index != inFlight {
                    queued = index
                    lastTurnRequestAt = Date()
                }
                return
            }

            rehostCachedPages()

            guard index != settled else { return }

            // 连点判定要在记账之前问：记完再问，问到的就是「这一下离它自己 0 秒」。
            let rapid = isRapidTurn()

            lastTurnRequestAt = Date()

            present(
                index,
                direction: index > settled ? .forward : .reverse,
                animated: abs(index - settled) == 1 && !rapid,
                in: pager
            )

            // 它自带的「点边缘翻页」每次转场以后都可能重新装上，得跟着补关。
            suppressEdgeTap(in: pager)
        }

        private func present(
            _ index: Int,
            direction: UIPageViewController.NavigationDirection,
            animated: Bool,
            in pager: UIPageViewController
        ) {

            let first = controller(at: index) ?? UIViewController()

            // 只走一格才演卷页：恢复进度、目录点章会一次跳几十面，
            // 给那种跳转配一次卷页，看着就是「跳页还带了个动画」。
            //
            // 我们自己按下去的那一次一律先记账，演不演动画都记：不演动画的那一次
            // UIKit 也可能回一次 `didFinishAnimating`，不记下来就被当成「读者自己翻的」，
            // 白解一次跟读的跟随锁——表现是「页自己跳了一下，之后再也不跟音频」。
            ours = index

            if animated {
                inFlight = index
                armSettleWatchdog(for: index, in: pager)
            } else {
                inFlight = nil
                settleTimer?.cancel()
                settleTimer = nil
                settled = index
            }

            pager.setViewControllers(
                [first],
                direction: direction,
                animated: animated,
                completion: nil
            )

            // 剪枝放在这次转场之后：窗口按「纸上现在是哪面」留，演到一半的那两面留在里面。
            prune(around: index)
        }

        /// 把外观钉到整棵卷页子树上：pager 自己 + 缓存里的每一面纸。
        ///
        /// 为什么要显式钉：这三处颜色（pager 底、纸背、纸上的正文）都来自同一份动态
        /// `UIColor`，取值要看宿主视图的 traits。而「宿主是谁」在切深浅的那一刻最不可靠
        /// ——缓存里那几页十有八九不在视图树里，`UIHostingController` 收不到 trait 更新，
        /// 等它被卷到纸上时用的还是切之前那一档。钉死之后不存在「哪一处按错的档解」，
        /// 夜间档配系统浅色也不会再让页眉那种 `.secondary` 语义色解成深灰。
        private func applyAppearance(
            _ appearance: UIUserInterfaceStyle,
            in pager: UIPageViewController
        ) {

            guard appearance != appliedAppearance else { return }

            appliedAppearance = appearance
            pager.overrideUserInterfaceStyle = appearance

            for host in pages.values {
                host.overrideUserInterfaceStyle = appearance
            }
        }

        /// 把缓存里的页换成最新一份内容。
        ///
        /// 只在纸停着的时候换：①整窗口重排正好压在动画起手那一帧，白卡一下；
        /// ②卷起来的那面是被单独摘出去渲染的纸，换到一半就是「半页混着两页内容」。
        private func rehostCachedPages() {

            guard contentDirty, let parent else { return }

            contentDirty = false

            for (page, host) in pages {
                host.rootView = parent.content(page)
                // 换主题走的也是这条路（纸色在内容口径里）：缓存里那几面的纸背跟着换，
                // 不然换了夜间档，翻页时露出来的还是上一档那张纸。
                host.view.backgroundColor = parent.paper
            }
        }

        /// 这一下是不是连点里的后一下。
        ///
        /// 连点时不再每一下都演满整段卷页（0.35s × 五下 = 快两秒，读者点得比纸快，
        /// 手感就是「点了没反应」），后到的那几下直接落页；单独一下照旧演完整卷页。
        private func isRapidTurn() -> Bool {
            Date().timeIntervalSince(lastTurnRequestAt) < rapidWindow
        }

        /// 动画演完以后把攒下的那一次接上。
        private func flushQueue(in pager: UIPageViewController) {

            guard let target = queued else { return }

            queued = nil

            guard target != settled, inFlight == nil else { return }

            present(
                target,
                direction: target > settled ? .forward : .reverse,
                // 能攒进队列就说明纸还在演的时候读者又点了一下——那正是连点，
                // 落地这一下不再演一遍。
                animated: abs(target - settled) == 1 && !isRapidTurn(),
                in: pager
            )
        }

        private func armSettleWatchdog(for index: Int, in pager: UIPageViewController) {

            let work = DispatchWorkItem { [weak self] in

                guard let self, self.inFlight == index else { return }

                // 回调没来。别问纸上是什么样子了，直接把它摆成要去的那一面。
                print("[Turn] 落页回调没来：按第 \(index) 面落定")

                self.present(
                    index,
                    direction: index >= self.settled ? .forward : .reverse,
                    animated: false,
                    in: pager
                )

                self.rehostCachedPages()
                self.flushQueue(in: pager)
            }

            settleTimer?.cancel()
            settleTimer = work

            // 卷页本身 0.35s 上下，留一倍余量：抢在动画演完之前落定就是自己把纸拍平。
            DispatchQueue.main.asyncAfter(
                deadline: .now() + 0.8,
                execute: work
            )
        }

        private func prune(around center: Int) {

            // 卷起来那一瞬间要用到下一页，往后多留一面。
            var window = Set((center - 1)...(center + 2))

            // 纸上和演到一半的那两面不能丢：控制器一被扔掉，`index(of:)` 就认不出
            // 落页是第几面，页码回写不上——表现是「翻了页但下面进度还停在原来那页」。
            window.insert(settled)
            window.insert(settled + 1)
            if let flying = inFlight {
                window.insert(flying)
            }

            pages = pages.filter { window.contains($0.key) }
        }

        /// 关掉 UIKit 自带的「点页面边缘翻页」。
        ///
        /// 必须关：点正文左右两侧已经是翻页的手势（见 `ReaderView.turnPage`），
        /// 两边都认就变成点一下翻两页。
        ///
        /// 只看这一层和它的直接子视图。再往里就是 `UIHostingController` 的正文，
        /// 那上面的点击是「点哪句从哪句朗读」，碰不得。
        private func suppressEdgeTap(
            in pager: UIPageViewController
        ) {

            guard let view = pager.view else { return }

            for candidate in [view] + view.subviews {
                for gesture in candidate.gestureRecognizers ?? [] {
                    if gesture is UITapGestureRecognizer {
                        gesture.isEnabled = false
                    }
                }
            }
        }

        // MARK: DataSource

        func pageViewController(
            _ pager: UIPageViewController,
            viewControllerBefore controller: UIViewController
        ) -> UIViewController? {

            guard let at = index(of: controller) else { return nil }

            return self.controller(at: at - 1)
        }

        func pageViewController(
            _ pager: UIPageViewController,
            viewControllerAfter controller: UIViewController
        ) -> UIViewController? {

            guard let at = index(of: controller) else { return nil }

            return self.controller(at: at + 1)
        }

        // MARK: Delegate

        /// 读者拖动 / 我们自己按下去的那一次转场起手。
        ///
        /// 这里只认「纸正在动」，不当它是用户翻的：`ours` 才是那一次的记号。
        /// 也不上表：读者可以按住半秒以上，到点把纸拍平就是脱手。松手以后
        /// UIKit 一定会给一次 `didFinishAnimating`（完成和取消都给），队列在那儿接。
        func pageViewController(
            _ pager: UIPageViewController,
            willTransitionTo pendingViewControllers: [UIViewController]
        ) {

            guard let target = pendingViewControllers.first,
                  let index = index(of: target)
            else { return }

            inFlight = index

            guard index != ours else { return }

            settleTimer?.cancel()
            settleTimer = nil
        }

        func pageViewController(
            _ pager: UIPageViewController,
            didFinishAnimating finished: Bool,
            previousViewControllers: [UIViewController],
            transitionCompleted completed: Bool
        ) {

            // 落页认不出来（缓存里没有那个控制器）时也不能把状态留着：
            // `ours` / `inFlight` 一漏，下一次真翻页就被当成我们自己按的，
            // 页码再也不回写，表现是「翻两下就卡住」。所以先记下再清，最后统一判。
            let ours = self.ours

            self.ours = nil
            inFlight = nil
            settleTimer?.cancel()
            settleTimer = nil

            if let landed = pager.viewControllers?.first.flatMap({ index(of: $0) }) {
                settled = landed

                if completed, landed != ours {
                    // 读者自己翻的那一下：演到一半攒下的跟随安排不作数了，
                    // 手比声音先到，落哪儿就报哪儿（见 `ReaderView.noteManualTurn`）。
                    queued = nil

                    parent?.page = landed
                    parent?.onUserTurn?(landed)
                }
            }

            rehostCachedPages()

            flushQueue(in: pager)
        }
    }
}
