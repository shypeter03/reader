//
//  SettingsView.swift
//  Reader
//
//  Created by 粟海洋 on 2026/8/26.
//

import SwiftUI
import UIKit
import SherpaKokoroKit

struct SettingsView: View {

    @AppStorage(
        "speechRate"
    )
    private var speechRate: Double = 1.0

    @AppStorage(
        "fontSize"
    )
    private var fontSize: Double = 1.0

    @AppStorage(
        "autoNextChapter"
    )
    private var autoNextChapter = true

    @AppStorage(
        "emotionEnhancement"
    )
    private var emotionEnhancement = true

    /// 和阅读页底部那颗喇叭是同一个键（`PlayerManager.speechEnabledKey`）：
    /// 两处写同一个值，拨哪一边另一边跟着变。写要走 `setSpeechEnabled`，
    /// 它顺手把正在放的声音停掉——只改值会出现「关了还在读」。
    @AppStorage(
        PlayerManager.speechEnabledKey
    )
    private var speechEnabled = true

    @AppStorage(
        "autoScroll"
    )
    private var autoScroll = true

    /// 键必须与 `TTSEngineType.storageKey` 一致（@AppStorage 只接受字面量）。
    @AppStorage(
        "ttsEngineType"
    )
    private var ttsEngineRaw: String = TTSEngineType.edge.rawValue

    /// 键必须与 `ReaderPipeline.continueTTSInBackgroundKey` 一致（@AppStorage 只接受字面量）。
    /// 只有朗读一条：文本解析用的是本地 Qwen3（MLX），在后台提交 GPU 会让进程直接被
    /// 系统终止，那是崩溃不是偏好，所以没有开关。
    @AppStorage(
        "continueTTSInBackground"
    )
    private var continueTTSInBackground = true

    @State private var cacheBytes: Int64?

    @State private var showClearCache = false

    /// 删除日志的确认框。日志是排查别的现场时唯一的东西，删错了没法补，所以问一句。
    @State private var showClearLog = false

    /// 日志体积。启动时量一次，导出之后再量：写日志的是后台那条队列，
    /// 主线程不能为这个数字去等它。
    @State private var logBytes: Int64 = 0

    /// 刚导出成功的那一份：present 出去就是分享面板。
    @State private var logExport: LogExport?

    @State private var logMissing = false

    /// 书单（清理要逐本走 pipeline）+ 手动刷新统计的触发器
    @State private var books: [Book] = []

    @State private var reloadToken = 0

    private let pipeline = ReaderContainer.shared.pipeline

    private let bookStore = BookStore.shared

    var body: some View {

        NavigationStack {

            Form {

                speechSection

                readingSection

                dataSection

                aboutSection
            }
            .navigationTitle("设置")
        }
    }
}

private extension SettingsView {

    /// 朗读 + 后台合成合成这一节：「后台继续朗读」本来就只管朗读那条队列，
    /// 单独立一节会让人以为它还管着别的（文本解析在后台是硬暂停，没有开关）。
    var speechSection: some View {

        Section("朗读") {

            Toggle(
                isOn: Binding(
                    get: { speechEnabled },
                    set: { PlayerManager.setSpeechEnabled($0) }
                )
            ) {
                Label(
                    "语音播报",
                    systemImage:
                        "speaker.wave.2"
                )
            }

            Text(
                speechEnabled
                    ? "关掉后点正文那一句不再朗读，正文里也不再有正在读的那一行；语音合成与整书解析一起停下，Qwen3 与各家的 TTS 权重当场卸掉。"
                    : "已关闭：点正文只翻页，不朗读。合成与解析都已挂起、模型已卸载（省电、腾出那 1~2GB 内存），排到一半的活儿留着，开回来接着跑。"
            )
            .font(.footnote)
            .foregroundStyle(.secondary)

            // 关掉喇叭之后这些全都无从生效：速度、续章、情绪、后端、后台续读，
            // 每一项都要有声音才有意义。留着只会让人以为关了还能调出别的表现，
            // 而「后台继续朗读」在这种状态下更是个纯摆设——后台根本没东西可续。
            if speechEnabled {

                HStack {

                    Label(
                        "朗读速度",
                        systemImage:
                            "speedometer"
                    )

                    Spacer()

                    Text(
                        String(
                            format: "%.1fx",
                            speechRate
                        )
                    )
                    .foregroundStyle(.secondary)
                }

                Slider(
                    value: $speechRate,
                    in: 0.5...2.0,
                    step: 0.1
                )

                Toggle(
                    "自动播放下一章",
                    isOn:
                        $autoNextChapter
                )

                Toggle(
                    "增强情绪表现",
                    isOn:
                        $emotionEnhancement
                )

                Picker(
                    "语音合成后端",
                    selection: $ttsEngineRaw
                ) {
                    ForEach(
                        TTSEngineType.allCases,
                        id: \.rawValue
                    ) { engine in
                        Text(
                            engine.displayName
                        )
                        .tag(engine.rawValue)
                    }
                }

                Text(
                    backendStatusText
                )
                .font(.footnote)
                .foregroundStyle(.secondary)

                Toggle(
                    isOn: $continueTTSInBackground
                ) {
                    Label(
                        "后台继续朗读",
                        systemImage:
                            "waveform"
                    )
                }

                Text(
                    continueTTSInBackground
                        ? "切到后台继续按需合成新句子，熄屏也不断。选的是本地 GPU 后端（Qwen3）时，后台会自己退到 Edge / Kokoro 那一格接着合成——同一个人换了后端音色会变，但不会停。整书解析用的是本地模型，切到后台一律暂停（iOS 不允许后台用 GPU），回前台自己接着排。"
                        : "已关闭：切到后台不再合成新句子，已经合成的照常放完——听到哪儿就停在哪儿，回前台接着合成。"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
    }

    /// 只在选了 Kokoro 时才提示模型是否就位；默认后端不打扰。
    private var backendStatusText: String {
        var text = "切换后端立刻生效，不用重启：选中的排第一，它连续失败 "
            + "\(FallbackTTSService.failureThreshold) 句就自动退到下一个（默认 Edge → Kokoro → Qwen3）。"

        if ttsEngineRaw == TTSEngineType.edge.rawValue {
            text += "Edge TTS 需要联网。"
        }

        // 权重没就位的后端在降级链里是空的一格，说出来才不用人去猜「为什么这句没有退路」。
        if SherpaKokoroTTSService.modelDirectoryIfAvailable() == nil {
            text += " 未找到 Kokoro 模型：权重应由 folder reference 在 build 时拷进 App，"
                + "或把 \(KokoroModelLocator.preferredDirectoryName) 放到 \(KokoroModelLocator.externalDirectoryNameHint) 后重启。"
        }
        if ttsEngineRaw == TTSEngineType.qwen3.rawValue, !Qwen3TTSService.modelAvailable() {
            text += " 未找到 Qwen3-TTS 权重，这一档暂时出不了声。"
        }
        return text
    }
}

private extension SettingsView {

    var readingSection: some View {

        Section("阅读") {

            HStack {

                Label(
                    "字体大小",
                    systemImage:
                        "textformat.size"
                )

                Spacer()

                Text(
                    "\(Int(fontSize * 100))%"
                )
                .foregroundStyle(.secondary)
            }

            Slider(
                value: $fontSize,
                in: 0.8...1.5,
                step: 0.05
            )

            Toggle(
                "自动跟随朗读",
                isOn:
                    $autoScroll
            )
        }
    }
}

private extension SettingsView {

    var dataSection: some View {

        Section {

            HStack {

                Label(
                    "生成缓存",
                    systemImage:
                        "internaldrive"
                )

                Spacer()

                Text(
                    cacheBytes == nil
                        ? "统计中…"
                        : ReaderCache.format(cacheBytes ?? 0)
                )
                .foregroundStyle(
                    .secondary
                )
                .monospacedDigit()
            }

            Text(
                "合成音频与 AI 标注都在这里。删了不影响书单和正文，重新打开章节会按当前流程重做。"
            )
            .font(.footnote)
            .foregroundStyle(.secondary)

            Button(
                role: .destructive
            ) {

                showClearCache = true

            } label: {

                Label(
                    "清除生成缓存",
                    systemImage:
                        "trash"
                )
            }

            HStack {

                Label(
                    "日志",
                    systemImage:
                        "doc.text"
                )

                Spacer()

                Text(
                    ReaderCache.format(logBytes)
                )
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }

            Text(
                "排查用的现场日志都在这一份里（`[Open]`、`[Gate]`、`[SLA]` 那一行行的标记）。"
                    + "真机不接 Xcode 也能导，发给别人就能看现场。攒到上限就自己转档、只留最近两段（每段 "
                    + ReaderCache.format(AppLog.limitBytes) + "），不会一路吃掉磁盘。"
            )
            .font(.footnote)
            .foregroundStyle(.secondary)

            Button(
                action: exportLog
            ) {

                Label(
                    "导出日志文件",
                    systemImage:
                        "square.and.arrow.up"
                )
            }

            Button(
                role: .destructive
            ) {

                showClearLog = true

            } label: {

                Label(
                    "删除日志文件",
                    systemImage:
                        "trash.slash"
                )
            }
        } header: {
            Text("数据")
        }
        .alert(
            "清除生成缓存",
            isPresented: $showClearCache
        ) {
            Button("取消", role: .cancel) {}
            Button("清除", role: .destructive) {
                clearCache()
            }
        } message: {
            Text("每本书的音频与句子标注都会被删除，正在播放时请先暂停。清除后重新打开章节会重新生成。")
        }
        .alert(
            "还没有日志",
            isPresented: $logMissing
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text("这一份文件是空的：先打开一本书读一会儿，再回来导出。")
        }
        .alert(
            "删除日志文件",
            isPresented: $showClearLog
        ) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                clearLog()
            }
        } message: {
            Text("两段现场日志一起删掉，接下去写的从空档开始。要发给别人看的话先导出这一份。")
        }
        // 分享面板吃的是临时目录里那份快照，不是活动日志本身（见 `AppLog.snapshotURL`）。
        .sheet(
            item: $logExport
        ) { file in
            ShareSheet(items: [file.url])
        }
        .task(id: reloadToken) {
            // 清理要逐本走 pipeline，所以书单得先拿到
            books = await bookStore.getAll()
            cacheBytes = await measureCache()
            logBytes = AppLog.size()
        }
    }

    /// 统计要遍历两棵目录树，几千个文件，别放在主线程的 body 里算。
    func measureCache() async -> Int64 {
        await Task.detached(priority: .utility) {
            ReaderCache.totalSize()
        }.value
    }

    /// 逐本走 pipeline 的清理：除了删文件，还要把调度表里这本书的任务丢掉，
    /// 否则会留着一批「已完成」的记录，重新打开时不再排产。
    func clearCache() {

        let books = self.books
        let pipeline = self.pipeline

        Task {

            for book in books {
                await pipeline.clearMediaCache(bookID: book.id)
                // 正文跟着清理一起删了：重新排队后台解析，点开章节才不用现算
                await pipeline.submitImport(book)
            }

            cacheBytes = await measureCache()
        }
    }

    /// 导出日志。合并那一步在后台：两段最多 4 MB，读出来再拼一次，按在主线程上
    /// 就是让分享面板慢半拍才出来。
    func exportLog() {

        Task {

            let url = await Task.detached(priority: .userInitiated) {
                AppLog.snapshotURL()
            }.value

            logBytes = AppLog.size()

            if let url {
                logExport = LogExport(url: url)
            } else {
                logMissing = true
            }
        }
    }

    /// 删除日志。等的是 `AppLog.clear()`：它在自己的写队列上先把待写的那些行落地再动手，
    /// 主线程直接按下去就得替那条队列等一次（那条上随时压着几百行）。
    func clearLog() {

        Task {

            await Task.detached(priority: .userInitiated) {
                AppLog.clear()
            }.value

            logBytes = AppLog.size()
        }
    }
}

private extension SettingsView {

    var aboutSection: some View {

        Section("关于") {

            HStack {

                Text("AI Reader")

                Spacer()

                Text("1.0.0")
                    .foregroundStyle(
                        .secondary
                    )
            }

            HStack {

                Text("AI 朗读引擎")

                Spacer()

                Text("未配置")
                    .foregroundStyle(
                        .secondary
                    )
            }
        }
    }
}

/// 刚导出的那一份日志快照。`Identifiable` 是给 `.sheet(item:)` 用的：
/// 分享面板要一个「有就是开、没了就是关」的值，而不是一个布尔。
private struct LogExport: Identifiable {

    let url: URL

    var id: URL { url }
}

/// 系统分享面板。
///
/// 只喂一个文件 URL：AirDrop、「存储到文件」、邮件都认它，收到的就是那一份 `.txt`。
private struct ShareSheet: UIViewControllerRepresentable {

    let items: [Any]

    func makeUIViewController(
        context: Context
    ) -> UIActivityViewController {

        let controller = UIActivityViewController(
            activityItems: items,
            applicationActivities: nil
        )

        // iPad 上系统默认把它按 popover 弹，没有锚点就是崩；这里给一个确定的呈现方式。
        controller.modalPresentationStyle = .pageSheet

        return controller
    }

    func updateUIViewController(
        _ controller: UIActivityViewController,
        context: Context
    ) {}
}
