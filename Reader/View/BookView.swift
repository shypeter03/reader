//
//  Book.swift
//  Reader
//
//  Created by 粟海洋 on 2026/8/26.
//

import SwiftUI

struct BookCard: View {

    let book: Book

    var body: some View {

        HStack(spacing: 16) {

            RoundedRectangle(cornerRadius: 10)
                .fill(.quaternary)
                .frame(
                    width: 80,
                    height: 110
                )
                .overlay {
                    Image(systemName: "book.closed")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                }

            VStack(
                alignment: .leading,
                spacing: 8
            ) {

                Text(book.title)
                    .font(.headline)

                if let author = book.author {
                    Text(author)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Text(
                    "第 \(book.lastReadChapter + 1) 章"
                )
                .font(.subheadline)

                ProgressView(
                    value: progress
                )
            }

            Spacer()
        }
        .padding()
        .background(.thinMaterial)
        .clipShape(
            RoundedRectangle(cornerRadius: 16)
        )
    }

    private var progress: Double {

        guard !book.chapters.isEmpty else {
            return 0
        }

        return Double(book.lastReadChapter)
            / Double(book.chapters.count)
    }
}

struct BookDetailView: View {

    let book: Book

    @State private var selectedChapter: ChapterDescriptor?
    @State private var showReader = false
    @State private var isAnalyzing = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {

                // MARK: - Book Header

                bookHeader
                    .padding(.horizontal, 20)
                    .padding(.top, 20)

                // MARK: - Continue Button

                continueButton
                    .padding(.horizontal, 20)
                    .padding(.top, 24)

                // MARK: - Chapter List

                chapterSection
                    .padding(.top, 32)
            }
            .padding(.bottom, 40)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedChapter) { descriptor in
            ReaderView(
                book: book,
                chapterDescriptor: descriptor
            )
        }
    }
}

// MARK: - Book Header

private extension BookDetailView {

    var bookHeader: some View {
        VStack(spacing: 18) {

            // Cover
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.indigo,
                                Color.purple
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                VStack(spacing: 10) {
                    Image(systemName: "book.closed.fill")
                        .font(.system(size: 42))
                        .foregroundStyle(.white.opacity(0.9))

                    Text(book.title)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                }
                .padding(20)
            }
            .frame(width: 150, height: 210)
            .shadow(
                color: .black.opacity(0.15),
                radius: 15,
                y: 8
            )

            // Title
            Text(book.title)
                .font(.system(size: 26, weight: .bold))
                .multilineTextAlignment(.center)

            // Author
            if let author = book.author,
               !author.isEmpty {

                Text(author)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // Info
            HStack(spacing: 20) {

                infoItem(
                    value: "\(book.chapters.count)",
                    title: "章节"
                )

                Divider()
                    .frame(height: 28)

                infoItem(
                    value: currentChapterText,
                    title: "当前"
                )

                Divider()
                    .frame(height: 28)

                infoItem(
                    value: progressText,
                    title: "进度"
                )
            }
            .padding(.top, 4)
        }
    }

    func infoItem(
        value: String,
        title: String
    ) -> some View {

        VStack(spacing: 4) {

            Text(value)
                .font(.system(
                    size: 16,
                    weight: .semibold
                ))

            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 60)
    }

    var currentChapterText: String {
        guard !book.chapters.isEmpty else {
            return "-"
        }

        return String(min(
            book.lastReadChapter + 1,
            book.chapters.count
        ))
    }

    var progressText: String {

        guard !book.chapters.isEmpty else {
            return "0%"
        }

        let progress =
            Double(book.lastReadChapter + 1)
            / Double(book.chapters.count)

        return "\(Int(progress * 100))%"
    }
}

// MARK: - Continue

private extension BookDetailView {

    var continueButton: some View {

        Button {
            openContinueReading()
        } label: {

            HStack(spacing: 12) {

                Image(systemName: "play.fill")
                    .font(.system(size: 14, weight: .bold))

                VStack(
                    alignment: .leading,
                    spacing: 3
                ) {

                    Text(
                        book.lastReadChapter < book.chapters.count
                        ? "继续阅读"
                        : "开始阅读"
                    )
                    .font(.system(
                        size: 16,
                        weight: .semibold
                    ))

                    if !book.chapters.isEmpty {

                        Text(
                            "第 \(book.lastReadChapter + 1) 章"
                        )
                        .font(.caption)
                        .opacity(0.8)
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .opacity(0.7)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .frame(height: 62)
            .background(
                LinearGradient(
                    colors: [
                        Color.indigo,
                        Color.purple
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .clipShape(
                RoundedRectangle(cornerRadius: 16)
            )
        }
        .buttonStyle(.plain)
    }

    func openContinueReading() {

        guard !book.chapters.isEmpty else {
            return
        }

        let index = min(
            book.lastReadChapter,
            book.chapters.count - 1
        )

        selectedChapter =
            book.chapters[index]
    }
}

// MARK: - Chapters

private extension BookDetailView {

    var chapterSection: some View {

        VStack(spacing: 0) {

                ForEach(book.chapters) { descriptor in

                    Button {

                        selectedChapter = descriptor

                    } label: {

                        HStack {

                            Text(descriptor.title)

                            Spacer()

                            Image(
                                systemName: "chevron.right"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                    }
                    .buttonStyle(.plain)
                }
            }
    }
}
