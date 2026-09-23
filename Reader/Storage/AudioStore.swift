//
//  AudioStore.swift
//  Reader
//
//  Created by 粟海洋 on 2026/8/26.
//

import Foundation

actor AudioStore {

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

    func save(
        data: Data,
        bookID: UUID,
        chapterID: UUID,
        sentenceID: UUID
    ) throws -> URL {

        let chapterURL =
            audioDirectory(
                bookID: bookID,
                chapterID: chapterID
            )

        try FileManager.default.createDirectory(
            at: chapterURL,
            withIntermediateDirectories: true
        )

        let url =
            chapterURL
            .appendingPathComponent(
                "\(sentenceID.uuidString).wav"
            )

        try data.write(to: url)

        return url
    }

    func load(
        bookID: UUID,
        chapterID: UUID,
        sentenceID: UUID
    ) -> URL? {

        let chapterURL =
            audioDirectory(
                bookID: bookID,
                chapterID: chapterID
            )

        let url =
            chapterURL
            .appendingPathComponent(
                "\(sentenceID.uuidString).wav"
            )

        guard FileManager.default
            .fileExists(atPath: url.path)
        else {
            return nil
        }

        return url
    }

    /// 删除某句音频。重录前必须先删：文件名只由 sentenceID 决定，
    /// 留着旧文件下一次 load 会直接命中它。
    func delete(
        bookID: UUID,
        chapterID: UUID,
        sentenceID: UUID
    ) {

        let url =
            audioDirectory(
                bookID: bookID,
                chapterID: chapterID
            )
            .appendingPathComponent(
                "\(sentenceID.uuidString).wav"
            )

        try? FileManager.default.removeItem(
            at: url
        )
    }

    /// 清掉整本书的合成产物。这里删的是 AIReader/{bookID}/ 整棵目录，
    /// ChapterStore 的 chapters/ 就在同一棵树下，所以一次删净：只删 .wav 会
    /// 留下指向已消失文件的 audioURL，那种句子再也不会被重新排产生成。
    func deleteBook(
        bookID: UUID
    ) {

        let url =
            rootURL.appendingPathComponent(
                bookID.uuidString,
                isDirectory: true
            )

        try? FileManager.default.removeItem(
            at: url
        )
    }

    private func audioDirectory(
        bookID: UUID,
        chapterID: UUID
    ) -> URL {

        rootURL
            .appendingPathComponent(
                bookID.uuidString,
                isDirectory: true
            )
            .appendingPathComponent(
                chapterID.uuidString,
                isDirectory: true
            )
    }
}
