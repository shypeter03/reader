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

                // 没封面时用书名铺一张色卡占位
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

/// 阅读页唤出的「目录」。
///
/// 它取代了原来单独一层的书籍详情页：图书 App 里目录是从正文上唤出来的，
/// 一本书不该有两套「先看介绍、再翻章节列表、再进正文」的路径。
/// 封面、作者、进度这些身份信息都留在这里，只是不再占一层页面。
struct ChapterOutlineView: View {

    let book: Book

    /// 正在读的那一章：高亮 + 打开时滚到它。
    let currentChapterID: UUID

    let onSelect: (ChapterDescriptor) -> Void

    @Environment(\.dismiss)
    private var dismiss

    var body: some View {

        NavigationStack {

            ScrollViewReader { proxy in

                List {

                    Section {
                        header
                            .listRowInsets(
                                EdgeInsets(
                                    top: 14,
                                    leading: 16,
                                    bottom: 14,
                                    trailing: 16
                                )
                            )
                            .listRowBackground(
                                Color(.secondarySystemBackground)
                            )
                    }

                    Section(
                        "章节 · \(book.chapters.count)"
                    ) {

                        ForEach(
                            book.chapters
                        ) { descriptor in

                            Button {

                                onSelect(descriptor)
                                dismiss()

                            } label: {

                                HStack {

                                    Text(descriptor.title)
                                        .foregroundStyle(
                                            descriptor.id == currentChapterID
                                                ? Color.accentColor
                                                : .primary
                                        )
                                        .lineLimit(1)

                                    Spacer()

                                    if descriptor.id == currentChapterID {
                                        Image(systemName: "checkmark")
                                            .font(.caption.bold())
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                            }
                            .id(descriptor.id)
                        }
                    }
                }
                .onAppear {
                    // 目录打开时停在正在读的那一章附近，而不是从第一页翻起
                    proxy.scrollTo(currentChapterID, anchor: .center)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var header: some View {

        HStack(alignment: .top, spacing: 14) {

            CoverImage(
                url: book.coverURL,
                title: book.title
            )
            .frame(width: 62, height: 87)
            .clipShape(
                RoundedRectangle(cornerRadius: 8)
            )

            VStack(alignment: .leading, spacing: 5) {

                Text(book.title)
                    .font(.headline)
                    .lineLimit(2)

                if let author = book.author, !author.isEmpty {
                    Text(author)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text(progressText)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
    }

    /// 进度按章算：句子级位置要读 chapter.json 才知道分母。
    ///
    /// 用「当前高亮的那一章」而不是 `book.lastReadChapter`：阅读页切章后进度是异步
    /// 落盘的，书单里那份 `book` 又是打开弹层时的快照，跟着它写就会和上面高亮的章对不上。
    private var progressText: String {

        guard !book.chapters.isEmpty else {
            return "还没开始"
        }

        let index = book.chapters.firstIndex {
            $0.id == currentChapterID
        } ?? book.lastReadChapter

        let current = min(index + 1, book.chapters.count)
        let total = book.chapters.count
        let percent = Int((Double(current) / Double(total) * 100).rounded())

        return "读到第 \(current)/\(total) 章 · \(percent)%"
    }
}
