//
//  PlayBar.swift
//  Reader
//
//  阅读页唤出来的两条：上方 `ReaderTopBar`（关闭 · 目录 · Aa）、下方
//  `VoiceToolBar`（听），外加 Aa 面板 `TypographyPanel`。
//

import SwiftUI
import UIKit

/// 阅读页上下各要让出多高。
///
/// 不能用 SwiftUI 传下来的 safe area：阅读页是根视图自己叠上去的一层，那层的
/// GeometryReader 挂着 `ignoresSafeArea()`（封面转场要按整屏坐标算落点），
/// 传进来已经是 0 了——真机截图量过，44pt 的顶栏整条压在状态栏的字上
///（字在 8...38.7pt，状态栏 zone 到 59pt）。所以直接问窗口要这两个数。
@MainActor
enum ChromeInsets {

    static var top: CGFloat {
        keyWindow?.safeAreaInsets.top ?? 0
    }

    static var bottom: CGFloat {
        keyWindow?.safeAreaInsets.bottom ?? 0
    }

    private static var keyWindow: UIWindow? {
        UIApplication
            .shared
            .connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
    }
}

/// 压在灵动岛下面的那一行章名：每页都在，不跟着 chrome 收放。
///
/// 章名从返回键上挪到这里，是因为返回键只在唤出按钮的那几秒看得见，
/// 而读者真正在意的是「我现在读到哪一章了」——那得一直在纸上。
/// 它占的这一段不是浮在正文上，而是正文自己让出来的（见 `pageReader`），
/// 所以分页量的高度和渲染用的是同一块地方。
struct ChapterRunningHead: View {

    static let contentHeight: CGFloat = 30

    static var totalHeight: CGFloat {
        ChromeInsets.top + contentHeight
    }

    let title: String

    let color: Color

    var body: some View {

        VStack(spacing: 0) {

            Color.clear
                .frame(height: ChromeInsets.top)

            Text(
                title
            )
            .font(
                .system(
                    size: 13,
                    weight: .medium
                )
            )
            .lineLimit(
                1
            )
            .truncationMode(
                .tail
            )
            .foregroundStyle(color)
            .frame(
                maxWidth: .infinity,
                alignment: .center
            )
            .frame(height: Self.contentHeight)
        }
        .padding(.horizontal, 18)
        .allowsHitTesting(false)
    }
}

/// 阅读页唤出来的两条：上方「关闭 · 目录 · Aa」，下方「听」。
///
/// 正文中心完全留给「点哪句从哪句开始朗读」，所以这两条不常驻，
/// 由左右边缘点击或下滑唤出、几秒后自己收回去——像图书 App 那样。
/// 「听」只留播放/暂停、句序、倍速和生成状态：上一句/下一句和句进度条都撤了，
/// 点句本身就是跳句，一条压在 home 指示条上的横杠既点不准也没地方点。
/// 生成状态只是条尾一个字，不再单独占一行——那样阅读页会被三条横杠夹着，
/// 中间留给正文的高度不到半屏，翻页翻两句就到底。
struct ReaderTopBar: View {

    /// 内容行高。不含状态栏那一段——那一段由 `ChromeInsets.top` 让出来。
    static let contentHeight: CGFloat = 52

    static var totalHeight: CGFloat {
        ChromeInsets.top + contentHeight
    }

    let onClose: () -> Void

    let onOutline: () -> Void

    let onTypography: () -> Void

    var body: some View {

        VStack(spacing: 0) {

            // 状态栏那一条留给材质，不摆控件：控件一律排在它下面。
            Color.clear
                .frame(height: ChromeInsets.top)

            HStack(spacing: 18) {

                // 只有箭头，不带章名：章名交给正文上面那行常驻页眉，
                // 摆在返回键上等于每翻一页都要重看一遍同样的字。
                Button(
                    action: onClose
                ) {
                    Image(
                        systemName: "chevron.left"
                    )
                    .font(
                        .system(
                            size: 22,
                            weight: .semibold
                        )
                    )
                    .frame(
                        width: 44,
                        height: 44
                    )
                    .contentShape(
                        Rectangle()
                    )
                }
                .accessibilityLabel("返回书库")

                Spacer()

                Button(
                    action: onTypography
                ) {
                    Image(systemName: "textformat.size")
                        .font(.system(size: 20, weight: .medium))
                        .frame(width: 30, height: 30)
                }
                .accessibilityLabel("朗读与排版设置")

                Button(
                    action: onOutline
                ) {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 20, weight: .medium))
                        .frame(width: 30, height: 30)
                }
                .accessibilityLabel("目录")
            }
            .frame(height: Self.contentHeight)
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            hairline
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
    }

    /// 一条分隔线：材质在半透明底色上几乎看不出来，没有它顶栏和正文糊成一片。
    private var hairline: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(height: 0.5)
    }
}

/// Aa 面板：字号、行距、底色。
///
/// 它挂在正文之上而不是新开一页：调排版要当场看得见效果，
/// 换到另一页去调就等于让用户凭想象翻页。
struct TypographyPanel: View {

    @AppStorage("fontSize")
    private var fontScale: Double = 1.0

    @AppStorage("lineSpacingScale")
    private var lineScale: Double = 1.0

    /// 键必须与 `ReaderTheme.storageKey` 一致（@AppStorage 只接受字面量）。
    @AppStorage("readerTheme")
    private var themeRaw: String = ReaderTheme.paper.rawValue

    var body: some View {

        VStack(alignment: .leading, spacing: 16) {

            HStack(spacing: 12) {

                Text("字号")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .leading)

                Text("A")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Slider(value: $fontScale, in: 0.8...1.5, step: 0.05)

                Text("A")
                    .font(.system(size: 19))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {

                Text("行距")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .leading)

                Slider(value: $lineScale, in: 0.8...1.6, step: 0.1)
            }

            HStack(spacing: 12) {

                Text("底色")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .leading)

                ForEach(ReaderTheme.allCases) { theme in

                    Button {
                        themeRaw = theme.rawValue
                    } label: {
                        Circle()
                            .fill(swatchStyle(theme))
                            .overlay(
                                Circle().strokeBorder(
                                    theme.text.opacity(0.25),
                                    lineWidth: 0.5
                                )
                            )
                            .overlay(
                                Circle()
                                    .fill(Color.accentColor)
                                    .frame(width: 8, height: 8)
                                    .opacity(theme.rawValue == themeRaw ? 1 : 0)
                            )
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(theme.label)
                }

                Spacer()
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
    }

    /// 「跟随系统」那颗不能直接涂 `theme.background`：浅色模式下它和宣纸一模一样，
    /// 用户挑不出来。给它一道左上白、右下黑的对角色，一眼就是「两档都跟着」。
    private func swatchStyle(_ theme: ReaderTheme) -> AnyShapeStyle {
        guard theme == .system else {
            return AnyShapeStyle(theme.background)
        }
        return AnyShapeStyle(
            LinearGradient(
                stops: [
                    .init(
                        color: Color(red: 0.99, green: 0.99, blue: 0.98),
                        location: 0.5
                    ),
                    .init(
                        color: Color(red: 0.09, green: 0.09, blue: 0.11),
                        location: 0.5
                    )
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }
}

// MARK: - 听

/// 「听」的快路操作收在正文下方这一条里：播放/暂停、读到第几句、倍速、生成状态。
///
/// 上一句/下一句和句进度条都撤了：跳句有「点正文那一句」这条更直接的路，
/// 而一条要点准的小横杠压在 home 指示条上，划页的手和点条的手还要抢同一块地方。
struct VoiceToolBar: View {

    @ObservedObject
    var player: PlayerManager

    /// 语音播报总开关。和设置页那个 Toggle 写同一个键（`PlayerManager.speechEnabledKey`），
    /// 所以是同一个值：任何一处拨了，另一处跟着变。
    @AppStorage(
        PlayerManager.speechEnabledKey
    )
    private var speechEnabled = true

    /// 本章句数。不用 `player.sentences.count`：换章那一瞬两边会短暂不一致，
    /// 分母跳成 0 会让读数闪一下。
    let sentenceCount: Int

    let analysisStatus: AnalysisStatus

    let ttsStatus: TTSStatus

    /// 生成失败时条尾出现「重试」。
    let onRetry: () -> Void

    private let speedOptions: [Double] = [0.75, 1.0, 1.25, 1.5, 2.0]

    /// 内容行高，不含让给 home 指示条的那一段。
    static let contentHeight: CGFloat = 56

    static var totalHeight: CGFloat {
        contentHeight + ChromeInsets.bottom
    }

    var body: some View {

        VStack(spacing: 0) {

            HStack(spacing: 14) {

                // 总开关排在播放键前面：它关掉的是「点一句读一句」这件事本身，
                // 那时候播放键再按就不该出声了。
                Button {
                    PlayerManager.setSpeechEnabled(!speechEnabled)
                } label: {
                    Image(
                        systemName: speechEnabled
                            ? "speaker.wave.2.fill"
                            : "speaker.slash.fill"
                    )
                    .font(.system(size: 19))
                    .foregroundStyle(speechEnabled ? .primary : .secondary)
                    .frame(
                        width: 34,
                        height: 34
                    )
                    .contentShape(
                        Rectangle()
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    speechEnabled ? "关闭语音播报" : "开启语音播报"
                )

                Button(action: { player.togglePlay() }) {

                    Image(
                        systemName: player.isPlaying
                            ? "pause.circle.fill"
                            : "play.circle.fill"
                    )
                    .font(.system(size: 32))
                    .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                .opacity(speechEnabled ? 1 : 0.35)
                .disabled(!speechEnabled)
                .accessibilityLabel(player.isPlaying ? "暂停" : "播放")

                Text("第 \(sentenceLabel) / \(sentenceCount) 句")
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)

                Spacer(minLength: 8)

                Menu {

                    ForEach(speedOptions, id: \.self) { rate in

                        Button {
                            player.playbackRate = rate
                        } label: {
                            HStack {
                                Text(String(format: "%.2fx", rate))
                                if player.playbackRate == rate {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }

                } label: {

                    Text(String(format: "%.2fx", player.playbackRate))
                        .font(.footnote.weight(.medium))
                        .monospacedDigit()
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color(.secondarySystemBackground)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("倍速")

                statusChip
            }
            .frame(height: Self.contentHeight)

            // home 指示条那一段同样只铺材质，控件不进去。
            Color.clear
                .frame(height: ChromeInsets.bottom)
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
    }

    // MARK: - Status

    /// 生成状态压成条尾一个字：它不该单独占一行，但失败时必须能就地重试。
    @ViewBuilder
    private var statusChip: some View {

        if !speechEnabled {

            // 关掉语音后两条队列是真的挂着（模型也已卸载），不是「正在合成」。
            // 章上的状态还是关之前那一份，照原样打出来就是一句谎话。
            Label("已停止生成", systemImage: "pause.circle")
                .font(.caption)
                .foregroundStyle(.secondary)

        } else if analysisStatus == .failed || ttsStatus == .failed {

            Button(action: onRetry) {
                Label("重试", systemImage: "exclamationmark.triangle")
            }
            .font(.caption)
            .buttonStyle(.plain)
            .foregroundStyle(.orange)

        } else if ttsStatus != .completed {

            Label("合成中", systemImage: "waveform")
                .font(.caption)
                .foregroundStyle(.secondary)

        } else if analysisStatus != .completed {

            Label("校准中", systemImage: "sparkles")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var sentenceLabel: Int {
        min(max(player.currentSentenceIndex + 1, 1), max(sentenceCount, 1))
    }
}
