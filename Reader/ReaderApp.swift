//
//  ReaderApp.swift
//  Reader
//
//  Created by 粟海洋 on 2026/8/26.
//

import SwiftUI

@main
struct ReaderApp: App {

    // 没有「播放」这个 tab 了：朗读控制是正文下方那条坞。播放页和它是同一件事的两个
    // 副本，各写一份进度与订阅，真出过「两份进度互相覆盖」——去掉之后只剩一条路。
    //
    // 阅读页也放在这一层，不用 fullScreenCover：封面转场的动画系统写死是硬切，
    // 只有根视图自己叠的这层才能既盖住 tab 栏、又让进出两个方向都吃到同一个动画。
    @StateObject
    private var launcher = ReaderLauncher.shared

    // 后台门禁不在这里挂：`ReaderPipeline` 自己盯 `UIApplication` 的生命周期通知。
    // 走 SwiftUI 的话，冷启动直接被系统丢进后台（后台音频、推送拉起）那一类
    // `onChange(of: scenePhase)` 根本不会触发，而那一刻的 GPU 提交照样崩。

    var body: some Scene {

        WindowGroup {

            // 整屏尺寸是给退场动画算落点用的：封面卡的位置是全屏幕坐标，
            // 两者必须在同一个坐标系里，所以这层 GeometryReader 铺满屏幕、不吃安全区。
            GeometryReader { canvas in

                // `ignoresSafeArea()` 挂的是里面那个 ZStack（要让书库、暗幕和阅读页都铺到边），
                // 代价是外层这个 GeometryReader 报回来的是**安全区**的尺寸：探针实测这一种挂法
                // 给 393×759，而把 `ignoresSafeArea()` 挂到 GeometryReader 上才给 393×852
                // （`.probe/run-canvas-size.sh`，三种挂法 A=759 / B=852 / C=759）。
                // 转场的几何必须用真正那块画布：`bookFrame` 在摊开那一步要正好等于整屏，
                // 封面才盖得住底下的 93pt——少盖一截就是「书举到一半，底下一条书架还在」，
                // 以及举起走完那一下正文从屏幕底下闪出来。
                // 这里只做加法（安全区四条边补回去），不换挂法：换挂法会改到所有下层视图
                // 收到的安全区，那是阅读页排版的事，不该为一趟动画去动它。
                let insets = canvas.safeAreaInsets

                let canvasSize = CGSize(
                    width: canvas.size.width + insets.leading + insets.trailing,
                    height: canvas.size.height + insets.top + insets.bottom
                )

                // 那一本书挪到哪一步：0 压在封面卡上，1 完全摊开成整屏。
                // 底下那层书库、暗幕和 BookStage 里的书都按同一个值联动，下拉手势改的也是它，
                // 所以三层永远同步，不会出现正文已经缩回去、书库还没复原。
                let present = launcher.opened == nil
                    ? 0
                    : launcher.presentation

                ZStack {

                    TabView {

                        LibraryView()
                            .tabItem {
                                Label(
                                    "书库",
                                    systemImage:
                                        "books.vertical"
                                )
                            }

                        SettingsView()
                            .tabItem {
                                Label(
                                    "设置",
                                    systemImage:
                                        "gearshape"
                                )
                            }
                    }
                    // 书摊开的时候底下那层往后退一点、收成一张卡，
                    // 看着像是「这本书被拿起来了」，而不是被糊住。
                    .scaleEffect(
                        1 - (1 - Self.dockedScale) * CGFloat(present)
                    )
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: Self.dockedCorner * CGFloat(present),
                            style: .continuous
                        )
                    )
                    .allowsHitTesting(launcher.opened == nil)

                    Color.black
                        .opacity(Self.scrimOpacity * CGFloat(present))
                        .ignoresSafeArea()
                        .allowsHitTesting(false)

                    if let target = launcher.opened {

                        // 转场由 BookStage 这一层摆那一本正在挪的书，阅读页原样待在整屏上：
                        // 它不再跟着 `presentation` 缩放、位移、淡出——缩的是书，不是页面。
                        // 落点每次现读（`landingFrame(for:)` 的注释说了为什么不能缓存），
                        // 拿不到就走回退落点，而不是让书飞向别的位置。
                        BookStage(
                            presentation: present,
                            cover: BookCover(
                                url: target.book.coverURL,
                                title: target.book.title
                            ),
                            card: launcher.landingFrame(
                                for: target.book.id
                            ),
                            canvas: canvasSize
                        ) {
                            ReaderView(
                                book: target.book,
                                chapterDescriptor:
                                    target.book.chapters[
                                        target.chapterIndex
                                    ],
                                onClose: {
                                    launcher.close()
                                }
                            )
                            // 换一本书必须换掉整个视图：ReaderView 的章是 init 里灌进
                            // @State 的，复用实例会留着上一本书的那一章。
                            .id(target.id)
                        }
                    }

                    // 开屏压在全部内容之上：首帧那一下书库还是空的，
                    // 「还没有书」那个空状态不接住就会先闪给用户看。
                    LaunchLayer()
                }
            }
            .ignoresSafeArea()
        }
    }

    /// 退到后面的书库缩多少、圆角多大。1 屏宽下 0.94 大概是封面卡往外让 24pt，
    /// 再多就开始露出窗口底色、像掉进一个洞里。
    private static let dockedScale: CGFloat = 0.94

    private static let dockedCorner: CGFloat = 44

    private static let scrimOpacity: Double = 0.32
}
