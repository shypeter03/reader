//
//  BookStore.swift
//  Reader
//
//  Created by 粟海洋 on 2026/9/21.
//

import Foundation

actor BookStore {

    static let shared = BookStore()

    private let booksFileURL: URL

    private var books: [Book] = []

    private var booksLoaded = false

    private init() {

        let base =
            FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0]

        let rootURL =
            base
            .appendingPathComponent(
                "AIReader",
                isDirectory: true
            )

        try? FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )

        booksFileURL =
            rootURL
            .appendingPathComponent(
                "books.json"
            )
    }

    // MARK: - Public API

    func getAll() -> [Book] {
        loadIfNeeded()
        return books
    }

    func add(_ book: Book) {
        loadIfNeeded()
        books.append(book)
        saveToDisk()
    }

    func update(_ book: Book) {
        loadIfNeeded()
        if let index = books.firstIndex(where: { $0.id == book.id }) {
            books[index] = book
            saveToDisk()
        }
    }

    func delete(id: UUID) {
        loadIfNeeded()
        books.removeAll { $0.id == id }
        saveToDisk()
    }

    /// 落一次阅读位置：章在 `chapters` 里的下标 + 章内句序。
    /// 每切一句都会调到这里，所以值没变就绝不写盘（整份书单会被重新编码一遍）。
    func setProgress(
        bookID: UUID,
        chapterIndex: Int,
        sentenceIndex: Int
    ) {
        loadIfNeeded()
        guard let index = books.firstIndex(where: { $0.id == bookID }) else {
            return
        }
        guard books[index].lastReadChapter != chapterIndex
            || books[index].lastReadSentence != sentenceIndex else {
            return
        }
        books[index].lastReadChapter = chapterIndex
        books[index].lastReadSentence = sentenceIndex
        saveToDisk()
    }

    // MARK: - Persistence

    /// init 是 nonisolated 的，读盘必须延到首次 actor 隔离访问时做。
    private func loadIfNeeded() {
        guard !booksLoaded else { return }
        booksLoaded = true
        loadFromDisk()
    }

    private func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: booksFileURL.path) else {
            return
        }

        do {
            let data = try Data(contentsOf: booksFileURL)
            books = try JSONDecoder().decode([Book].self, from: data)
            print("BookStore: 加载了 \(books.count) 本书")
        } catch {
            print("BookStore: 加载失败 - \(error)")
            books = []
        }
    }

    private func saveToDisk() {
        do {
            let data = try JSONEncoder().encode(books)
            try data.write(to: booksFileURL)
            print("BookStore: 保存了 \(books.count) 本书")
        } catch {
            print("BookStore: 保存失败 - \(error)")
        }
    }
}
