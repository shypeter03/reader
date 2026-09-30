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

    /// 封面副本根：`Application Support/AIReader/covers`
    static let coverRoot: URL = {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        let url = base
            .appendingPathComponent("AIReader", isDirectory: true)
            .appendingPathComponent("covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// 一本书的封面副本位置。按 bookID 命名，所以「重新导入同一本书」也对得上号。
    static func coverCopy(for bookID: UUID, source: URL) -> URL {
        let ext = source.pathExtension.lowercased()
        return coverRoot.appendingPathComponent(bookID.uuidString + (ext.isEmpty ? "" : "." + ext))
    }

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

    // MARK: - 部署丢内容取证

    /// 「每次 ⌘R 装完新构建，正文/标注/音频就没了，可书单和阅读进度还在」的现场取证。
    /// 启动时跑一次，结论全部进 `[Persist]` 日志。
    ///
    /// 只用容器内的事实就能把死因定下来，因为三棵树的分界很清楚：
    ///
    /// - `books.json` 都不在 → 数据容器是全新的（部署确实发生了卸载重装）。容器里的东西
    ///   应用侧怎么写都保不住，要改的是安装方式，不是代码；
    /// - `books.json` 在、正文树或解析树不在 → 沙箱没换，是里面被选择性清掉了，
    ///   再按创建时间分：书单本身也是刚刚才建的话，说明它是新容器里重新写出来的；
    /// - 只有音频树空 → 系统回收 `Library/Caches`。那是目录选错了，不是谁删的。
    ///
    /// 报告逻辑收在 ``persistenceReport(layout:now:)`` 里，布局当参数传进来：
    /// 真机上用真实路径，无头验证时喂假目录，判定这一条路是同一套代码。
    struct PersistenceLayout {
        let appSupport: URL
        let readerRoot: URL
        let booksFile: URL
        let textRoot: URL
        let analysisRoot: URL
        let audioRoot: URL
    }

    static func persistenceLayout() -> PersistenceLayout {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let readerRoot = appSupport.appendingPathComponent("AIReader", isDirectory: true)
        return PersistenceLayout(
            appSupport: appSupport, readerRoot: readerRoot,
            booksFile: readerRoot.appendingPathComponent("books.json"),
            textRoot: readerRoot.appendingPathComponent("Books", isDirectory: true),
            analysisRoot: analysisRoot, audioRoot: audioRoot
        )
    }

    static func logPersistenceDiagnostics() {
        for line in persistenceReport(layout: persistenceLayout(), now: Date()) { print(line) }
    }

    static func persistenceReport(layout: PersistenceLayout, now: Date) -> [String] {
        let fm = FileManager.default
        var lines: [String] = []

        let free = (try? layout.appSupport.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?
            .volumeAvailableCapacity
        lines.append("[Persist] 沙箱 \(layout.appSupport.path)｜卷内可用 \(free.map { format(Int64($0)) } ?? "未知")")

        // AIReader/ 一眼看清：谁在、谁不在、是谁刚刚才建的
        let children = (try? fm.contentsOfDirectory(
            at: layout.readerRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        if children.isEmpty {
            lines.append("[Persist] AIReader/ 空或不存在 → 这个容器里从来没落过东西")
        } else {
            let described = children.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { url -> String in
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .creationDateKey, .fileSizeKey])
                let isDir = values?.isDirectory == true
                let size = isDir ? allocatedSize(of: url) : Int64(values?.fileSize ?? 0)
                let born = values?.creationDate.map { "建于\(ago($0, now))" } ?? "建于?"
                return "\(url.lastPathComponent)\(isDir ? "/" : "") \(format(size)) \(born)"
            }
            lines.append("[Persist] AIReader/ \(described.joined(separator: "｜"))")
        }

        let books = (try? Data(contentsOf: layout.booksFile))
            .flatMap { try? JSONDecoder().decode([Book].self, from: $0) } ?? []
        var textPresent = 0, coverPresent = 0, declared = 0
        var declaredIDs = Set<UUID>()
        for book in books {
            if fm.fileExists(atPath: book.epubRootURL.path) { textPresent += 1 }
            if let cover = book.coverURL, fm.fileExists(atPath: cover.path) { coverPresent += 1 }
            declared += book.chapters.count
            declaredIDs.formUnion(book.chapters.map(\.id))
        }
        // 落库的章节 id 有多少是书单现在认领的。「章节对不上」就是这一条：
        // 书重新导入过，id 换了一茬，旧的正文/标注/音频全挂在没人认的 id 下。
        var claimed = 0, orphaned = 0, orphanedBytes: Int64 = 0
        for bookDir in childDirectories(of: layout.analysisRoot) where bookDir.lastPathComponent.isUUIDString {
            for chapterDir in childDirectories(of: bookDir.appendingPathComponent("chapters", isDirectory: true))
            where chapterDir.lastPathComponent.isUUIDString {
                if UUID(uuidString: chapterDir.lastPathComponent).map(declaredIDs.contains) == true {
                    claimed += 1
                } else {
                    orphaned += 1
                    orphanedBytes += allocatedSize(of: chapterDir)
                }
            }
        }
        lines.append("[Persist] 书单 \(books.count) 本｜正文在 \(textPresent)/\(books.count)｜封面在 \(coverPresent)/\(books.count)"
            + "｜解析 \(format(allocatedSize(of: layout.analysisRoot)))｜音频 \(format(allocatedSize(of: layout.audioRoot)))")
        lines.append("[Persist] 章节 认领 \(claimed)/声明 \(declared)｜无人认领 \(orphaned) 个共 \(format(orphanedBytes))"
            + (orphaned > 0 ? " ← 落库的东西挂在旧书单名下，现在的书读不到它们" : ""))

        let audit = pathAudit(books: books, layout: layout, fm: fm, now: now)
        lines.append(contentsOf: audit.lines)

        let booksBorn = (try? layout.booksFile.resourceValues(forKeys: [.creationDateKey]))?.creationDate
        let booksFresh = booksBorn.map { now.timeIntervalSince($0) < 120 } ?? false
        let analysisEmpty = childDirectories(of: layout.analysisRoot).isEmpty
        let textEmpty = childDirectories(of: layout.textRoot).isEmpty
        let audioEmpty = childDirectories(of: layout.audioRoot).isEmpty
        let verdict: String
        if !fm.fileExists(atPath: layout.booksFile.path) {
            verdict = "书单文件本身也不在 → 容器是全新的，部署真的把 App 卸载重装了。"
                + "容器内任何东西都保不住，要动的是安装方式"
        } else if audit.staleContainer > 0 {
            verdict = "\(audit.textMissing) 本书的单子指向不到正文，其中 \(audit.staleContainer) 本把路径接回当前沙盒就又有 → "
                + "死因是书单存的是**绝对路径**、容器 UUID 换过，东西在原地。要改的是路径口径，不是往沙盒补数据"
        } else if audit.textMissing > 0 {
            verdict = "\(audit.textMissing) 本书的正文目录接回当前沙盒也不在 → 正文是真没了。"
                + "对照上面 Books/ 实到目录：名字对不上就说明那些目录属于没人认领的旧导入"
        } else if booksFresh, analysisEmpty, textEmpty {
            verdict = "books.json 是 \(ago(booksBorn!, now)) 才建的，且正文/解析树都空 → 容器仍是新的，"
                + "这份书单是这次装完重写出来的，不是上次留下的"
        } else if analysisEmpty, textEmpty {
            verdict = "容器没换（书单还是老的），但正文树和解析树都没了 → 沙箱内被删。"
                + "本 App 只有「清空音频与标注」「删除这本书」两条删除路径，都打日志，按时间点对照谁动的手"
        } else if audioEmpty {
            verdict = "只剩音频树空了 → 系统回收了 Library/Caches（卷内可用只剩 \(free.map { format(Int64($0)) } ?? "?")）。"
                + "音频放在可回收目录，代价就是几十秒/句重合成"
        } else {
            verdict = "三棵树都在：这次启动没丢东西"
        }
        lines.append("[Persist] 判定：\(verdict)")
        return lines
    }

    /// 路径审计的产出。
    private struct PathAudit {
        var lines: [String] = []
        /// 正文在书单记的路径上读不到的书数
        var textMissing = 0
        /// 正文或封面里，「接回当前沙盒前缀就又能读到」的书数
        var staleContainer = 0
    }

    private enum PathState: Equatable {
        case inPlace          // 记的路径直接读得到
        case staleContainer   // 记的路径读不到，但换当前容器前缀后有
        case gone             // 换前缀也没有 → 真没了
    }

    /// 「正文/封面在不在」光看目录树是判不出来的：书单里存的是**绝对** file URL
    /// （`epubRootURL`、`coverURL`、每个 `ChapterDescriptor.fileURL` 都是）。容器 UUID 一换，
    /// 文件原地没动也会一律读不到 —— 那种情况该改的是路径口径，不是往沙盒里补数据。
    /// 所以每本书再走一遍：把绝对路径里「`Library/Application Support` 以下」那一截接到
    /// 当前沙盒上试一次。接得上 = 路径过期，接不上 = 真没了。
    /// 顺带列出 `Books/` 实到目录（名字/大小/生日），不然「树还在」会被误判成「没丢东西」。
    private static func pathAudit(
        books: [Book],
        layout: PersistenceLayout,
        fm: FileManager,
        now: Date
    ) -> PathAudit {
        var audit = PathAudit()

        for book in books.prefix(8) {
            let text = state(of: book.epubRootURL, layout: layout, fm: fm)
            let cover: (PathState, String)
            if let url = book.coverURL {
                cover = state(of: url, layout: layout, fm: fm)
            } else {
                cover = (.inPlace, "书单里没记")
            }
            if text.0 != .inPlace { audit.textMissing += 1 }
            if text.0 == .staleContainer || cover.0 == .staleContainer { audit.staleContainer += 1 }
            audit.lines.append(
                "[Persist] 路径 「\(book.title.prefix(12))」正文 \(text.1)｜封面 \(cover.1)"
            )
        }
        if books.count > 8 {
            audit.lines.append("[Persist] 路径 …其余 \(books.count - 8) 本未审计")
        }

        let dirs = childDirectories(of: layout.textRoot).sorted { $0.lastPathComponent < $1.lastPathComponent }
        let listed = dirs.prefix(8).map { url -> String in
            let born = (try? url.resourceValues(forKeys: [.creationDateKey]))?
                .creationDate.map { ago($0, now) } ?? "?"
            return "\(url.lastPathComponent) \(format(allocatedSize(of: url))) 建于\(born)"
        }
        audit.lines.append(
            "[Persist] Books/（正文树）实到 \(dirs.count) 个导入目录"
                + (listed.isEmpty ? "（空的）" : "：" + listed.joined(separator: "｜"))
        )
        return audit
    }

    /// 记在书单里的路径现在到底读不读得到，以及「换回当前沙盒前缀」能不能救回来。
    private static func state(
        of url: URL,
        layout: PersistenceLayout,
        fm: FileManager
    ) -> (PathState, String) {
        if fm.fileExists(atPath: url.path) { return (.inPlace, "在") }

        let stored = containerID(of: url.path) ?? "非沙盒"
        let current = containerID(of: layout.appSupport.path) ?? "非沙盒"
        let note = "存于容器\(stored.prefix(8))，当前\(current.prefix(8))"

        guard let relative = sandboxRelative(url.path) else {
            return (.gone, "不在｜\(note)，且路径不是本沙盒的形状")
        }
        let rebased = URL(fileURLWithPath: layout.appSupport.path + "/" + relative)
        if fm.fileExists(atPath: rebased.path) {
            return (.staleContainer, "不在（\(note)），接回当前沙盒后有：\(relative)")
        }
        return (.gone, "不在（\(note)），接回当前沙盒也没有：\(relative)")
    }

    /// `/var/mobile/Containers/Data/Application/<UUID>/…` 里的那一段。拿不到说明路径
    /// 不是标准沙盒形状（比如 Mac 上跑），判定时按「非沙盒」处理。
    private static func containerID(of path: String) -> String? {
        let marker = "/Containers/Data/Application/"
        guard let range = path.range(of: marker) else { return nil }
        let rest = path[range.upperBound...]
        guard let end = rest.firstIndex(of: "/") else { return String(rest) }
        return String(rest[..<end])
    }

    /// 沙盒根（`Library/Application Support`）以下那一截，用来把过期的绝对路径接回当前容器。
    private static func sandboxRelative(_ path: String) -> String? {
        let marker = "/Library/Application Support/"
        guard let range = path.range(of: marker) else { return nil }
        let rest = String(path[range.upperBound...])
        return rest.isEmpty ? nil : rest
    }

    private static func ago(_ date: Date, _ now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<120: return "\(Int(seconds)) 秒前"
        case ..<7200: return "\(Int(seconds / 60)) 分钟前"
        case ..<172_800: return "\(Int(seconds / 3600)) 小时前"
        default: return "\(Int(seconds / 86_400)) 天前"
        }
    }

    private static func childDirectories(of url: URL) -> [URL] {
        guard let list = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        return list
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
