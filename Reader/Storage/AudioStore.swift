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
