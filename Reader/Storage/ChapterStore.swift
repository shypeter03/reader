//
//  ChapterStore.swift
//  Reader
//

import Foundation

actor ChapterStore {

    private let rootURL: URL

    init() {

        let base =
            FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0]

        rootURL =
            base
            .appendingPathComponent(
                "AIReader",
                isDirectory: true
            )

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
