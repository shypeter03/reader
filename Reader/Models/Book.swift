//
//  Book.swift
//  Reader
//
//  Created by 粟海洋 on 2026/8/26.
//

import Foundation

struct Book: Identifiable, Codable {

    let id: UUID

    let title: String

    let author: String?

    let coverURL: URL?

    /// EPUB 解压后的根目录
    let epubRootURL: URL

    /// 章节索引，不包含正文
    let chapters: [ChapterDescriptor]

    /// 阅读位置
    var lastReadChapter: Int

    var lastReadSentence: Int

    /// 一张图（key 见 `ChapterImage.imageKey`）在这本书里出现过几**章**，一章内重复只算一次。
    ///
    /// 为什么要记在书上而不是解析章节时算：装饰图（书壳 logo、每章都印一遍的作者像）的
    /// 判据是**跨章的重复率**，而章节解析是一章一趟、彼此看不见的。放在书单上，
    /// 排版那一侧才问得到「这张图是不是满本书都在」。
    ///
    /// nil = 这份书单落库时还没有这项统计（老书）。读路径会在后台补算（`ReaderPipeline.registerBook`），
    /// 补出来之前一律按「没有证据是装饰」处理——不筛就是把图都画上，宁可多画一条 logo，
    /// 也不要在补算完成前把真图（亲密关系那种，190 张各不相同）吃掉。
    var imageTally: [String: Int]?

    init(
        id: UUID = UUID(),
        title: String,
        author: String?,
        coverURL: URL?,
        epubRootURL: URL,
        chapters: [ChapterDescriptor],
        lastReadChapter: Int = 0,
        lastReadSentence: Int = 0,
        imageTally: [String: Int]? = nil
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.coverURL = coverURL
        self.epubRootURL = epubRootURL
        self.chapters = chapters
        self.lastReadChapter = lastReadChapter
        self.lastReadSentence = lastReadSentence
        self.imageTally = imageTally
    }
}

extension Book {

    /// 这一章要上纸的图，按 `Chapter.images` 的原顺序。
    ///
    /// 单一口径放在这里：分页端和渲染端必须拿到**同一份**，两边各筛一次迟早分家——
    /// 纸上的图比量到的多，那一面就超页（红线「量的 ≥ 纸上的」反了）。
    ///
    /// 无表可依（`imageTally == nil`，老书单还没补算）时原样交出，不筛。
    func placedImages(
        _ images: [ChapterImage],
        chapterURL: URL
    ) -> [ChapterImage] {
        Self.placedImages(
            images,
            chapterURL: chapterURL,
            tally: imageTally,
            chapterCount: chapters.count
        )
    }

    /// 判据本体。上面那一条只是把书上那两项喂进来，这一份是**给已经在书单之外的那一侧**
    /// 用的（`BookPagination` 在量全书那一趟里跨了 actor 跳，带不动 `Book`，只带得出
    /// 这张表和章数这两个值）。两条走的是同一段代码，分不了家。
    static func placedImages(
        _ images: [ChapterImage],
        chapterURL: URL,
        tally: [String: Int]?,
        chapterCount: Int
    ) -> [ChapterImage] {

        guard let tally else { return images }

        return images.filter {
            !ChapterImage.isDecorativeImage(
                occurrences: tally[
                    ChapterImage.imageKey(href: $0.href, chapterURL: chapterURL)
                ] ?? 0,
                chapterCount: chapterCount
            )
        }
    }
}
