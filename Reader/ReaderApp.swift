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

                // 阅读页摊开到哪一步：0 落在封面卡上，1 铺满整屏。
                // 底下那层书库和这层暗幕都按同一个值联动，下拉手势改的也是它，
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

                        ReaderView(
                            book: target.book,
                            chapterDescriptor:
                                target.book.chapters[target.chapterIndex],
                            onClose: {
                                launcher.close()
                            }
                        )
                        // 换一本书必须换掉整个视图：ReaderView 的章是 init 里灌进
                        // @State 的，复用实例会留着上一本书的那一章。
                        .id(target.id)
                        // 不用 .transition：那个只在插入/移除的两端之间插值，
                        // 中途被手指按住就得整个重放。这里直接按 presentation 摆，
                        // 下拉多少落在多少上，松手再决定走完还是弹回。
                        .modifier(
                            CoverMatch(
                                progress: present,
                                source: launcher.sourceFrame,
                                canvas: canvas.size
                            )
                        )
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

/// progress 1 = 铺满整屏，0 = 正好落在封面卡那块地方。
///
/// 只按宽度算缩放：卡是 2:3、整页是全屏，硬要把高也对上就得把整页压扁，
/// 字会先挤成一团再弹回来。宽度对上、位置对上，看着就是那张卡被拿起来了。
private struct CoverMatch: ViewModifier, Animatable {

    var progress: Double

    /// nil = 不知道那张卡在哪（比如从别处打开阅读页），退回等比缩放。
    let source: CGRect?

    let canvas: CGSize

    var animatableData: Double {
        get {
            progress
        }
        set {
            progress = newValue
        }
    }

    /// 离全屏还有多远：1 在卡上，0 已经铺满。
    private var rest: Double {
        1 - progress
    }

    private var targetWidth: CGFloat {
        guard let source, source.width > 1, canvas.width > 1 else {
            return canvas.width * 0.86
        }
        return source.width
    }

    private var scale: CGFloat {
        CGFloat(1 - rest * (1 - targetWidth / max(canvas.width, 1)))
    }

    private var center: CGPoint {
        guard let source, source.width > 1 else {
            return CGPoint(x: canvas.width / 2, y: canvas.height * 0.62)
        }
        return CGPoint(x: source.midX, y: source.midY)
    }

    /// 收到底之前把不透明度也拉到 0。
    ///
    /// 原来是 `0.35 + 0.65 * progress`，于是整页落到封面卡上时还留着 35% 的实影，
    /// 而拆视图就发生在这一瞬 —— 表现是缩回去以后「啪」地闪一下没了。
    /// 只在最后 15% 行程上加一道淡出，中间段和原来完全一致。
    private var opacity: Double {
        (0.35 + 0.65 * progress) * min(1, progress / 0.15)
    }

    func body(
        content: Content
    ) -> some View {

        let offset = CGSize(
            width: (center.x - canvas.width / 2) * CGFloat(rest),
            height: (center.y - canvas.height / 2) * CGFloat(rest)
        )

        content
            .clipShape(
                RoundedRectangle(
                    cornerRadius: 26 * CGFloat(rest),
                    style: .continuous
                )
            )
            .scaleEffect(scale)
            .offset(offset)
            .opacity(opacity)
    }
}
