//
//  Book.swift
//  Reader
//
//  Created by 粟海洋 on 2026/8/26.
//

import SwiftUI
import ImageIO

/// 封面图。EPUB 里的封面经常是打印稿尺寸，直接解码一张就是二十几兆内存，
/// 所以走 ImageIO 按显示尺寸的 3 倍缩略图解，结果按路径缓存。
struct CoverImage: View {

    let url: URL?

    let title: String

    var body: some View {

        // scaledToFill 的布局尺寸是「按比例铺满后的外接框」，比格子宽（0.75 的封面
        // 在 2:3 格子里会报成 401pt 而不是 357pt），撑出去的部分会吃掉列间距，
        // 于是真封面卡挨着、占位卡之间留白。frame(maxWidth: .infinity) 封顶不住
        // 不肯缩的孩子，只有 GeometryReader + 定死宽高才行。
        GeometryReader { proxy in

            ZStack {

                // 没封面时用书名铺一张色卡占位，风格与详情页一致
                LinearGradient(
                    colors: [Color.indigo, Color.purple],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                Text(title)
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .padding(16)

                if let image = Self.load(url) {

                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .frame(
                width: proxy.size.width,
                height: proxy.size.height
            )
            .clipped()
        }
        .aspectRatio(2.0 / 3.0, contentMode: .fit)
    }

    private static let cache = NSCache<NSString, UIImage>()

    private static let maxPixelSize: CGFloat = 720

    private static func load(_ url: URL?) -> UIImage? {

        guard let url else {
            return nil
        }

        let key = url.path as NSString

        if let hit = cache.object(forKey: key) {
            return hit
        }

        guard let source = CGImageSourceCreateWithURL(
            url as CFURL,
            nil
        ) else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]

        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else {
            return nil
        }

        let image = UIImage(cgImage: thumbnail)

        cache.setObject(image, forKey: key)

        return image
    }
}

/// 书库里的一张书卡：只有封面和进度（对齐图书 App）。
struct BookCoverTile: View {

    let book: Book

    var body: some View {

        VStack(
            alignment: .leading,
            spacing: 9
        ) {

            CoverImage(
                url: book.coverURL,
                title: book.title
            )
            .clipShape(
                RoundedRectangle(
                    cornerRadius: 12
                )
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: 12
                )
                .strokeBorder(
                    .quaternary,
                    lineWidth: 0.5
                )
            }
            .shadow(
                color: .black.opacity(0.18),
                radius: 6,
                y: 4
            )

            HStack(spacing: 7) {

                Text(
                    "\(Int(progress * 100))%"
                )
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
        }
    }

    /// 进度按章算：句子级位置要读 chapter.json 才知道分母，
    /// 为了一条进度条去解析整本书的标注不值。
    private var progress: Double {

        guard !book.chapters.isEmpty else {
            return 0
        }

        return min(
            1,
            Double(book.lastReadChapter + 1)
            / Double(book.chapters.count)
        )
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
            CoverImage(
                url: book.coverURL,
                title: book.title
            )
            .frame(width: 150, height: 210)
            .clipShape(
                RoundedRectangle(cornerRadius: 16)
            )
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

                        // 用章自己的标题，不写「第 N 章」：N 是数组下标，和书里印的
                        // 章号是两套（前言占一格、正文从「第5章」起），并排看着像出错。
                        Text(
                            book.chapters.indices.contains(book.lastReadChapter)
                                ? book.chapters[book.lastReadChapter].title
                                : book.chapters[0].title
                        )
                        .font(.caption)
                        .opacity(0.8)
                        .lineLimit(1)
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
