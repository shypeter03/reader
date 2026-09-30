//
//  LaunchSplash.swift
//  Reader
//
//  开屏：纸色底，画面中下部一个翻书的图标，然后整幅交给书库。
//
//  冷启动真正的耗时只有 `books.json` 那一次解码，几十毫秒。所以这一层不是「等」，
//  是把系统启动页和书库之间那段没有内容的空档接上——不接的话首帧是「还没有书」
//  那个空状态闪一下，再蹦出列表，看着像坏了。
//
//  App 画出第一帧之前那段是 SpringBoard 的启动页（`Info.plist` 里 `UILaunchScreen`），
//  它不能动，只能填一块底色和一张静态图。这里只填底色，图标不在启动页那张图上：
//  那张要的是资源文件（位图/PDF），而「某一本书」被钉死进资源就意味着——换一本书、
//  换一版封面，启动页还停在旧的那本上。底色接底色本来就是无缝的，图标等 App 第一帧
//  淡入，看着是「东西出现了」而不是「东西跳了一下」。
//

import SwiftUI

/// 品牌那一枚：开屏用它，主屏幕图标也用它。
///
/// 说「也用它」不是修辞——`.probe/run-app-icon-render.sh` 编译的就是这个文件，图标那张
/// PNG 是从这里的一个 `BrandGlyph` 渲染出来的。形状、渐变、纸色只有一份定义，改这儿
/// 开屏和桌面一起跟着变；要是哪天出现第二处画它的代码，两边就会各走各的，而那种不一致
/// 只有换机器、换系统版本那天才看得出来。
enum Brand {

    /// 翻书那一下的符号。
    ///
    /// 换名字前先跑 `.probe/launch-symbol-probe.swift`：SF Symbol 是按系统版本进的，
    /// App 的部署目标比测试机老。旧系统上没这个名字只会得到 nil，表现是
    /// 「图标没了，只剩一块底色」——而且只在老机器上出现。
    static let glyph = "book.fill"

    static let glyphTop = Color(red: 0.40, green: 0.70, blue: 1.00)

    static let glyphBottom = Color(red: 0.08, green: 0.35, blue: 0.85)

    static var glyphGradient: LinearGradient {
        LinearGradient(
            colors: [glyphTop, glyphBottom],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// 那张「纸」的本色。开屏底色走的是资源目录里的 `LaunchBackground`（要跟系统启动页
    /// 无缝接上），图标只能用这里的定值：位图渲染时没有 appearance 可跟随。
    static let paper = Color(red: 0.97, green: 0.95, blue: 0.91)

    /// 展示名。开屏那行字用它，主屏幕下面那行由 `Info.plist` 的 `CFBundleDisplayName`
    /// 管——改名字要两处一起改。
    static let displayName = "纸声"
}

/// 符号本体，只画那本书、不带字。`side` 是字号（点）。
struct BrandGlyph: View {

    let side: CGFloat

    var body: some View {
        Image(systemName: Brand.glyph)
            .font(.system(size: side))
            .foregroundStyle(Brand.glyphGradient)
    }
}

/// 纸被挑起一角、冻在中间的那一下。主屏幕图标用它。
///
/// 主屏幕图标在 iOS 上是 SpringBoard 画的一张静态位图，没有动画这回事（Android 的自适应
/// 图标才行）。所以「书页在翻」只能取一瞬：右下角那一角纸掀起来、露出底下那条蓝——
/// 纸是正文，蓝是声音，翻书这件事留在形状里而不是留在时间里。
struct BrandPageCorner: View {

    /// 画布边长。所有尺寸按它取比例，换尺寸不用重算。
    let side: CGFloat

    /// 折痕离角多远，按边长取这一成。0.34 那一版量过：翻起来的那一页压住了右页的下沿，
    /// 看着像两个东西撞在一起，而不是一本书被翻开一角；0.26 留得住那道缝，
    /// 又还大到在 60pt 的格子里看得出来。
    private static let fold: CGFloat = 0.26

    /// 折页自由边往外拱的量，按折痕长度取这一成。0 就是两张直边拼的三角，看着像贴纸
    /// 而不是翻起来的纸。
    private static let bow: CGFloat = 0.10

    /// 折痕两个端点之间那段「原来那一角」的区域——掀开之后露出来的底。
    private struct Under: Shape {
        func path(in rect: CGRect) -> Path {
            let d = min(rect.width, rect.height) * BrandPageCorner.fold
            var p = Path()
            p.move(to: CGPoint(x: rect.maxX - d, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - d))
            p.closeSubpath()
            return p
        }
    }

    /// 掀起来的那一页背面：折痕为底、往左上翻过去的那个三角，两条自由边各往外拱一点。
    private struct Flap: Shape {
        func path(in rect: CGRect) -> Path {
            let d = min(rect.width, rect.height) * BrandPageCorner.fold
            let bow = d * BrandPageCorner.bow

            let creaseStart = CGPoint(x: rect.maxX - d, y: rect.maxY)
            let creaseEnd = CGPoint(x: rect.maxX, y: rect.maxY - d)
            let tip = CGPoint(x: rect.maxX - d, y: rect.maxY - d)

            var p = Path()
            p.move(to: creaseStart)
            // 原来那条底边翻上来后成了自由边，往左上拱。
            p.addQuadCurve(
                to: tip,
                control: CGPoint(x: creaseStart.x - bow, y: (creaseStart.y + tip.y) / 2 - bow)
            )
            p.addQuadCurve(
                to: creaseEnd,
                control: CGPoint(x: (tip.x + creaseEnd.x) / 2 - bow, y: tip.y - bow)
            )
            p.closeSubpath()
            return p
        }
    }

    var body: some View {
        let d = side * Self.fold

        ZStack {

            Under()
                .fill(
                    LinearGradient(
                        colors: [Brand.glyphBottom, Brand.glyphTop],
                        startPoint: .bottom,
                        endPoint: .top
                    )
                )

            // 背面那条灰靠折痕：纸在折痕处被压住、往尖上去就吃光。
            Flap()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.90, green: 0.88, blue: 0.84),
                            Color.white
                        ],
                        startPoint: UnitPoint(
                            x: (side - d / 2) / side,
                            y: (side - d / 2) / side
                        ),
                        endPoint: UnitPoint(
                            x: (side - d) / side,
                            y: (side - d) / side
                        )
                    )
                )
                // 投影落在纸面上、偏向左上：光从右上来，掀起来的角才会往左下投。
                .shadow(
                    color: Color.black.opacity(0.28),
                    radius: side * 0.014,
                    x: -side * 0.006,
                    y: -side * 0.006
                )
        }
        .frame(width: side, height: side)
    }
}

/// 主屏幕那一张：纸底 + 那本书 + 右下角冻住的纸角。
///
/// 边到边都得填满、不许留透明：iOS 会把这张方图自己裁成圆角方块，透明像素在暗色壁纸上
/// 会发黑，而真正的圆角是系统给的——自己再画一圈圆就是两层边。
struct BrandIcon: View {

    let side: CGFloat

    /// 那本书在整张图里占多大。0.44 那一版在 1024 的方图上四周空得发虚，缩到主屏幕
    /// 那 60pt 就只剩一个点；再往上就顶到右下角那一角翻纸（那条缝是图标唯一的细节）。
    private static let glyphRatio: CGFloat = 0.50

    var body: some View {
        ZStack {

            Brand.paper

            BrandGlyph(side: side * Self.glyphRatio)

            BrandPageCorner(side: side)
        }
        .frame(width: side, height: side)
    }
}

/// 开屏什么时候收，条件都在这儿。
///
/// 不用 `ObservableObject`：收场只看两件事凑齐没有，而这层从头到尾没人观察它，
/// 轮询比挂一条订阅流省事，也不会有「忘了 mark 就把人关在门外」那种死法。
@MainActor
final class LaunchGate {

    static let shared = LaunchGate()

    /// 最短摆够这点时间。只等数据到手就收，冷启动等于闪一下。
    static let leastVisible: TimeInterval = 0.5

    /// 最多摆到这儿：加载链路真出意外，也到点放人。
    ///
    /// 开屏把用户关在门外，比多闪那一下糟糕得多。
    static let watchdog: TimeInterval = 2

    private(set) var booksLoaded = false

    private let openedAt = Date()

    private init() {}

    /// 书库第一份数据到手（`LibraryView.loadBooks` 报的）。
    func markBooksLoaded() {
        booksLoaded = true
    }

    /// 数据到手、且最短时长走满，两件事都齐了才回报。
    func waitUntilSettled() async {

        while !booksLoaded
                || Date().timeIntervalSince(openedAt) < Self.leastVisible {

            let age = Date().timeIntervalSince(openedAt)

            if age >= Self.watchdog || Task.isCancelled {
                return
            }

            try? await Task.sleep(
                nanoseconds: 40_000_000
            )
        }
    }
}

/// 根视图最上面那一层。收掉之后整层从层级里拿掉，之后不再出现。
struct LaunchLayer: View {

    @State private var gone = false

    var body: some View {

        if !gone {

            LaunchSplash {
                gone = true
            }
        }
    }
}

struct LaunchSplash: View {

    let onFinished: () -> Void

    /// 开着减弱动效的人要的是「别在我眼前动」：图标直接摆在那儿，不做淡入。
    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion

    /// 图标出现了多少。
    @State private var appeared: Double = 0

    @State private var handedOff = false

    /// 翻书那一下的符号尺寸。形状与颜色都在 `Brand`，这儿只管开屏这一版摆多大。
    private static let glyphSize: CGFloat = 56

    /// 「画面中下部」取屏高的这一成。
    ///
    /// 取比例而不是定死离底多远：874 高的机器上定死点数正好看，375×667 那种小屏
    /// 同样的数就掉到 home 指示条上了。
    private static let anchor: CGFloat = 0.70

    private static let iconGap: CGFloat = 16

    /// 字标字号。比 `Text` 默认的 footnote（13）大一档：这一行是品牌，不是说明文字，
    /// 13pt 挂在 56pt 的图标下面看着像图标的脚注。
    private static let wordSize: CGFloat = 17

    /// 字标字距。两字的词，4pt 刚好把「纸声」拉开成一个标志而不是一截正文。
    private static let wordTracking: CGFloat = 4

    /// 出现之前空这么长。
    ///
    /// 系统启动页 → 这一层是硬切，那块底色两边是同一个资源，所以接上无色差；
    /// 图标跟着硬切就出现会像闪。空 0.12s 再淡入，整条（0.12 + 0.22）压在
    /// `LaunchGate.leastVisible` 里走完——不然放行的那一下会停在「图标淡到一半」。
    private static let appearDelay: TimeInterval = 0.12

    private static let appearDuration: Double = 0.22

    private static let offDuration: Double = 0.24

    private static let appear = Animation.easeOut(
        duration: LaunchSplash.appearDuration
    )

    private static let off = Animation.easeIn(
        duration: LaunchSplash.offDuration
    )

    var body: some View {

        GeometryReader { area in

            ZStack {

                // 和系统启动页同一个资源：那段启动画面就是这块底色铺的，接上不会闪色。
                Color("LaunchBackground")
                    .ignoresSafeArea()

                // 底色不跟着淡：它要是也半透明，交接前那几帧会看见底下的空书库。
                mark
                    .position(
                        x: area.size.width / 2,
                        y: area.size.height * Self.anchor
                    )
            }
        }
        .opacity(handedOff ? 0 : 1)
        .task {
            await run()
        }
    }

    /// 图标 + 那行字。整组一起淡入，交棒时一起往外让一点，像是递出去而不是没了。
    private var mark: some View {

        VStack(
            spacing: Self.iconGap
        ) {

            BrandGlyph(side: Self.glyphSize)

            // 字标：加重的中字 + 一点字距 + 那本书用的同一条渐变。
            //
            // `design: .rounded` 这类「换个字体长相」的路子对中文是空的：系统字体只有拉丁
            // 部分有圆体，中文回落到苹方，能动的只有字号、字重和字距这三样。
            //
            // 也只有这一行是我们能排版的。主屏幕图标下面那行字由 SpringBoard 用系统字体画，
            // 我们能改的只有 `Info.plist` 里那串文字本身——所以名字取 `Brand.displayName`，
            // 开屏这行和桌面那行同名，改名字两处一起改。
            Text(Brand.displayName)
                .font(
                    .system(
                        size: Self.wordSize,
                        weight: .medium
                    )
                )
                .tracking(Self.wordTracking)
                .foregroundStyle(Brand.glyphGradient)
        }
        .opacity(appeared)
        .scaleEffect(0.96 + 0.04 * appeared)
        .scaleEffect(handedOff ? 1.05 : 1)
    }

    // MARK: - 时间线

    private func run() async {

        if reduceMotion {

            appeared = 1
        } else {

            try? await Task.sleep(
                nanoseconds: UInt64(Self.appearDelay * 1_000_000_000)
            )

            withAnimation(Self.appear) {
                appeared = 1
            }
        }

        await LaunchGate.shared.waitUntilSettled()

        withAnimation(Self.off) {
            handedOff = true
        }

        try? await Task.sleep(
            nanoseconds: UInt64(Self.offDuration * 1_000_000_000)
        )

        onFinished()
    }
}
