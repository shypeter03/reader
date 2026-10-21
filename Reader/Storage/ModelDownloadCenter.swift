//
//  ModelDownloadCenter.swift
//  Reader
//
//  逐文件把千问权重拉到沙盒里：一个文件一次会话，收完就在后台读一遍算 sha256，
//  对得上才装进模型目录。
//
//  没有整包可下（实测 HF 和镜像的 `/archive/main.zip` 都是 404），所以进度只能是
//  「第 k 个文件 / 已收字节 / 校验中」这一种形状；分母用清单里的字节数，两套模型
//  各自一条进度。
//
//  取消丢掉当前那一个文件已收的字节，下一次从头下它：不落 `.part`，也就不需要断点续传
//  那套（resume data 会过期，跨 host 更是无效）。
//

import Combine
import CryptoKit
import Foundation

/// 当前那一个文件正处在哪一段。
enum ModelDownloadPhase: Equatable, Sendable {
    /// 正在收字节。
    case receiving
    /// 收完了，正在把整个文件读一遍核对 sha256。
    case verifying
}

struct ModelDownloadProgress: Equatable {
    let id: ModelID
    let phase: ModelDownloadPhase
    let fileName: String
    /// 这一套已经完成文件的字节 + 当前文件的 `fileBytesDone`（校验段也算当前文件）。
    let baseBytes: Int64
    let fileBytesDone: Int64
    let fileBytesTotal: Int64
    let modelBytesTotal: Int64

    var fileFraction: Double { Self.fraction(fileBytesDone, of: fileBytesTotal) }

    var modelFraction: Double { Self.fraction(baseBytes + fileBytesDone, of: modelBytesTotal) }

    var modelBytesDone: Int64 { baseBytes + fileBytesDone }

    private static func fraction(_ done: Int64, of total: Int64) -> Double {
        total > 0 ? Double(min(done, total)) / Double(total) : 0
    }
}

enum ModelDownloadError: Error, LocalizedError {

    case cancelled
    case httpStatus(code: Int, url: String)
    case unexpectedSize(file: String, got: Int64, want: Int64)
    case checksumMismatch(file: String, got: String)
    case network(file: String, reason: String)
    case installation(file: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "已取消"
        case .httpStatus(let code, let url):
            return "服务器返回 \(code)：\(url)"
        case .unexpectedSize(let file, let got, let want):
            return "\(file) 到手 \(got) 字节，清单写的是 \(want) 字节"
        case .checksumMismatch(let file, let got):
            return "\(file) 校验不过（sha256 \(got.prefix(12))… 与清单不一致），已丢弃"
        case .network(let file, let reason):
            return "\(file) 下载失败：\(reason)"
        case .installation(let file, let reason):
            return "\(file) 装不进模型目录：\(reason)"
        }
    }
}

/// 上一次失败。挂在具体的那一套上：两套共用一个 center，UI 才知道该在哪一行报这个错。
struct ModelDownloadFailure: Equatable {
    let id: ModelID
    let message: String
}

/// 一次跑一套模型，内部串行。UI 只读 `progress` 和 `lastFailure`。
@MainActor
final class ModelDownloadCenter: ObservableObject {

    static let shared = ModelDownloadCenter()

    @Published private(set) var progress: ModelDownloadProgress?

    /// 上一次失败的原因。再次开跑时清掉。
    @Published private(set) var lastFailure: ModelDownloadFailure?

    private var run: Task<Void, Never>?

    /// 现在在跑的那一套。`progress` 要等第一个字节到手才出现，所以「正在下哪一套」得单独记：
    /// 只按 `progress?.id` 判的话，按下按钮到进度条出现之间，那一行会闪回「未下载」。
    private var runningID: ModelID?

    /// 试过的源按「上次谁成了」重排：一次要下十几个文件，每个都先撞一遍超时再退镜像的话，
    /// 光等待就把几分钟的下载变成十几分钟（实测把第一个源换成连不上的域名，第二个文件的
    /// 那一次撞超时照样发生）。只在主 actor 上读写，不需要锁。
    private var hostOrder = ModelManifest.hosts

    /// 现在正在飞的那一个下载任务，取消按钮掐它。
    private var currentTask: URLSessionDownloadTask?

    var isBusy: Bool { run != nil }

    func isDownloading(_ id: ModelID) -> Bool {
        run != nil && runningID == id
    }

    // MARK: - 下载

    func start(_ id: ModelID) {
        guard run == nil else { return }
        lastFailure = nil

        let spec = ModelManifest.spec(id)
        let directory = ModelStore.directory(id)
        // 随包那一个先补上：它不占下载量，缺了这套却加载不起来。
        ModelStore.seedBundledFiles(id)

        let queue = ModelStore.missingFiles(id).filter { $0.repository != nil }
        let base = ModelStore.installedBytes(of: id)
        guard !queue.isEmpty else {
            ModelStore.noteChange()
            return
        }

        print("[Model] 开下 \(spec.displayName)：\(queue.count) 个文件 \(ReaderCache.format(spec.downloadBytes))"
            + "（已就位 \(ReaderCache.format(base))）")

        // 每个文件的起点先在这里算成一串常量：Task 体要在 MainActor 之外挂起再回来，
        // 捕获一个还在往上加的可变量的话，进度闭包读到的就是别的文件加过的数。
        var offsets: [Int64] = []
        offsets.reserveCapacity(queue.count)
        var acc = base
        for file in queue {
            offsets.append(acc)
            acc += file.bytes
        }
        let plan = Array(zip(queue, offsets))

        runningID = id
        run = Task {
            defer { self.run = nil; self.runningID = nil; self.currentTask = nil; self.progress = nil }
            do {
                for (file, fileBase) in plan {
                    try await self.download(
                        file: file,
                        dest: ModelStore.installURL(for: file, in: directory)
                    ) { phase, bytes in
                        Task { @MainActor in
                            self.publish(
                                ModelDownloadProgress(
                                    id: id,
                                    phase: phase,
                                    fileName: file.fileName,
                                    baseBytes: fileBase,
                                    fileBytesDone: bytes,
                                    fileBytesTotal: file.bytes,
                                    modelBytesTotal: spec.installedBytes
                                )
                            )
                        }
                    }
                }

                let problems = ModelStore.seedBundledFiles(id)
                if problems.isEmpty {
                    ModelStore.noteChange()
                    print("[Model] \(spec.displayName) 就位：\(ReaderCache.format(spec.installedBytes))"
                        + "，目录 \(directory.path)")
                } else {
                    self.lastFailure = ModelDownloadFailure(id: id, message: problems.joined(separator: "；"))
                    print("[Model] \(spec.displayName) 下完了但随包文件没补上：\(problems)")
                }
            } catch {
                if Task.isCancelled {
                    print("[Model] \(spec.displayName) 已取消（下一个文件从头下）")
                } else {
                    self.lastFailure = ModelDownloadFailure(id: id, message: error.localizedDescription)
                    print("[Model] \(spec.displayName) 失败：\(error.localizedDescription)")
                }
            }
        }
    }

    func cancel() {
        run?.cancel()
        currentTask?.cancel()
    }

    // MARK: - 删除

    /// 删掉一整套权重。正在下载的那一套先掐再删，不然删完还剩个任务在往里写。
    func delete(_ id: ModelID) {
        if run != nil {
            cancel()
        }
        // 体积在删之前量：删完再问就是 0，那条日志就变成「释放了 0 B」。
        let freed = ModelStore.allocatedBytes(of: id)
        do {
            try ModelStore.removeAll(id)
            print("[Model] 已删除 \(ModelManifest.spec(id).displayName)，释放 \(ReaderCache.format(freed))")
        } catch {
            lastFailure = ModelDownloadFailure(
                id: id,
                message: "删不掉：\(error.localizedDescription)"
            )
        }
    }

    // MARK: - 单个文件

    private func download(
        file: ModelFile,
        dest: URL,
        onEvent: @escaping @Sendable (ModelDownloadPhase, Int64) -> Void
    ) async throws {

        var lastError: Error?

        /// 只要有一个源答过话（哪怕答 404、哪怕校验不过），问题就不在「连不上」这一层，
        /// 那句排查提示不该盖在真正的原因上。
        var reachedServer = false
        var lastNetworkReason: String?

        for host in hostOrder {
            guard let url = file.url(from: host) else { break }

            print("[Model] ↓ \(file.fileName) ← \(url.absoluteString)")

            // 必须是 `.default`：`.ephemeral` 不继承系统代理，实测这台机器上同一个
            // config.json 在默认会话下 200/988 字节，换成 ephemeral 就只剩超时（-1001）——
            // 表现为「按了下载，进度一直是 0」。代理在用户机器上时开时关，所以两个源都要留。
            let config = URLSessionConfiguration.default
            // 30 秒管的是「两个数据块之间的空档」，不是整个文件的时限：1GB 那一个本来就要
            // 跑几分钟。这个数不能更小：实测走代理连 huggingface.co 的第一跳冷握手就超了
            // 15 秒（那次 hf-mirror 先 308 回本站，第二跳在 15 秒档上直接 -1001）。
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 3_600

            // 串行队列：校验那一步在它的回调里做，不能和主线程抢，也不能两个回调并进来
            // 改同一个 `settled`。
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            queue.qualityOfService = .utility

            let delegate = FileDownloadDelegate(file: file, dest: dest, onEvent: onEvent)
            let session = URLSession(configuration: config, delegate: delegate, delegateQueue: queue)
            let task = session.downloadTask(with: url)
            currentTask = task
            defer { currentTask = nil; session.invalidateAndCancel() }

            do {
                try await delegate.awaitDownload(of: task)
                prefer(host)
                return
            } catch let error as ModelDownloadError {
                if case .cancelled = error { throw error }
                switch error {
                case .network(_, let reason): lastNetworkReason = reason
                case .cancelled: break
                default: reachedServer = true
                }
                lastError = error
                print("[Model] \(file.fileName) 在 \(host) 没成：\(error.localizedDescription)")
            } catch {
                lastError = error
                print("[Model] \(file.fileName) 在 \(host) 没成：\(error.localizedDescription)")
            }
        }

        // 两个源都只在「连不上」这一层失败：光说 The request timed out. 分不清是设备断了网、
        // 系统里配了个不通的代理，还是这两个域名一起被挡。把源名和该查的东西一起报出去。
        if !reachedServer, let reason = lastNetworkReason {
            let names = hostOrder.map { $0.replacingOccurrences(of: "https://", with: "") }
                .joined(separator: "、")
            throw ModelDownloadError.network(
                file: file.fileName,
                reason: "\(reason)；\(names) 都连不通。先用这台设备的浏览器打开 hf-mirror.com："
                    + "浏览器也打不开就是这一档网络不通，换网络或关掉代理/VPN 再来"
            )
        }

        throw lastError
            ?? ModelDownloadError.network(file: file.fileName, reason: "两个源都连不上")
    }

    /// 把这一次成了的源挪到队首。`for host in hostOrder` 拿的是数组的副本，所以在迭代途中
    /// 改它不会让当前这一轮跳格。
    private func prefer(_ host: String) {
        guard hostOrder.first != host else { return }
        hostOrder.removeAll { $0 == host }
        hostOrder.insert(host, at: 0)
        print("[Model] 首选源换成 \(host)")
    }

    /// 进度只许往前走：回调是后台队列甩回主线程的，几次 `Task` 之间没有先后。
    private func publish(_ next: ModelDownloadProgress) {
        guard let current = progress else {
            progress = next
            return
        }
        if current.id == next.id,
            current.fileName == next.fileName,
            current.phase == next.phase,
            next.fileBytesDone < current.fileBytesDone {
            return
        }
        progress = next
    }
}

/// 一个文件一次会话。回调只管三件事：报进度、算 sha256、装进模型目录。
///
/// 必须声明成 `URLSessionDownloadDelegate`：落盘那一条（`didFinishDownloadingTo`）和
/// `didWriteData` 都是它的成员，早前列成 `URLSessionDataDelegate` 时 Swift 不把这两个方法
/// 暴露给 Objective-C 运行时，URLSession 一个都不调（实测轨迹只有「redirect → complete nil」），
/// 于是任务正常结束、continuation 却永远没人 resume——进度钉在 0，也不报错。
///
/// 系统给的那份临时文件在 `didFinishDownloadingTo` 返回后就被删掉，所以校验和 `moveItem`
/// 必须在那一次回调里做完——这也是它跑在自己的 OperationQueue 上的原因：1GB 的 sha256
/// 要把盘整读一遍，放主线程就是 UI 停几秒。
private final class FileDownloadDelegate: NSObject, URLSessionDownloadDelegate {

    private let file: ModelFile
    private let dest: URL
    private let onEvent: @Sendable (ModelDownloadPhase, Int64) -> Void

    private var continuation: CheckedContinuation<Void, Error>?

    /// 一次结清：`didFinishDownloadingTo` 之后还会来 `didCompleteWithError`，
    /// continuation resume 两次是崩溃。
    private var settled = false

    private var lastReported: [ModelDownloadPhase: Int64] = [:]

    /// 1MB 报一次：1GB 那一个就是约 1000 次，够顺也够不着让 SwiftUI 跟着每块抖一下。
    private let reportInterval = 1_048_576

    init(
        file: ModelFile,
        dest: URL,
        onEvent: @escaping @Sendable (ModelDownloadPhase, Int64) -> Void
    ) {
        self.file = file
        self.dest = dest
        self.onEvent = onEvent
    }

    func awaitDownload(of task: URLSessionDownloadTask) async throws {
        try await withTaskCancellationHandler(
            operation: {
                try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<Void, Error>) in
                    self.continuation = continuation
                    task.resume()
                }
            },
            onCancel: {
                task.cancel()
            }
        )
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        if totalBytesExpectedToWrite > 0, totalBytesExpectedToWrite != file.bytes {
            // 服务器发的和清单不是同一份（最常见是仓库里那个文件被换过）。别把它装进目录。
            settle(
                .failure(
                    ModelDownloadError.unexpectedSize(
                        file: file.fileName,
                        got: totalBytesExpectedToWrite,
                        want: file.bytes
                    )
                )
            )
            downloadTask.cancel()
            return
        }
        report(.receiving, totalBytesWritten)
    }

    /// 收完了：先认状态码，再整读一遍核对 sha256，对得上才装进目录。
    ///
    /// 状态码只能在这里读——下载任务不会走 `dataTask:didReceive response:` 那一条（实测
    /// 一个回调都没来），所以非 200（仓库改名、CDN 限流）到手的是那一段错误正文，
    /// 只能落进临时文件之后再判；sha256 是同一道闸的第二把锁。
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let http = downloadTask.response as? HTTPURLResponse
        guard http?.statusCode == 200 else {
            settle(.failure(ModelDownloadError.httpStatus(
                code: http?.statusCode ?? -1,
                url: http?.url?.absoluteString ?? "?"
            )))
            return
        }
        do {
            let digest = try sha256Hex(of: location)
            guard digest == file.sha256 else {
                throw ModelDownloadError.checksumMismatch(file: file.fileName, got: digest)
            }
            try install(from: location)
            settle(.success(()))
        } catch {
            settle(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else {
            // 任务正常结束却没给过落盘回调：这一条不报就是永久挂住（continuation 没人
            // resume，UI 钉在 0% 且不报错）。成功路径上 `settled` 已经为真，这里会被吞掉。
            settle(.failure(ModelDownloadError.network(
                file: file.fileName,
                reason: "会话结束但没有文件落盘"
            )))
            return
        }
        let ns = error as NSError
        // 只认 URLSession 自己的 -999：别的域里同一个小码是「用户取消」那类，不是这件事。
        if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorCancelled {
            settle(.failure(ModelDownloadError.cancelled))
        } else {
            settle(.failure(ModelDownloadError.network(file: file.fileName, reason: error.localizedDescription)))
        }
    }

    // MARK: - 校验与安装

    private func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        var read: Int64 = 0
        while let chunk = try handle.read(upToCount: reportInterval), !chunk.isEmpty {
            hasher.update(data: chunk)
            read += Int64(chunk.count)
            report(.verifying, read)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func install(from temp: URL) throws {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            // 覆盖上一次的同名文件：清单认定这一格就该是这份内容。
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fm.moveItem(at: temp, to: dest)
        } catch {
            throw ModelDownloadError.installation(file: file.fileName, reason: error.localizedDescription)
        }
    }

    private func report(_ phase: ModelDownloadPhase, _ done: Int64) {
        let previous = lastReported[phase] ?? -1
        // 收满/读完那一步无条件报一次，进度条才不会被四舍五入卡在 99%。
        guard done == file.bytes || done - previous >= Int64(reportInterval) else { return }
        lastReported[phase] = done
        onEvent(phase, done)
    }

    private func settle(_ result: Result<Void, Error>) {
        guard !settled else { return }
        settled = true
        continuation?.resume(with: result)
        continuation = nil
    }
}
