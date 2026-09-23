//
//  PlayBar.swift
//  Reader
//
//  Created by 粟海洋 on 2026/8/26.
//

import SwiftUI

struct PlayerBar: View {

    let chapter: Chapter
    @Binding var activeSentence: Int

    @State private var isPlaying = false

    var body: some View {

        VStack(spacing: 12) {

            // 当前句信息
            if chapter.sentences.indices.contains(activeSentence) {

                let sentence = chapter.sentences[activeSentence]

                HStack {

                    VStack(
                        alignment: .leading,
                        spacing: 3
                    ) {

                        Text(
                            sentence.characterName ?? "旁白"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        Text(sentence.text)
                            .font(.subheadline)
                            .lineLimit(1)
                    }

                    Spacer()
                }
            }

            // 章节进度
            ProgressView(
                value: progress
            )

            // 播放控制
            HStack {

                Button {
                    previousSentence()
                } label: {
                    Image(
                        systemName: "backward.end.fill"
                    )
                }

                Spacer()

                Button {
                    isPlaying.toggle()
                } label: {

                    Image(
                        systemName:
                            isPlaying
                            ? "pause.fill"
                            : "play.fill"
                    )
                    .font(.title2)
                }

                Spacer()

                Button {
                    nextSentence()
                } label: {
                    Image(
                        systemName: "forward.end.fill"
                    )
                }
            }
            .font(.title3)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(.ultraThinMaterial)
    }

    // MARK: - Progress

    private var progress: Double {

        guard !chapter.sentences.isEmpty else {
            return 0
        }

        return Double(activeSentence + 1)
            / Double(chapter.sentences.count)
    }

    // MARK: - Previous

    private func previousSentence() {

        guard activeSentence > 0 else {
            return
        }

        activeSentence -= 1
    }

    // MARK: - Next

    private func nextSentence() {

        guard activeSentence < chapter.sentences.count - 1 else {
            return
        }

        activeSentence += 1
    }
}
