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
            coverURL: storedCoverURL(),
            epubRootURL: rootURL,
            chapters: chapters
        )
    }

    /// 封面单独拷一份到 `AIReader/covers/{bookID}.<原扩展名>`，书单记的是这一份。
    ///
    /// 原来记的是解压出来的 EPUB 树里那个路径，于是封面的命跟正文绑在一起：正文树没了
    /// （删过一次旧导入、重新导入换了目录名）或者容器 UUID 变了，封面就一起读不到 ——
    /// 而表现是「重新部署以后书库全是占位色卡」。封面只有几百 KB，按 bookID 存一份，
    /// 既能扛住正文树整棵消失，也是「书还在、封面没了」这条判据唯一的独立证据。
    private func storedCoverURL() -> URL? {

        guard let coverURL,
              FileManager.default.fileExists(atPath: coverURL.path)
        else {
            return nil
        }

        let target = ReaderCache.coverCopy(for: id, source: coverURL)

        do {
            try FileManager.default.copyItem(at: coverURL, to: target)
            return target
        } catch {
            // 同名副本已经存在（重复导入同一本书）或写入失败：不影响能不能读，退回原路径
            print("[Import] 封面副本没写成：\(error.localizedDescription)，用 EPUB 树内路径")
            return coverURL
        }
    }
}
