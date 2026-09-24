//
//  ReaderPageView.swift
//  Reader
//
//  一页正文。渲染口径必须与 `PageLayout` 的测量口径逐字对应——字号、行距、
//  段首缩进、句间距、页边距全部走 `ReaderTypography`，任何一处只在一边改，
//  页高就会算错，表现是「字溢到下一页」或整页空一半。
//

import SwiftUI

/// 不带滚动的一页内容。单独拆出来是为了能被脱离 TabView 量出固有高度
/// （测量/校验用），ReaderPageView 只是给它套一层滚动容器。
struct ReaderPageBody: View {

    /// 整章句子
    let sentences: [Sentence]

    /// 本页承载的句子下标
    let positions: [Int]

    let bodySize: CGFloat

    /// 正在朗读的句子下标；nil 表示本页没有正在播的句子
    let activePosition: Int?

    let tap: (Int) -> Void

    var body: some View {

        VStack(
            alignment: .leading,
            spacing: ReaderTypography.sentenceGap(size: bodySize)
        ) {

            if positions.isEmpty, sentences.isEmpty {

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
                positions,
                id: \.self
            ) { position in

                if position < sentences.count {

                    sentenceBlock(
                        sentences[position],
                        position: position
                    )
                }
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
    }

    /// 当前句只换颜色，不换字号/字重：换了这页的行数就和测量结果对不上，
    /// 播到某一句字却掉到下一页去。
    @ViewBuilder
    private func sentenceBlock(
        _ sentence: Sentence,
        position: Int
    ) -> some View {

        let isActive = position == activePosition

        VStack(
            alignment: .leading,
            spacing: 2
        ) {

            if let name = sentence.characterName,
               sentence.speaker == .character {

                Text(name)
                    .font(
                        .system(
                            size: ReaderTypography.labelSize(size: bodySize),
                            weight: .medium
                        )
                    )
                    .foregroundStyle(
                        isActive
                            ? Color.accentColor
                            : Color.secondary
                    )
            }

            Text(sentence.text)
                .font(.system(size: bodySize))
                .lineSpacing(
                    ReaderTypography.lineSpacing(size: bodySize)
                )
                .multilineTextAlignment(.leading)
                .fixedSize(
                    horizontal: false,
                    vertical: true
                )
                .padding(
                    .leading,
                    ReaderTypography.paragraphIndent(size: bodySize)
                )
                .foregroundStyle(
                    isActive
                        ? .primary
                        : Color.primary.opacity(0.72)
                )
        }
        .frame(
            maxWidth: .infinity,
            alignment: .leading
        )
        .contentShape(Rectangle())
        .onTapGesture {

            tap(position)
        }
    }
}

struct ReaderPageView: View {

    let sentences: [Sentence]

    let positions: [Int]

    let bodySize: CGFloat

    let activePosition: Int?

    let tap: (Int) -> Void

    var body: some View {

        // 整页装不下一句时（超长引用、极小屏）靠滚动兜底，而不是把句子撕开
        ScrollView {

            ReaderPageBody(
                sentences: sentences,
                positions: positions,
                bodySize: bodySize,
                activePosition: activePosition,
                tap: tap
            )
        }
    }
}
