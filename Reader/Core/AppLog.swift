//
//  AppLog.swift
//  Reader
//
//  能导出的日志。
//
//  口径：这个文件里的顶层 `print` 顶掉了标准库那一个（同 module 的声明优先于隐式
//  import 的标准库），所以现有那一百多处 `print("[Gate] …")` 一行都不必改，输出照旧进
//  Xcode 控制台，另外多落一份带时间戳的文件。真机不带 Xcode 跑的时候控制台根本没处看，
//  「设置 → 导出日志文件」给的就是那一份。
//
//  两类东西接不住，说清楚免得以后拿它当全量证据：
//  - 别的 module：`SherpaKokoroKit` 这类 package 里的 `print` 走的还是标准库，收不到；
//    C/C++ 直接写 fd 1 的输出（MLX、sherpa 的 native 日志）同理——要收它们得把 stdout 的
//    文件描述符换成管道，而管道满了 `print` 会阻塞调用线程，等于在排产的后台线程上
//    埋一个卡死点，不值；
//  - 崩溃栈。那是系统写的 `.ips`，在 设置 → 隐私与安全 → 分析与改进 里。
//
//  无头验证在 `.probe/log-export-probe.swift`（跑法 `UDID=<模拟器> .probe/run-log-export-probe.sh`）：
//  影子与标准库逐字一致、行序 FIFO、八线程并发不粘连、2 MB 转段、导出的那份三段齐、
//  跨启动续写。
//

import Foundation

enum AppLog {

    /// 单个文件的上限。逐句的 `[SLA]` 一分钟能写几十条，不设上限就是在用户的磁盘上
    /// 一路攒下去；只留最近两份，最坏 4 MB，导出时拼一起。
    static let limitBytes: Int64 = 2 * 1_024 * 1_024

    private static let directory: URL = {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        let url = base
            .appendingPathComponent("AIReader", isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private static let currentURL = directory.appendingPathComponent("current.log")
    private static let previousURL = directory.appendingPathComponent("previous.log")

    /// 串行队列。写日志的调用点横跨主线程、音频回调和排产的后台任务，用队列而不是锁：
    /// 落盘本来就该离开主线程，而且行的先后得和 `print` 的先后一致，不然
    /// `[SLA] T4 音频就绪` 会排在 `T2 分析就绪` 前面，那份日志就没法读了。
    private static let queue = DispatchQueue(
        label: "myself.Reader.AppLog",
        qos: .utility
    )

    // 下面三个只在 `queue` 上碰。`DateFormatter` 不是线程安全的，所以它也只在这条队列上用。
    private static var handle: FileHandle?
    private static var segmentWritten: Int64 = 0
    private static var didOpen = false

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    private static let fileStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return formatter
    }()

    // MARK: - 写

    static func record(_ message: String) {
        queue.async {
            openIfNeeded()

            let data = Data("\(stamp.string(from: Date())) \(message)\n".utf8)

            if segmentWritten + Int64(data.count) > limitBytes {
                rotate()
            }

            handle?.write(data)
            segmentWritten += Int64(data.count)
        }
    }

    /// 第一次写才开文件：启动路径上一个 `print` 都没有的话，不该顺手建目录、写横幅。
    private static func openIfNeeded() {
        guard !didOpen else { return }
        didOpen = true

        ensureFile(currentURL)
        handle = FileHandle(forWritingAtPath: currentURL.path)

        // 计数从文件真实长度起：上次进程留下的那一段还在，接着攒满才转。
        // 按 0 起算等于每次启动都以为自己是个空文件，上限就成了无限。
        segmentWritten = fileSize(of: currentURL)

        _ = handle?.seek(toFileOffset: UInt64(segmentWritten))

        writeRaw(
            "=== 启动 \(stamp.string(from: Date())) · \(appIdentity()) ===\n"
        )
    }

    private static func rotate() {
        try? handle?.close()
        try? FileManager.default.removeItem(at: previousURL)
        try? FileManager.default.moveItem(at: currentURL, to: previousURL)

        ensureFile(currentURL)
        handle = FileHandle(forWritingAtPath: currentURL.path)
        segmentWritten = 0

        // 转档这件事本身要在文件里留一行：导出时两段是拼在一起的，没有边界就成了
        // 「中间莫名少了点什么」。
        writeRaw(
            "=== \(stamp.string(from: Date())) 上一段满 "
                + "\(ReaderCache.format(limitBytes))，整段转到了本文件开头 ===\n"
        )
    }

    private static func writeRaw(_ text: String) {
        handle?.write(Data(text.utf8))
        segmentWritten += Int64(text.utf8.count)
    }

    private static func ensureFile(_ url: URL) {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        FileManager.default.createFile(atPath: url.path, contents: nil)
    }

    /// 文件大小。刻意不走 `url.resourceValues(forKeys: [.fileSizeKey])`：同一个 `URL`
    /// 实例会把第一次读到的值缓存下来（实测：文件从 100 字节写到 5100，再删掉重建成
    /// 5 字节，那个实例一路都报 100），而上面的路径全是 `static let`，缓存能活到进程结束。
    /// 受害者有两个：设置页那个数字成了死的；更要紧的是开档时拿它当 `segmentWritten`
    /// 的起点，一旦缓存先给了 0，这一段就以为自己空着，上限直接成了无限。
    private static func fileSize(of url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    // MARK: - 导出

    /// 合并出一份快照交给分享面板，返回那一份的路径；一行都还没写过就是 nil。
    ///
    /// 给出去的是临时目录里的副本，不是活动文件本身：面板在那头读的时候这头还在往里写，
    /// 分开才不会给出半行。
    static func snapshotURL() -> URL? {

        // 排在前面那些异步写入先落地，不然导出的那份缺最后几行。
        queue.sync {}

        guard didOpen else { return nil }

        var text = """
        AIReader 日志 · 导出于 \(stamp.string(from: Date()))
        版本 \(appIdentity())
        沙盒 \(directory.path)
        卷内可用 \(freeCapacity())｜日志 \(ReaderCache.format(size()))（每段上限 \(ReaderCache.format(limitBytes))，只留最近两段）

        """

        for url in [previousURL, currentURL] {
            if let body = try? String(contentsOf: url, encoding: .utf8) {
                text += body
            }
        }

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AIReader日志-\(fileStamp.string(from: Date())).txt"
            )

        guard let data = text.data(using: .utf8) else { return nil }

        try? FileManager.default.removeItem(at: out)

        do {
            try data.write(to: out, options: .atomic)
            return out
        } catch {
            record("[Log] 导出快照失败：\(error.localizedDescription)")
            return nil
        }
    }

    /// 日志体积（两段之和），设置页那一行显示用。
    static func size() -> Int64 {
        fileSize(of: previousURL) + fileSize(of: currentURL)
    }

    /// 删掉那两份文件，只留一份空档接着写。书单、正文、生成缓存都不沾。
    ///
    /// 走 `queue.sync`：删的是活动句柄背后那个文件。先把排在前面那些 `async` 的写入
    /// 排空再关句柄——否则晚到的那条会继续往已经 unlink 的旧 inode 里写，设置页看着
    /// 是 0，磁盘上还藏着一截没人认领、也导不出来的数据。
    static func clear() {

        queue.sync {

            // 先把文件与句柄备齐：下面删完要立刻拿到一个新句柄，不能让随后的
            // `record` 撞上 `handle == nil` 再走一遍开档（那会又插一条启动横幅）。
            openIfNeeded()

            try? handle?.close()
            try? FileManager.default.removeItem(at: previousURL)
            try? FileManager.default.removeItem(at: currentURL)

            ensureFile(currentURL)
            handle = FileHandle(forWritingAtPath: currentURL.path)
            segmentWritten = 0

            // 「清过」这件事在文件里留一行：下一份导出没有中断点的话，读的人会把它
            // 当成「这一程就是刚启动」，而前面其实是被删掉的一大段现场。
            writeRaw("=== \(stamp.string(from: Date())) 日志已手动清空 ===\n")
        }
    }

    /// 卷内可用空间。和 `fileSize(of:)` 同一个理由不走 `resourceValues`：`directory`
    /// 是个 `static let`，第一次读到的数会被缓存下来，往后每次导出报的都是那一刻的余量。
    private static func freeCapacity() -> String {
        let free = (try? FileManager.default.attributesOfFileSystem(
            forPath: directory.path
        ))?[.systemFreeSize] as? NSNumber

        return free.map { ReaderCache.format($0.int64Value) } ?? "未知"
    }

    private static func appIdentity() -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version)(\(build)) · iOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion) · \(machineName)"
    }

    /// 机型标识（`iPhone17,2` 这一种）。内存和 GPU 都按它分档，看日志的人最先要问的就是它。
    private static var machineName: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(
                bytes: raw.prefix(while: { $0 != 0 }),
                encoding: .utf8
            ) ?? "未知机型"
        }
    }
}

/// 顶掉标准库的 `print`。签名和标准库保持一致，所以调用点一条都不用改口径。
///
/// 一份输出两条路：控制台照旧（带 Xcode 跑还是要看得见），文件里那一行前面多个时间戳。
/// `terminator` 在这儿不起作用——一次调用就是文件里的一行，所以串里自带的换行会跟着
/// 落进去，只是续的那几行没有时间戳。
func print(
    _ items: Any...,
    separator: String = " ",
    terminator: String = "\n"
) {

    var line = ""

    for (index, item) in items.enumerated() {
        if index > 0 {
            line += separator
        }
        line += String(describing: item)
    }

    AppLog.record(line)

    fputs(line + terminator, stdout)
}
