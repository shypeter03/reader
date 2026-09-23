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

    init(
        id: UUID = UUID(),
        title: String,
        author: String?,
        coverURL: URL?,
        epubRootURL: URL,
        chapters: [ChapterDescriptor],
        lastReadChapter: Int = 0,
        lastReadSentence: Int = 0
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.coverURL = coverURL
        self.epubRootURL = epubRootURL
        self.chapters = chapters
        self.lastReadChapter = lastReadChapter
        self.lastReadSentence = lastReadSentence
    }
}
