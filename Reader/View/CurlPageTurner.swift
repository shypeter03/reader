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
//  这张纸摊成一面还是左右两面（`isSpread`）由外层按**纸的实际宽度**判（见
//  `ReaderTypography.spreadAllowed`），这里只照着摆：`.min` 一面纸一个控制器，
//  `.mid` 两面纸一对控制器。
//

import SwiftUI
import UIKit

/// 卷页容器。喂进来的还是 `PageLayout` 那一份「一页一面」，摊成双页时两面一起算一摊。
///
/// 口径四处，都不打算绕回去：
/// ① 单页那一档（spine `.min`）一面纸只印一面：走的是 `isDoubleSided` 的默认值 false，
///    卷起来露的是 **UIKit 自己那张白卡纸**（不是我们的纸）。模拟器抓飞行帧量过：黑底页
///    那一张是 0.777 的亮灰，把 `host.view.backgroundColor` 从黑改成 clear 一点没变（0.737），
///    钉 traits 也治不到。想自己供纸背也不行——竖排单页只能走 spine `.min`，那里递 1 个
///    控制器报「要 2 个」、递 2 个报「要 1 个」。所以深色档那一层亮纸目前就是亮着翻过去，
///    没有兜住它。压暗盖层这条路试过并撤掉：α=0.75 的黑确实把飞行帧从 0.777 压到 0.192
///    （模拟器抓帧量的，且必须挂 window——挂 `pager.view` 压不住，curl 图层排在它的子视图之上），
///    代价是那 0.4s 整屏一起暗（正文 0.091 → 0.025），真机上看着比那张亮纸还碍事。
///    **双页那一档没有这个问题**：`.mid` 把 `isDoubleSided` 拧成 true，卷起来露的纸背是
///    我们供的那两面（探针录屏逐帧看过，近黑的四面纸翻一趟，全程没有亮页闪；唯一的亮处
///    是卷起那道弧上的高光，它不跟纸色走，真书也一样）。
/// ② 页序由外面定义（`startIndex` + `pageCount` + `content`），这里只认连续整数。
///    阅读页把「本章 + 已经预取好的相邻那一章」拼成同一段页序递进来（见 `ReaderView.TurnSpine`），
///    所以章边界不再是一堵墙：拖到本章最后一页还能往外拖，那一下就是普通的卷页，
///    落到相邻那一章的第一面上。跨章另有两条路：点屏幕两侧、音频播到章末自动推进。
/// ③ 纸换版（`revision`）就整份缓存作废重来。所以换版只许发生在「下标的含义真的整体变了」
///    的时候（目录跳章、字号/页宽变了重排）；跨章不算——那一段页序里两边都在，
///    每个下标对应的还是同一面纸。把跨章也算成换版的话，落点会被重新供页，
///    纸刚卷到底就被一张新生成的同类纸顶掉，看着就是闪一下白。
/// ④ 双页的一摊怎么配对：按**下标的奇偶**配（偶数是左面、奇数是右面），不按「离这段页序
///    开头第几面」配。理由只有一条：`TurnSpine` 的规矩是已给出去的下标永远不动，所以下标
///    的奇偶也不会动——配对因此是稳定的。照起点配就不是：上一章的纸预取到位那一下起点会挪，
///    于是每一摊的配对整体错开一面，读者正在看的那两面当场被拆开重排（表现是「页自己跳了
///    一下」）。代价是页序两头各可能差一面，那两面交**空白纸**（`content` 会拿到一个区间外
///    的下标，见 `ReaderView.pageView`）——摊不满的那半张纸就是书的头尾那一张白纸，
///    而书中间永远不会有它。
///
/// 翻页的节奏（`isRapidTurn`）：单独一下演完整卷页，连着点就不演了——第一下起手，
/// 后面每一下直接落页。理由很直白：卷页一段 0.35s，连着点五下要等将近两秒，
/// 而读者点得比纸快的时候，看到的就是「点了没反应」。宁可少演几段动画，
/// 也不要让手等纸。
///
/// 双页那一档的卷页是 0.41s 整趟（探针在进程内量 `curl-inputTime` 那组动画量的），
/// 而且**拧不动**：`pager.view.layer.speed` 对它没有任何影响（单页那一档可以），
/// 所以别再往「翻页提速」上想路子，要快只能换渲染层。
struct CurlPageTurner<Sheet: View>: UIViewControllerRepresentable {

    /// 这一张纸摊成左右两面（中缝在纸正中）还是就一面。
    ///
    /// 由外层按纸宽定，不看设备型号。**只能在 init 时定**：`spineLocation` 走
    /// `UIPageViewControllerOptionSpineLocationKey`，那是构造参数，装好以后不许再改
    /// （改了供页的成对数就对不上，UIKit 直接报异常）。所以换档是外层拿 `.id` 把这个容器
    /// 整个换掉——换档本来就要重新分页，纸的版式全变了，重建不是代价而是对得上。
    let isSpread: Bool

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
    ///
    /// 双页时可能拿到**区间外**的那个下标（0 或 1）：那是摊不满时补上的半张纸，
    /// 外层要交一张空白纸，不能拿它去印正文某一页（见口径 ④）。
    let content: (Int) -> Sheet

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(
        context: Context
    ) -> UIPageViewController {

        // 中缝在哪儿只有这一处能说：`.mid` = 纸正中，一次供两面；`.min` = 左边缘，一次一面。
        let pager = UIPageViewController(
            transitionStyle: .pageCurl,
            navigationOrientation: .horizontal,
            options: isSpread
                ? [
                    .spineLocation: NSNumber(
                        value: UIPageViewController.SpineLocation.mid.rawValue
                    )
                ]
                : nil
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
        /// 它要比那一段动画略长一点——正好卡在「上一下的纸刚落地又来一下」这个手感上。
        /// 再短就抓不到连点，再长就成了「正常速度翻页也没动画」。动画多长是量出来的：
        /// 单页那一档 0.35s 上下，双页（`.mid`）整趟 0.41s（探针在进程内采 `curl-inputTime`
        /// 那组动画量的），所以门槛跟着档走。
        ///
        /// 写成计算属性而不是 `static let`：这个 Coordinator 是泛型类型
        /// （`Coordinator<Sheet>`），泛型里不许有 static 存储属性。
        private var rapidWindow: TimeInterval {
            isSpread ? 0.5 : 0.4
        }

        private var pages: [Int: UIHostingController<Sheet>] = [:]

        /// 已经钉给这一层子树的外观。只有它变了才去刷 pager 和缓存里的每一面纸。
        private var appliedAppearance: UIUserInterfaceStyle = .unspecified

        // MARK: 摊（一次转场的单位）

        /// 一摊 = 单页时的一面纸，双页时的左右两面。
        ///
        /// 容器里所有记账都在这个单位上：`settled` / `inFlight` / `ours` 存的还是外面交进来
        /// 的那个面的下标，但**比较一律先换算成摊**。不按面的下标比的话，双页时声音推进到
        /// 右边那一面（下标 +1，摊没变）会被当成一次翻页——纸在原地自己卷一趟。
        ///
        /// 配对按下标的奇偶、偶数在左（文件头口径 ④）。这里用位移而不是除法：
        /// `>>` 在负数上就是向下取整，上一章的纸贴进来把起点挪成负数时配对照样稳；
        /// `/` 会朝零截，-1 就和不存在的 -0 撞成一摊了。
        private var isSpread: Bool {
            parent?.isSpread ?? false
        }

        /// 第 index 面属于第几摊。
        private func unit(of index: Int) -> Int {
            isSpread ? index >> 1 : index
        }

        /// 第 unit 摊包含哪些面。双页恒两个，其中可能有一个是两头补位的白纸。
        private func leaves(of unit: Int) -> [Int] {
            guard isSpread else { return [unit] }
            return [unit << 1, (unit << 1) + 1]
        }

        private func sameUnit(_ a: Int, _ b: Int) -> Bool {
            unit(of: a) == unit(of: b)
        }

        /// 这一面摊不摊得出来。单页就是页序本身；双页还包含两头那半张补位纸——
        /// 它虽然没字，但它那一摊里有真纸，所以得给它造一个控制器。
        private func presentable(_ index: Int) -> Bool {

            guard let parent, parent.pageCount > 0 else { return false }

            let last = parent.startIndex + parent.pageCount - 1

            guard isSpread else {
                return index >= parent.startIndex && index <= last
            }

            return unit(of: index) >= unit(of: parent.startIndex)
                && unit(of: index) <= unit(of: last)
        }

        /// 摊里那两面折回一个「真的在页序里」的下标。
        ///
        /// 必须折：两头补位的白纸不属于页序，把它原样报给外层，`pageBinding` 那一头
        /// 一看下标出了正文那段就当跨章处理（`crossIfNeeded`），表现是「翻到书的头一页
        /// 突然跳去上一章」。
        private func anchored(_ index: Int) -> Int {

            guard let parent, parent.pageCount > 0 else { return index }

            return min(
                max(index, parent.startIndex),
                parent.startIndex + parent.pageCount - 1
            )
        }

        // MARK: 供页

        private func controller(at index: Int) -> UIHostingController<Sheet>? {

            guard let parent, presentable(index) else { return nil }

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

        /// 第 unit 摊要交出去的那几个控制器：单页一个，双页恒两个。
        ///
        /// 双页那一档 UIKit 死要求两个（探针量过：`.mid` 下递 1 个直接抛
        /// "The number of provided view controllers (1) doesn't match the number required (2)"），
        /// 所以两头补位的那半张纸也得有控制器。
        ///
        /// 这一摊里一张真纸都没有就交 nil——`viewControllerBefore/After` 靠那条报
        /// 「页序到头了」，读者不能再往这头翻。
        private func controllers(forUnit unit: Int) -> [UIViewController]? {

            let wanted = leaves(of: unit)

            guard wanted.contains(where: presentable) else { return nil }

            let sheets = wanted.compactMap { controller(at: $0) }

            // 走到这里还想不出纸（parent 还没挂上）：按这一摊该有几面补几个空壳。
            // 少递一个在 `.mid` 那一档就是抛异常，宁可白一张纸。
            return sheets.isEmpty
                ? wanted.map { _ in UIViewController() }
                : sheets
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

            if let flying = inFlight {
                // 演着的时候又来了一次要求。比的是摊：双页时声音推进到这一摊的右面
                // （下标 +1、摊没变）不算「还要翻页」，攒进队列会让纸在落定以后
                // 自己再卷一趟。
                if !sameUnit(index, flying) {
                    queued = index
                    lastTurnRequestAt = Date()
                }
                return
            }

            rehostCachedPages()

            guard !sameUnit(index, settled) else { return }

            // 连点判定要在记账之前问：记完再问，问到的就是「这一下离它自己 0 秒」。
            let rapid = isRapidTurn()

            lastTurnRequestAt = Date()

            present(
                index,
                direction: index > settled ? .forward : .reverse,
                animated: abs(unit(of: index) - unit(of: settled)) == 1 && !rapid,
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

            // 只走一摊才演卷页：恢复进度、目录点章会一次跳几十面，
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
                controllers(forUnit: unit(of: index)) ?? [UIViewController()],
                direction: direction,
                animated: animated,
                completion: { _ in
                    // **落定只认这里**。代码发起的卷页 UIKit 不给 `didFinishAnimating`
                    // ——探针实测（`.probe/curl-callback-probe.swift`，iOS 26.5 模拟器）：
                    // 四次 `setViewControllers(animated:true)` 的 completion 全在 0.41s 回来，
                    // delegate 一条都没打。以前靠 0.8s 兜底计时落定，那 0.8s 里 `inFlight`
                    // 一直挂着，读者每一下点击都只被攒进 `queued`——纸不动，等到兜底才
                    // 不演动画地跳过去，表现就是「点右侧没反应」。
                    //
                    // 兜底计时留着：completion 也可能不来（页面切走、动画被系统掐掉），
                    // 那时它是唯一能把 `inFlight` 放下的东西。
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            self.settle(at: index, in: pager)
                        }
                    }
                }
            )

            // 剪枝放在这次转场之后：窗口按「纸上现在是哪摊」留，演到一半的那两摊留在里面。
            prune(around: unit(of: index))
        }

        /// 纸停在某一面上：把「在飞」放下、记住落点，再把攒着的下一次接上。
        ///
        /// 只认自己按下去的那一次（`inFlight == index`）：读者拖着纸演到一半时，
        /// `willTransitionTo` 已经把 `inFlight` 改成读者要去的那一面，这里就不该抢。
        ///
        /// **不动 `ours`**：那面记号要留到下一次转场起手才换。留着它是安全的那一侧
        /// ——万一某个系统版本对代码发起的卷页既给 completion 又给 `didFinishAnimating`，
        /// 后到的那一条会看见「落点 == 记号」而不回写、不解跟随锁；抹掉它就把我们自己
        /// 那一次认成读者拖的了，白解一次跟随（「页自己跳了一下，之后再也不跟音频」）。
        /// 而读者真拖的那一下必然落在**别的摊**上（同一摊拖不动），记号挡不到它。
        private func settle(
            at index: Int,
            in pager: UIPageViewController
        ) {

            guard inFlight == index else { return }

            inFlight = nil
            settleTimer?.cancel()
            settleTimer = nil
            settled = index

            rehostCachedPages()

            flushQueue(in: pager)
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

            guard !sameUnit(target, settled), inFlight == nil else { return }

            present(
                target,
                direction: target > settled ? .forward : .reverse,
                // 能攒进队列就说明纸还在演的时候读者又点了一下——那正是连点，
                // 落地这一下不再演一遍。
                animated: abs(unit(of: target) - unit(of: settled)) == 1 && !isRapidTurn(),
                in: pager
            )
        }

        private func armSettleWatchdog(for index: Int, in pager: UIPageViewController) {

            let work = DispatchWorkItem { [weak self] in

                guard let self, self.inFlight == index else { return }

                // 连 completion 都没来（正常路径落定在它那里，见 `present`）。
                // 别问纸上是什么样子了，直接把它摆成要去的那一摊。
                print("[Turn] 落页回调没来：按第 \(index) 面落定")

                self.present(
                    index,
                    direction: unit(of: index) >= unit(of: self.settled)
                        ? .forward
                        : .reverse,
                    animated: false,
                    in: pager
                )

                self.rehostCachedPages()
                self.flushQueue(in: pager)
            }

            settleTimer?.cancel()
            settleTimer = work

            // 卷页本身 0.35s 上下（双页那一档探针量到 0.41s），留一倍余量：
            // 抢在动画演完之前落定就是自己把纸拍平。
            DispatchQueue.main.asyncAfter(
                deadline: .now() + 0.8,
                execute: work
            )
        }

        private func prune(around center: Int) {

            // `center` 是一摊。卷起来那一瞬间要用到下一摊的纸，所以往后多留一摊。
            var window: Set<Int> = []

            for offset in -1...2 {
                window.formUnion(leaves(of: center + offset))
            }

            // 纸上和演到一半的那两摊不能丢：控制器一被扔掉，`index(of:)` 就认不出
            // 落页是哪一摊，页码回写不上——表现是「翻了页但下面进度还停在原来那页」。
            window.formUnion(leaves(of: unit(of: settled)))

            if let flying = inFlight {
                window.formUnion(leaves(of: unit(of: flying)))
            }

            pages = pages.filter { window.contains($0.key) }
        }

        /// 关掉 UIKit 自带的「点页面边缘翻页」。
        ///
        /// 必须关：点正文左右两侧已经是翻页的手势（见 `ReaderView.turnPage`），
        /// 两边都认就变成点一下翻两页。
        ///
        /// 只看这一层和它的直接子视图。再往里就是 `UIHostingController` 的正文，
        /// 那上面的点击归 SwiftUI（单击弹按钮、双击读那一句），碰不得。
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
        //
        // 协议只让一次交**一个**控制器（`viewControllerBefore/After` 的返回类型就是
        // `UIViewController?`），所以走纸这条路只能一面一面走：UIKit 拿「这一面后面是谁」
        // 往下问，配对是它自己按问到的顺序凑的。我们这边的规矩（偶数面在左、两面一摊）
        // 靠两件事撑住：`setViewControllers` 每次都交整摊（程序翻页），以及下标连续。
        //
        // 拖动那一下 UIKit 到底一次走一摊还是一面，探针造不出手指，验不了：
        // 所以落定那一条会打 `[Turn]` 把摊的奇偶报出来（见 `didFinishAnimating`）。
        // 真机上要是从来没有「没落在头一面」那一条，就是配对没错。

        func pageViewController(
            _ pager: UIPageViewController,
            viewControllerBefore controller: UIViewController
        ) -> UIViewController? {

            guard let at = index(of: controller) else { return nil }

            return neighbor(of: at, forward: false)
        }

        func pageViewController(
            _ pager: UIPageViewController,
            viewControllerAfter controller: UIViewController
        ) -> UIViewController? {

            guard let at = index(of: controller) else { return nil }

            return neighbor(of: at, forward: true)
        }

        /// 走纸时的下一面 / 上一面。到头的那一条按**摊**判：那一摊里一张真纸都没有，
        /// 就报 nil 说「这头翻不动了」——不然读者能一直翻进补位白纸里，而那里面什么都没有。
        private func neighbor(
            of index: Int,
            forward: Bool
        ) -> UIViewController? {

            let next = index + (forward ? 1 : -1)

            guard presentable(next),
                  controllers(forUnit: unit(of: next)) != nil
            else { return nil }

            return controller(at: next)
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

            // 是我们自己按下去的那一摊：兜底计时留着（那是同一段动画，不是读者拖的）。
            if let ours, sameUnit(index, ours) { return }

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

                // 取证（#169）：双页时纸落定应该落在「一摊的头一面」（偶数面在左，口径 ④）。
                // 没落在头一面上就意味着 UIKit 那一次拖走的不是一摊而是一面——配对得改。
                // 探针造不出手指，这条只能等真机日志坐实，所以它每次都报，不判错。
                if isSpread, (landed & 1) != 0 {
                    print(
                        "[Turn] 双页落点不在摊的头一面：landed=\(landed) "
                            + "纸上=\(pager.viewControllers?.compactMap { index(of: $0) } ?? [])"
                    )
                }

                // 比的是摊，不是面：双页时我们交出去的下标可能是摊里右边那一面（页码跟的是
                // 声音的落点），而落定以后 `viewControllers.first` 是左边那一面。按面比就
                // 把我们自己按的那一下认成了读者翻的，白解一次跟读的跟随锁。
                if completed, unit(of: landed) != ours.map({ unit(of: $0) }) {
                    // 读者自己翻的那一下：演到一半攒下的跟随安排不作数了，
                    // 手比声音先到，落哪儿就报哪儿（见 `ReaderView.noteManualTurn`）。
                    queued = nil

                    // 报出去的下标必须真的在页序里：摊里补位的那半张白纸不属于页序，
                    // 原样报上去会被 `pageBinding` 当成跨章落点。
                    let shown = anchored(landed)

                    parent?.page = shown
                    parent?.onUserTurn?(shown)
                }
            }

            rehostCachedPages()

            flushQueue(in: pager)
        }
    }
}
