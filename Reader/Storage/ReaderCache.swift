//
//  ReaderCache.swift
//  Reader
//
//  生成物（合成音频 + 章节解析结果）的落盘位置和体积口径。
//
//  两类东西分开放，理由是「被删掉要付什么代价」不一样：
//
//  - 音频：`Library/Caches/novel/{bookID}/{chapterID}/…`。随时能从正文重合成，
//    放系统缓存目录，磁盘紧张时可以让系统自己回收。
//  - 解析结果（chapter.json：角色表、每句的情绪/语速/说话人）：
//    `Application Support/AIReader/cache/novel/{bookID}/chapters/…`。重跑一遍
//    本地 LLM 比重新合成音频贵得多，而且是被 C 端用户等出来的结果，不能让系统
//    背着我们删——所以它归在 `cache/` 这个口径下统一统计和清理，但不在 Caches 目录。
//
//  书单（books.json）、正文（Books/ 下解压出来的 EPUB）**不是缓存**：删了要用户
//  重新导入，所以这两个都不在上面两棵树里，清理与统计都碰不到它们。
//

import Foundation

enum ReaderCache {

    /// 音频根：`Library/Caches/novel`
    static let audioRoot: URL = {
        let base = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        )[0]
        let url = base.appendingPathComponent("novel", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// 解析结果根：`Application Support/AIReader/cache/novel`
    static let analysisRoot: URL = {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        let url = base
            .appendingPathComponent("AIReader", isDirectory: true)
            .appendingPathComponent("cache", isDirectory: true)
            .appendingPathComponent("novel", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static func bookAudioDirectory(_ bookID: UUID) -> URL {
        audioRoot.appendingPathComponent(bookID.uuidString, isDirectory: true)
    }

    static func bookAnalysisDirectory(_ bookID: UUID) -> URL {
        analysisRoot.appendingPathComponent(bookID.uuidString, isDirectory: true)
    }

    // MARK: - Size

    /// 一本书占的缓存字节（音频 + 解析）。
    static func size(ofBook bookID: UUID) -> Int64 {
        allocatedSize(of: bookAudioDirectory(bookID)) + allocatedSize(of: bookAnalysisDirectory(bookID))
    }

    /// 全部缓存字节，口径就是上面两棵树，别的都不算。
    static func totalSize() -> Int64 {
        allocatedSize(of: audioRoot) + allocatedSize(of: analysisRoot)
    }

    private static func allocatedSize(of directory: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }   // 读不动的子目录跳过：统计不该把 App 弄崩
        ) else { return 0 }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [
                .totalFileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey,
            ]), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
        }
        return total
    }

    /// 给人看的体积。1024 进制：磁盘占用本来就是这么算的。
    static func format(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        return unit == 0
            ? "\(Int(value)) B"
            : String(format: "%.1f %@", value, units[unit])
    }

    // MARK: - 旧布局清理

    /// 升级前的一切生成物都在 `Application Support/AIReader/{bookID}/` 一棵树下
    /// （音频和 chapters/ 混在一起）。目录一改，那棵树里的东西一条都读不到：
    /// chapter.json 换了位置，里面存的又是绝对路径。留着只是几百 MB 死数据，
    /// 所以启动时删一次，正文和书单不碰（用户确认过：清空重录）。
    ///
    /// 判据用「目录名是不是一个 UUID」——同层剩下的只有 `Books`、`cache` 和两个
    /// `.json`，都不会误伤，也不需要维护一张保留名单。
    static func migrateLegacyLayoutOnce() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: legacyLayoutFlag) else { return }

        let readerRoot = analysisRoot
            .deletingLastPathComponent()   // …/AIReader/cache
            .deletingLastPathComponent()   // …/AIReader
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: readerRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            defaults.set(true, forKey: legacyLayoutFlag)
            return
        }

        var removed: Int64 = 0
        var books: Int = 0
        for url in children where url.lastPathComponent.isUUIDString {
            removed += allocatedSize(of: url)
            try? FileManager.default.removeItem(at: url)
            books += 1
        }

        defaults.set(true, forKey: legacyLayoutFlag)
        if books > 0 {
            print("[Cache] 旧布局清理：删掉 \(books) 本书的旧缓存目录，释放 \(format(removed))（音频与解析将在打开时重做）")
        }
    }

    private static let legacyLayoutFlag = "readerCacheLayoutV2"
}

private extension String {
    /// 只有标准大写形态的 UUID 才算，避免哪天 `Books` 改名撞上一个十六进制词。
    var isUUIDString: Bool { UUID(uuidString: self) != nil }
}
