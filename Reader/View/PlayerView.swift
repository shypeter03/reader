//
//  PlayerView.swift
//  Reader
//
//  Created by 粟海洋 on 2026/8/26.
//

import SwiftUI

struct PlayerView: View {

    @ObservedObject
    var player: PlayerManager

    private let speedOptions: [Double] = [
        0.75, 1.0, 1.25, 1.5, 2.0
    ]

    var body: some View {

        VStack(spacing: 0) {

            if player.sentences.isEmpty {

                emptyState

            } else {

                sentenceList

                Divider()

                controls
            }
        }
        .navigationTitle(
            player.currentChapter?.title
                ?? "尚未播放"
        )
        .navigationBarTitleDisplayMode(
            .inline
        )
    }

    private var emptyState: some View {

        VStack(spacing: 16) {

            Spacer()

            Image(
                systemName: "headphones"
            )
            .font(.system(size: 60))
            .foregroundStyle(.tertiary)

            Text("尚未加载章节")
                .font(.title3)
                .foregroundStyle(.secondary)

            Text("请在书库中选择章节开始阅读")
                .font(.subheadline)
                .foregroundStyle(.tertiary)

            Spacer()
        }
    }

    private var sentenceList: some View {

        ScrollViewReader { proxy in

            ScrollView {

                LazyVStack(
                    alignment: .leading,
                    spacing: 14
                ) {

                    ForEach(
                        player.sentences
                    ) { sentence in

                        sentenceRow(
                            sentence,
                            isActive: sentence.index
                                == player.currentSentenceIndex
                        )
                        .id(sentence.index)
                        .onTapGesture {

                            player.playSentence(
                                at: sentence.index
                            )
                        }
                    }
                }
                .padding(
                    .horizontal, 20
                )
                .padding(
                    .top, 16
                )
                .padding(
                    .bottom, 20
                )
            }
            .onChange(
                of: player.currentSentenceIndex
            ) { _, newIndex in

                withAnimation(
                    .easeInOut(
                        duration: 0.3
                    )
                ) {

                    proxy.scrollTo(
                        newIndex,
                        anchor: .center
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func sentenceRow(
        _ sentence: Sentence,
        isActive: Bool
    ) -> some View {

        VStack(
            alignment: .leading,
            spacing: 4
        ) {

            if sentence.speaker == .character,
               let name = sentence.characterName {

                Text(name)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(
                        isActive
                            ? Color.accentColor
                            : .secondary
                    )
            }

            Text(sentence.text)
                .font(.body)
                .foregroundStyle(
                    isActive
                        ? .primary
                        : .secondary
                )
                .fontWeight(
                    isActive ? .semibold : .regular
                )
        }
        .padding(
            .vertical, 6
        )
        .padding(
            .horizontal, 10
        )
        .frame(
            maxWidth: .infinity,
            alignment: .leading
        )
        .background(
            isActive
                ? Color.accentColor.opacity(0.1)
                : Color.clear
        )
        .clipShape(
            RoundedRectangle(
                cornerRadius: 8
            )
        )
        .animation(
            .easeInOut(
                duration: 0.2
            ),
            value: isActive
        )
    }

    private var controls: some View {

        VStack(spacing: 16) {

            HStack(spacing: 50) {

                Button {

                    player.skipBackward()

                } label: {

                    Label(
                        "15",
                        systemImage:
                            "gobackward"
                    )
                }

                Button {

                    player.togglePlay()

                } label: {

                    Image(
                        systemName:
                            player.isPlaying
                            ? "pause.circle.fill"
                            : "play.circle.fill"
                    )
                    .font(.system(size: 50))
                }

                Button {

                    player.skipForward()

                } label: {

                    Label(
                        "15",
                        systemImage:
                            "goforward"
                    )
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)

            Menu {

                ForEach(
                    speedOptions,
                    id: \.self
                ) { rate in

                    Button {

                        player.playbackRate = rate

                    } label: {

                        HStack {

                            Text(
                                String(
                                    format: "%.2fx",
                                    rate
                                )
                            )

                            if player.playbackRate == rate {

                                Image(
                                    systemName: "checkmark"
                                )
                            }
                        }
                    }
                }

            } label: {

                HStack(spacing: 6) {

                    Image(
                        systemName:
                            "speedometer"
                    )

                    Text(
                        String(
                            format: "%.2fx",
                            player.playbackRate
                        )
                    )
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        }
        .padding(
            .top, 16
        )
        .padding(
            .bottom, 20
        )
        .background(
            .ultraThinMaterial
        )
    }
}
