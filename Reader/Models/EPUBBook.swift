//
//  EPUBBook.swift
//  Reader
//
//  Created by 粟海洋 on 2026/8/26.
//

import Foundation

struct EPUBBook: Identifiable {

    let id: UUID

    let title: String

    let author: String?

    /// EPUB 解压后的根目录
    let rootURL: URL

    /// OPF 文件所在目录
    let opfDirectory: URL

    /// 封面文件
    let coverURL: URL?

    /// 章节索引
    let chapters: [ChapterDescriptor]

    init(
        id: UUID = UUID(),
        title: String,
        author: String?,
        rootURL: URL,
        opfDirectory: URL,
        coverURL: URL?,
        chapters: [ChapterDescriptor]
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.rootURL = rootURL
        self.opfDirectory = opfDirectory
        self.coverURL = coverURL
        self.chapters = chapters
    }
}

extension EPUBBook {

    func makeBook() -> Book {

        Book(
            id: id,
            title: title,
            author: author,
            coverURL: coverURL,
            epubRootURL: rootURL,
            chapters: chapters
        )
    }
}
