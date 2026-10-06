//
//  Book.swift
//  Reader
//
//  Created by 粟海洋 on 2026/8/26.
//

import SwiftUI
import ImageIO

/// 封面那一面：图按比例铺满给定的框、裁掉多出来的，圆角和那道 0.5pt 边都在这儿收。
///
/// 书库的卡、目录头上那张小图、以及进出场那本**正在挪的**书共用这一个视图，理由只有一条：
/// 书落回架子那一刻，转场副本和真封面卡画的是同一张图才叫「交接」——裁法、圆角、那道边
/// 任一样对不上，落点那一瞬就是重影（表现是「缩回去以后卡边上多出一圈」）。
///
/// 从不拉伸：只有 fill + 裁。框不合比例时变的是**露出来那一块**，不是把字压扁。
struct CoverFace: View {

    let url: URL?

    let title: String

    var corner: CGFloat = 12

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
        .clipShape(
            RoundedRectangle(
                cornerRadius: corner,
                style: .continuous
            )
        )
        .overlay {
            RoundedRectangle(
                cornerRadius: corner,
                style: .continuous
            )
            .strokeBorder(
                .quaternary,
                lineWidth: 0.5
            )
        }
    }

    /// EPUB 里的封面经常是打印稿尺寸，直接解码一张就是二十几兆内存，
    /// 所以走 ImageIO 按 720px 缩略图解，结果按路径缓存。
    /// 转场那本书要的是「立刻有图、不许闪」，靠的就是这份缓存：卡上已经解过一遍的图，
    /// 副本这一份是命中，不再解第二次。
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

/// 2:3 那一档：书库的封面卡和目录头上的小图。
///
/// 转场那本书不吃这层——它那一面要从 2:3 的卡长到整屏，比例本来就一路在变
/// （见 `BookStageGeometry`），钉死比例就飞不出去。
struct CoverImage: View {

    let url: URL?

    let title: String

    var corner: CGFloat = 12

    var body: some View {

        CoverFace(
            url: url,
            title: title,
            corner: corner
        )
        .aspectRatio(2.0 / 3.0, contentMode: .fit)
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
                title: book.title,
                corner: 8
            )
            .frame(width: 62, height: 87)

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
