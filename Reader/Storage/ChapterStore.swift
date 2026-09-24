//
//  ChapterStore.swift
//  Reader
//

import Foundation

actor ChapterStore {

    /// 解析结果落在 `Application Support/AIReader/cache/novel/`（见 ``ReaderCache``）：
    /// 归缓存口径统计和清理，但故意不放 `Library/Caches` —— 重跑一遍本地 LLM 太贵，
    /// 不能让系统在后台替我们删。
    private let rootURL: URL = ReaderCache.analysisRoot

    init() {
        try? FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
    }

    // MARK: - Save

    func save(
        chapter: Chapter,
        bookID: UUID
    ) throws {

        let directoryURL = chapterDirectory(
            bookID: bookID,
            chapterID: chapter.id
        )

        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )

        let fileURL = directoryURL.appendingPathComponent("chapter.json")

        let data = try JSONEncoder().encode(chapter)

        try data.write(to: fileURL)
    }

    // MARK: - Load

    func load(
        bookID: UUID,
        chapterID: UUID
    ) -> Chapter? {

        let directoryURL = chapterDirectory(
            bookID: bookID,
            chapterID: chapterID
        )

        let fileURL = directoryURL.appendingPathComponent("chapter.json")

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }

        guard let data = try? Data(contentsOf: fileURL) else {
            return nil
        }

        return try? JSONDecoder().decode(Chapter.self, from: data)
    }

    // MARK: - Check Exists

    func exists(
        bookID: UUID,
        chapterID: UUID
    ) -> Bool {

        let directoryURL = chapterDirectory(
            bookID: bookID,
            chapterID: chapterID
        )

        let fileURL = directoryURL.appendingPathComponent("chapter.json")

        return FileManager.default.fileExists(atPath: fileURL.path)
    }

    // MARK: - Delete

    func delete(
        bookID: UUID,
        chapterID: UUID
    ) {

        let directoryURL = chapterDirectory(
            bookID: bookID,
            chapterID: chapterID
        )

        try? FileManager.default.removeItem(at: directoryURL)
    }

    /// 清掉一本书的全部解析结果。音频在另一棵树（`Library/Caches/novel/`），
    /// 由 `AudioStore.deleteBook` 负责，两边要一起调。
    func deleteBook(
        bookID: UUID
    ) {
        try? FileManager.default.removeItem(
            at: ReaderCache.bookAnalysisDirectory(bookID)
        )
    }

    // MARK: - Directory

    private func chapterDirectory(
        bookID: UUID,
        chapterID: UUID
    ) -> URL {

        rootURL
            .appendingPathComponent(
                bookID.uuidString,
                isDirectory: true
            )
            .appendingPathComponent(
                "chapters",
                isDirectory: true
            )
            .appendingPathComponent(
                chapterID.uuidString,
                isDirectory: true
            )
    }
}
