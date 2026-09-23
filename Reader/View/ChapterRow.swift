//
//  ChapterRow.swift
//  Reader
//
//  Created by 粟海洋 on 2026/8/26.
//

import SwiftUI

struct ChapterRow: View {

    let chapter: Chapter
    let isCurrent: Bool
    let action: () -> Void

    var body: some View {

        Button(action: action) {

            HStack(spacing: 14) {

                // Chapter number
                Text("\(chapter.index + 1)")
                    .font(.system(
                        size: 14,
                        weight: .semibold
                    ))
                    .foregroundStyle(
                        isCurrent
                        ? .white
                        : .secondary
                    )
                    .frame(
                        width: 34,
                        height: 34
                    )
                    .background(
                        isCurrent
                        ? Color.indigo
                        : Color.secondary
                            .opacity(0.10)
                    )
                    .clipShape(Circle())

                // Title
                VStack(
                    alignment: .leading,
                    spacing: 5
                ) {

                    Text(chapter.title)
                        .font(.system(
                            size: 16,
                            weight: isCurrent
                                ? .semibold
                                : .regular
                        ))
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    chapterStatus
                }

                Spacer()

                Image(
                    systemName: "chevron.right"
                )
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                isCurrent
                ? Color.indigo.opacity(0.08)
                : Color(.secondarySystemGroupedBackground)
            )
            .clipShape(
                RoundedRectangle(
                    cornerRadius: 14
                )
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var chapterStatus: some View {

        switch chapter.audioStatus {

        case .pending:

            Label(
                "尚未生成语音",
                systemImage: "waveform"
            )
            .font(.caption)
            .foregroundStyle(.secondary)

        case .analyzing:

            Label(
                "AI 分析中",
                systemImage: "sparkles"
            )
            .font(.caption)
            .foregroundStyle(.orange)

        case .generating:

            Label(
                "语音生成中",
                systemImage: "waveform"
            )
            .font(.caption)
            .foregroundStyle(.orange)

        case .completed:

            Label(
                "已生成语音",
                systemImage: "checkmark.circle.fill"
            )
            .font(.caption)
            .foregroundStyle(.green)

        case .failed:

            Label(
                "生成失败",
                systemImage: "exclamationmark.circle.fill"
            )
            .font(.caption)
            .foregroundStyle(.red)
        }
    }
}
