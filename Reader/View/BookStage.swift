//
//  BookStage.swift
//  Reader
//
//  书库 ↔ 阅读器之间那一趟：把书从架子上拿起来、放大、绕书脊摊开；退场反着走。
//
//  一轨到底。只有 `presentation` 这一个数（0 = 正好压在书库那张封面卡上，1 = 书已经
//  完全摊开成阅读页）。打开、合上、以及阅读页里那一下下拉/右滑写的都是它，所以任何
//  时候被手指按住，都能从当下那一格接着走，不用重放。
//
//  为什么不用 `matchedGeometryEffect`：那条路的插值挂在 transaction 的动画上，而这一趟
//  的进度是**手指直接改的**（下拉多少就摊开多少，松手才决定走完还是弹回）。共享几何在
//  中途按住时只能每帧重新播种，按住那一段就不是动画而是重放；而且它只给形状的连续，
//  给不了绕书脊那一下的透视、书口的纸边、和落在纸上的影子。两头由同一个数摆同一个框，
//  几何连续本来就已经拿到了，不必再多一套命名空间。
//
//  为什么不借阅读页那套卷页：`UIPageViewController` 没有「摊开到一半」的口子——程序翻页
//  只能整段跑（实测单页 0.35s、双页 `.mid` 0.41s，且 `.mid` 那一段连 `layer.speed` 都
//  拧不动，见 `.probe/spine-mid-probe.swift`），而这一趟要能被按住、能反向。所以进出场是
//  这一层自己的三维旋转，落定以后立刻交回真卷页：两段接得上，但不互相顶替。
//
//  画的是**一本精装书**，三条都是有意的：
//
//  ① 封面是一块刚性板，绕书脊那条边转，带透视。精装本的封面本来就是刚的，它跟着弯
//     反而是错的。
//  ② 纸的弯（圆柱形卷起那一小段）只有阅读页里那套真卷页有，这一层不假造：Core Animation
//     没有网格，要真弯得自己铺 mesh 上 Metal，为一趟进出场不值。
//  ③ 转角走到 90° 出头就停。书脊贴在屏幕左边，封面一过 90°，它的整个投影都翻到屏幕左边
//     外面去了——再往下转只是转一部看不见的机器。最后那一小段用淡出接住，不是让它停在纸上。
//
//  整页正文什么时候该露出来，是这一层最容易做错的一处，所以单独写成 `readerVisible`：
//  举起那一段整页是**不画**的。那本合着的书只有卡片那么大，把正文露出来就成了
//  「一张封面在一页字上飘」。到举起走完那一步，封面正好铺满整屏，正文在它底下已经排好；
//  从这一刻起封面每转一度，就有一竖条真的字被揭出来。两头在同一格碰面，所以既不会出现
//  「封面消失后正文突然长出来」，也不会闪一次重排。
//
//  落回卡上那一刻的像素一致性靠 `CoverFace`：封面图、裁法、圆角、那道 0.5pt 边都是
//  书库那张卡同一个视图出的，所以副本盖上去和真卡重叠看不出两层。
//

import SwiftUI

/// 一本**合着的**书的两份身份：封面图，加上没封面时那张书名底卡。
struct BookCover {

    let url: URL?

    let title: String
}

/// 那一趟的全部算式，一处都不碰视图。
///
/// 单独拆出来只为一件事：每一格都能拿像素去量（`.probe/book-stage-probe.swift`）。
/// 动画顺不顺只有真机说得上话，但「封面落回卡上时两个框是不是同一个」「举起走完那一刻
/// 整屏到底盖住了没有」「转到 60° 还剩多宽没揭出来」这些不是手感，是数。
struct BookStageGeometry {

    /// 整屏。和 `ReaderApp` 那层 `GeometryReader` 同一个坐标系——封面卡的框也是全屏坐标。
    let canvas: CGSize

    /// 那张卡此刻占的地方（`ReaderLauncher.frames` 现读那份，见它的注释）。
    let card: CGRect

    /// 0 = 压在卡上，1 = 完全摊开。
    let presentation: Double

    /// 举起这一段占整趟行程的比例，剩下全给封面绕脊转出去。
    ///
    /// 0.42 不是拍的：这一趟要办的两件事——「拿走」（连着底下书库往后退、暗幕压上来）和
    /// 「翻开」——本来就该各占一半，但举起那一段还兼着盖住整屏好让正文无声地换上来，
    /// 所以比转出去那一段稍短一点。真正的约束在另一头：它必须留出足够行程给转面，
    /// 否则正文是在最后 0.1s 里一下全露出来的。
    static let liftEnd = 0.42

    /// 封面最多开到这儿（度）。90° 以后整个投影已经在屏幕外，多出来的那几度只是让
    /// 纸背那一寸闪得过去，不是让它停在纸上。
    static let maxAngle: Double = 96

    /// 透视强度。SwiftUI 这个参数不是焦距，是 0...1 的比例；0.28 是探针量着定的：
    /// 再小看不出游离边被抬起来（那本书就成了在纸上平移的贴纸），再大封面左边会鼓出屏幕。
    static let perspective: Double = 0.28

    /// 卡片自己的圆角。落回卡上那一刻必须是同一个数，不然边缘会跳一圈。
    static let cardCorner: CGFloat = 12

    /// 淡出从这一段开始（此时转角已过 84°，剩下那点面积本来就在屏幕外了）。
    static let fadeStart: Double = 0.86

    /// 完全摊开那一步书占的地方：整屏。阅读页就待在这儿，一动不动。
    var openFrame: CGRect {
        CGRect(origin: .zero, size: canvas)
    }

    /// 举起这一段走到哪儿。线性——快慢由外面那条 spring 给，这里不再叠一层曲线。
    var lift: Double {
        ramp(presentation / Self.liftEnd)
    }

    /// 转这一段走到哪儿，过一道两头都缓的曲线：铰链从静止开始动，不该一上来就满速。
    var swing: Double {
        ease(ramp((presentation - Self.liftEnd) / (1 - Self.liftEnd)))
    }

    /// 那本合着的书此刻在屏幕上的框：卡 → 整屏。
    ///
    /// 长和宽各自插值，不等比。卡是 2:3、整屏是 0.46，等比放到整屏高度就必须先超出屏幕；
    /// 而封面按 fill + 裁 画（`CoverFace`），框变了图不会变形，变的只是露出来那一块和轮廓。
    var bookFrame: CGRect {
        let t = CGFloat(lift)

        return CGRect(
            x: card.minX * (1 - t),
            y: card.minY * (1 - t),
            width: card.width + (canvas.width - card.width) * t,
            height: card.height + (canvas.height - card.height) * t
        )
    }

    /// 书脊在 x 的哪儿。举起走完那一刻它就是屏幕左边那条 0。
    var spineX: CGFloat {
        bookFrame.minX
    }

    /// 圆角：合着的时候是卡那 12，举起走完那一刻必须是 0。
    ///
    /// 跟着 `lift` 而不是 `swing`：举起走完那一格，封面正好铺满整屏、正文就在它底下换上来，
    /// 这时要是还留着 12pt 圆角，屏幕四个角就是四块透明的圆缺口——底下缩小了的书库会从
    /// 四个角露出来（探针 `liftEnd` 那一格专门查四角）。而卡片那 12pt 在放大的这一段里
    /// 本来就相对越来越小，顺手收掉它，看着就是封面摊平成一张纸。
    var corner: CGFloat {
        Self.cardCorner * (1 - CGFloat(lift))
    }

    var angle: Double {
        Self.maxAngle * swing
    }

    /// 抬起来多少（转角的 sin）。盖住的宽度、影子的宽和浓淡都由它派生，
    /// 这样「抬得越高 = 影子越宽越淡」是同一个数推出来的，不会两处各写各的。
    var elevation: Double {
        sin(angle * .pi / 180)
    }

    /// 铰链那一下取**负角**。绕 (0,1,0) 转 θ 在 SwiftUI 的坐标系里（x 右、y 下、z 朝读者）
    /// 有 z' = -x·sinθ，x 为正的游离边会往屏幕里钻；要它朝读者抬起来只能反着转。
    /// 投影对不对归探针量：`.probe/run-book-stage-probe.sh` 抽的是逐列的板子上下沿。
    var hingeAngle: Double {
        -angle
    }

    /// 封面此刻还盖着多宽（正交估计；透视下实测会略宽一点，因为抬起来那条边离读者近、
    /// 被放大了）。落笔在探针里量，不在这里猜。
    var coveredWidth: CGFloat {
        max(0, bookFrame.width * CGFloat(cos(angle * .pi / 180)))
    }

    var frontVisible: Bool {
        angle < 90
    }

    /// 封面板的不透明度。
    var coverOpacity: Double {
        guard swing > Self.fadeStart else { return 1 }
        return max(0, (1 - swing) / (1 - Self.fadeStart))
    }

    /// 整页正文画不画（为什么是这一条而不是淡入淡出，见文件头）。
    var readerVisible: Bool {
        presentation >= Self.liftEnd
    }

    /// 书口那一小条纸边：跟着书一起长大，卡上 2pt、整屏 8pt。
    var pageEdge: CGFloat {
        2 + 6 * CGFloat(lift)
    }

    /// 书脊那一条装订。比纸边宽一点：那是封面绕过去的一道弧，不是一摞纸。
    var spineBand: CGFloat {
        3 + 9 * CGFloat(lift)
    }

    var shadowRadius: CGFloat {
        5 + 20 * CGFloat(lift)
    }

    var shadowY: CGFloat {
        3 + 13 * CGFloat(lift)
    }

    var shadowOpacity: Double {
        0.16 + 0.20 * lift
    }

    /// 抬起来的封面落在纸上的那道影子：贴着它此刻那条游离边，越高越宽越淡。
    /// 合着的时候 `elevation` 是 0，不透明度就是 0——纸上不该留印子。
    var castShadowWidth: CGFloat {
        10 + 26 * CGFloat(elevation)
    }

    var castShadowOpacity: Double {
        0.40 * elevation
    }

    /// 那道影子的起始 x：紧贴还盖着的那一段的右边缘。
    var castShadowX: CGFloat {
        spineX + coveredWidth
    }

    /// 不知道那张卡在哪时的落点（要求五.8 的回退）：屏幕中下方一张虚拟卡。
    ///
    /// 不是「让书从屏幕中心凭空长出来」——那条要求明确不要。中心偏下、按 2:3 起算，
    /// 和书库第一屏的卡差不多大，读者看到的仍然是一本从架子高度被拿起来的书。
    static func fallbackCard(canvas: CGSize) -> CGRect {
        let width = canvas.width * 0.42
        let height = width * 1.5

        return CGRect(
            x: (canvas.width - width) / 2,
            y: canvas.height * 0.62 - height / 2,
            width: width,
            height: height
        )
    }

    private func ramp(_ value: Double) -> Double {
        min(1, max(0, value))
    }

    private func ease(_ value: Double) -> Double {
        let t = ramp(value)
        return t * t * (3 - 2 * t)
    }
}

/// 那一趟的容器：底下是原样的阅读页，上面是那一本正在挪的书。
struct BookStage<Reader: View>: View {

    /// 0 = 压在封面卡上，1 = 完全摊开。由 `ReaderLauncher` 唯一持有。
    let presentation: Double

    let cover: BookCover

    /// 那张卡此刻占的地方；nil 走 `fallbackCard`。
    let card: CGRect?

    let canvas: CGSize

    /// 交出来的一页正文。它原样待在整屏上，转场期间既不平移到卡、也不缩成一小块：
    /// 缩的是那本书，不是阅读页。
    @ViewBuilder
    let reader: () -> Reader

    /// 纸色和阅读页同一个键（`ReaderTheme.storageKey`），不在这里再定一套。
    /// 两头各写一份颜色迟早分家：夜间档那本书的纸背必须是那张深纸。
    @AppStorage("readerTheme")
    private var themeRaw: String = ReaderTheme.paper.rawValue

    @Environment(\.colorScheme)
    private var systemScheme: ColorScheme

    var body: some View {

        let g = BookStageGeometry(
            canvas: canvas,
            card: card ?? BookStageGeometry.fallbackCard(canvas: canvas),
            presentation: presentation
        )

        ZStack {

            reader()
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity
                )
                .opacity(g.readerVisible ? 1 : 0)

            castShadow(g)

            if presentation < 0.999 {
                BookPlate(
                    geometry: g,
                    cover: cover,
                    theme: theme
                )
            }
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity
        )
        .ignoresSafeArea()
    }

    private var theme: ReaderTheme {
        ReaderTheme(rawValue: themeRaw) ?? .paper
    }

    /// 封面抬起来以后压在纸上的那道影子。只在转出去那一段画（`readerVisible`）：
    /// 举起那一段纸上还不该有字，也就不该有影子。
    ///
    /// 必须再乘一次 `coverOpacity`：影子是**封面**投的，封面淡出到底那一刻它跟着没了。
    /// 少了这一乘，`presentation` 走到 1、封面已经拆掉，这道 40% 的黑还会横在正文左边
    /// 一条 36pt 的带上——「转场结束不许残留阴影」说的就是它（探针 `open` 那一格量）。
    @ViewBuilder
    private func castShadow(
        _ g: BookStageGeometry
    ) -> some View {

        let strength = g.readerVisible
            ? g.castShadowOpacity * g.coverOpacity
            : 0

        Color.clear
            .overlay {
                LinearGradient(
                    colors: [
                        theme.crease,
                        theme.crease.opacity(0.35),
                        .clear,
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(
                    width: g.castShadowWidth,
                    height: g.canvas.height
                )
                .opacity(strength)
                .position(
                    x: g.castShadowX + g.castShadowWidth / 2,
                    y: g.canvas.height / 2
                )
            }
            .allowsHitTesting(false)
    }
}

/// 那一本书。正面是封面，转过 90° 以后是纸背（环衬）。
private struct BookPlate: View {

    let geometry: BookStageGeometry

    let cover: BookCover

    let theme: ReaderTheme

    var body: some View {

        ZStack {

            face
                .opacity(geometry.frontVisible ? 1 : 0)

            back
                .opacity(geometry.frontVisible ? 0 : 1)
        }
        .frame(
            width: geometry.bookFrame.width,
            height: geometry.bookFrame.height
        )
        .clipShape(
            RoundedRectangle(
                cornerRadius: geometry.corner,
                style: .continuous
            )
        )
        .rotation3DEffect(
            .degrees(geometry.hingeAngle),
            axis: (x: 0, y: 1, z: 0),
            anchor: .leading,
            anchorZ: 0,
            perspective: BookStageGeometry.perspective
        )
        .shadow(
            color: .black.opacity(geometry.shadowOpacity),
            radius: geometry.shadowRadius,
            y: geometry.shadowY
        )
        .opacity(geometry.coverOpacity)
        .position(
            x: geometry.bookFrame.midX,
            y: geometry.bookFrame.midY
        )
        // 这一层不吃手势：它只是一张画出来的纸，吃掉点击就成了「点了没反应」。
        // 转场期间真正拦手势的是阅读页那边（`ReaderView.turnPage` / `applyPull` / `handleTap`
        // 都看 `ReaderLauncher.isTransitioning`），在这儿留一层看不见的挡板反而是错的。
        .allowsHitTesting(false)
    }

    private var face: some View {

        CoverFace(
            url: cover.url,
            title: cover.title,
            corner: geometry.corner
        )
        .overlay(alignment: .trailing) {
            pageEdge
        }
        .overlay(alignment: .leading) {
            spine
        }
        // 装订那一道暗：合着的时候只留一点点（那是封面绕书脊的弧），
        // 抬起来以后靠脊那侧压得更深——书是被自己抬起来的，光从读者那侧来。
        .overlay(alignment: .leading) {
            LinearGradient(
                colors: [
                    Color.black.opacity(0.10 + 0.26 * geometry.elevation),
                    .clear,
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(
                width: max(18, geometry.bookFrame.width * 0.14)
            )
        }
    }

    /// 纸背。合上以后朝读者那一面是封面，翻开越过 90° 看见的就是这一面——它只在那几度
    /// 里存在（再往外整个投影已经在屏幕外），但不能没有：少了它，转过 90° 那一瞬
    /// 看见的还是镜像的封面图。
    /// 底色一律走主题那张纸：夜间档要是这里给一层白，就是「深色模式闪白」那一类，
    /// 而它是进出场，比翻页更容易被看见。
    private var back: some View {

        theme.background
            .overlay(alignment: .leading) {
                LinearGradient(
                    colors: [theme.crease, .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: max(16, geometry.bookFrame.width * 0.10))
            }
    }

    /// 书口那一摞纸的边。底色用主题那张纸而不是写死米白：夜间档那本书的纸边
    /// 也得是深纸，深浅两档都不会闪一条白出来。
    private var pageEdge: some View {

        theme.background
            .overlay {
                LinearGradient(
                    colors: [
                        Color.black.opacity(0.30),
                        Color.white.opacity(0.16),
                        Color.black.opacity(0.34),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }
            .frame(width: geometry.pageEdge)
    }

    /// 书脊那一条。封面绕过脊会有一道高光加一道暗，都在这一条里。
    private var spine: some View {

        LinearGradient(
            colors: [
                Color.black.opacity(0.24),
                Color.white.opacity(0.12),
                Color.black.opacity(0.12),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(width: geometry.spineBand)
    }
}
