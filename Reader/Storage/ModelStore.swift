//
//  ModelStore.swift
//  Reader
//
//  下载回来的千问权重在沙盒里的落点、就绪判定、体积与删除。
//
//  目录选 `Application Support` 而不是 `Library/Caches`：TTS 那一份 1.6GB 重下一次要
//  几分钟，系统回收缓存不该把它顺手带走（音频那种「几十秒就能重做」的才配待在 Caches，
//  见 `ReaderCache` 的分界说明）。
//

import Foundation

enum ModelStore {

    /// 权重根：`Application Support/AIReader/models`
    static let root: URL = {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        var url = base
            .appendingPathComponent("AIReader", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // 这一棵树是可重下的 1.6GB，不该跟着 iCloud 备份走。
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return url
    }()

    static func directory(_ id: ModelID) -> URL {
        root.appendingPathComponent(ModelManifest.spec(id).directoryName, isDirectory: true)
    }

    /// 清单里这一个文件该落在哪儿。
    static func installURL(for file: ModelFile, in directory: URL) -> URL {
        directory.appendingPathComponent(file.relativePath)
    }

    // MARK: - 就绪

    /// 齐了没有：清单里每个文件都在、字节对得上（含随包复制过去的那一个）。
    ///
    /// 不复核 sha256：那要把 1.6GB 整读一遍，而这条每次开 App、每次排 TTS 降级链都要问。
    /// 下载那一刻已经逐文件校过，之后只有用户手动删改或写坏才会不一致——那种情况由加载方
    /// 自己报错（`Qwen3TTSService.missingComponents`、MLX 的 safetensors 校验）。
    static func isReady(_ id: ModelID) -> Bool {
        missingFiles(id).isEmpty
    }

    /// 就绪才交出目录；没就位返回 nil，加载方拿它决定要不要往下建模型。
    static func directoryIfReady(_ id: ModelID) -> URL? {
        let url = directory(id)
        guard isReady(id) else { return nil }
        return url
    }

    /// 还缺哪些文件（含还没从 bundle 复制的那一个）。
    static func missingFiles(_ id: ModelID) -> [ModelFile] {
        let directory = self.directory(id)
        return ModelManifest.spec(id).files.filter { !matches($0, in: directory) }
    }

    /// 在清单里、需要从网络下的那一些中，现在还不缺的字节数（给进度当起点）。
    static func installedBytes(of id: ModelID) -> Int64 {
        let directory = self.directory(id)
        return ModelManifest.spec(id).files
            .filter { matches($0, in: directory) }
            .reduce(0) { $0 + $1.bytes }
    }

    /// 这套权重现在占了多少盘（数目录里的实际字节，不看清单）。
    static func allocatedBytes(of id: ModelID) -> Int64 {
        allocatedBytes(at: directory(id))
    }

    private static func matches(_ file: ModelFile, in directory: URL) -> Bool {
        actualSize(at: installURL(for: file, in: directory)) == file.bytes
    }

    private static func actualSize(at url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true
        else { return nil }
        return Int64(values.fileSize ?? -1)
    }

    // MARK: - 随包那一个文件的复制

    /// 把 bundle 里那一个 `tokenizer.json` 复制进模型目录（HF 上没有它，加载却必须有）。
    ///
    /// 已经在、字节也对 → 什么都不做。返回问题清单（空 = 齐了）：调用方要么在开跑前
    /// 先补一次，要么在下载完成后补一次，两条都走得通。
    @discardableResult
    static func seedBundledFiles(_ id: ModelID) -> [String] {
        let directory = self.directory(id)
        var problems: [String] = []

        for file in ModelManifest.spec(id).files {
            guard case .appBundle(let folder) = file.source else { continue }
            if matches(file, in: directory) { continue }

            let source = Bundle.main
                .url(forResource: folder, withExtension: nil)?
                .appendingPathComponent(file.fileName)

            guard let source, actualSize(at: source) == file.bytes else {
                problems.append("bundle 里找不到 \(folder)/\(file.fileName)")
                continue
            }
            let dest = installURL(for: file, in: directory)
            do {
                try FileManager.default.createDirectory(
                    at: dest.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                // 覆盖旧的：上一次复制可能是残缺的（进程被杀在写盘中间）。
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.copyItem(at: source, to: dest)
            } catch {
                problems.append("复制 \(file.fileName) 失败：\(error.localizedDescription)")
            }
        }
        return problems
    }

    // MARK: - 删除

    /// 删掉一整套权重（目录整个不见，正在放的声音由调用方负责先停）。
    static func removeAll(_ id: ModelID) throws {
        let url = directory(id)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
        noteChange()
    }

    // MARK: - 体积

    static func allocatedBytes(at directory: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
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

    /// 两套一起占的盘，给「数据」那一节的统计用。
    static func totalAllocatedBytes() -> Int64 {
        ModelID.allCases.reduce(0) { $0 + allocatedBytes(of: $1) }
    }

    // MARK: - 变化通知

    /// 装成一套或删掉一套之后发这条，并给 `changeCount` +1。
    ///
    /// 为什么要一个计数而不只是通知：TTS 那条降级链在排链时查过一次「权重在不在」，
    /// 留着不重查（每句都走 file manager 不划算），但也不能在用户下载完之后还当它缺。
    /// 于是每句只比一个整数，计数变了才 stat 一次。
    static let didChangeNotification = Notification.Name("AIReader.models.didChange")

    private static let changes = LockedCounter()

    static var changeCount: Int { changes.value }

    static func noteChange() {
        changes.increment()
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
}

/// 一个带锁的整数：写的一方在主线程（下载完成/删除），读的一方在 TTS 那条 actor 上。
private final class LockedCounter: @unchecked Sendable {

    private let lock = NSLock()

    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}
