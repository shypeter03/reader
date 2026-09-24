//
//  AudioStore.swift
//  Reader
//
//  Created by 粟海洋 on 2026/8/26.
//

import Foundation

actor AudioStore {

    /// 音频落在 `Library/Caches/novel/` 下（见 ``ReaderCache``）：可以让系统在
    /// 磁盘紧张时回收，所以 `load` 返回 nil 是正常结果，不是错误。
    private let rootURL: URL = ReaderCache.audioRoot

    init() {
        try? FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
    }

    /// - Parameter backendSubdirectory: 不同 TTS 后端的命名空间（`edge-v1`/`kokoro-v3`），
    ///   换主后端时互不误命中；传 nil 时不带这一层（Qwen3-TTS 的平铺形状）。
    func save(
        data: Data,
        bookID: UUID,
        chapterID: UUID,
        sentenceID: UUID,
        backendSubdirectory: String? = nil
    ) throws -> URL {

        let chapterURL =
            audioDirectory(
                bookID: bookID,
                chapterID: chapterID,
                backendSubdirectory: backendSubdirectory
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
        sentenceID: UUID,
        backendSubdirectory: String? = nil
    ) -> URL? {

        let chapterURL =
            audioDirectory(
                bookID: bookID,
                chapterID: chapterID,
                backendSubdirectory: backendSubdirectory
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
        sentenceID: UUID,
        backendSubdirectory: String? = nil
    ) {

        let url =
            audioDirectory(
                bookID: bookID,
                chapterID: chapterID,
                backendSubdirectory: backendSubdirectory
            )
            .appendingPathComponent(
                "\(sentenceID.uuidString).wav"
            )

        try? FileManager.default.removeItem(
            at: url
        )
    }

    /// 清掉整本书的合成产物：`Caches/novel/{bookID}/` 整棵树。
    /// 解析结果不在这棵树下（它在 Application Support 的 cache/ 里），
    /// 所以「清空音频与标注」要两个 store 各删一次，别只调这里。
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
        chapterID: UUID,
        backendSubdirectory: String? = nil
    ) -> URL {

        let base =
            rootURL
            .appendingPathComponent(
                bookID.uuidString,
                isDirectory: true
            )
            .appendingPathComponent(
                chapterID.uuidString,
                isDirectory: true
            )

        guard let backendSubdirectory else { return base }

        return base.appendingPathComponent(
            backendSubdirectory,
            isDirectory: true
        )
    }
}
