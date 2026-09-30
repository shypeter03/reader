//
//  LibraryView.swift
//  Reader
//
//  Created by 粟海洋 on 2026/8/26.
//

import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {

    @State private var books: [Book] = []

    @State private var showImporter = false

    @State private var isImporting = false

    @State private var importError: String?

    @State private var processingBookID: UUID?

    @State private var clearCacheTarget: Book?

    @State private var deleteTarget: Book?

    /// 打开哪本书由根视图那层负责：阅读页要盖住 tab 栏，动画只能由叠它的那一层驱动。
    @ObservedObject
    private var launcher = ReaderLauncher.shared

    private let bookStore = BookStore.shared

    private let pipeline = ReaderContainer.shared.pipeline

    var body: some View {
        NavigationStack {
            ZStack {

                Color(.systemBackground)
                    .ignoresSafeArea()

                if books.isEmpty {
                    emptyView
                } else {
                    bookList
                }

                if isImporting {
                    ProgressView("正在导入 EPUB…")
                        .padding(24)
                        .background(.regularMaterial)
                        .clipShape(
                            RoundedRectangle(
                                cornerRadius: 16
                            )
                        )
                }
            }
            .navigationTitle("书库")
            .toolbar {
                ToolbarItem(
                    placement: .topBarTrailing
                ) {
                    Button {
                        showImporter = true
                    } label: {
                        Image(systemName: "plus")
                            .font(
                                .system(
                                    size: 24,
                                    weight: .regular
                                )
                            )
                    }
                }
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.epub],
                allowsMultipleSelection: false
            ) { result in
                handleImport(result)
            }
            .alert(
                "导入失败",
                isPresented: Binding(
                    get: {
                        importError != nil
                    },
                    set: { value in
                        if !value {
                            importError = nil
                        }
                    }
                )
            ) {
                Button("确定") {
                    importError = nil
                }
            } message: {
                Text(
                    importError
                    ?? "未知错误"
                )
            }
            .alert(
                "清空音频与标注",
                isPresented: Binding(
                    get: {
                        clearCacheTarget != nil
                    },
                    set: { value in
                        if !value {
                            clearCacheTarget = nil
                        }
                    }
                )
            ) {
                Button("取消", role: .cancel) {
                    clearCacheTarget = nil
                }
                Button("清空", role: .destructive) {
                    if let book = clearCacheTarget {
                        clearCacheTarget = nil
                        Task {
                            await pipeline.clearMediaCache(bookID: book.id)
                            // 清理把落库的正文一起删了：重新走一遍导入的后台解析，
                            // 让点开章节仍然不用等 XML 解析。
                            await pipeline.submitImport(book)
                        }
                    }
                }
            } message: {
                Text(
                    "删除《\(clearCacheTarget?.title ?? "")》已合成的音频与句子标注，正文与书单保留，重新打开章节会按新流程重新生成。请在没有播放时操作。"
                )
            }
            .alert(
                "删除这本书",
                isPresented: Binding(
                    get: {
                        deleteTarget != nil
                    },
                    set: { value in
                        if !value {
                            deleteTarget = nil
                        }
                    }
                )
            ) {
                Button("取消", role: .cancel) {
                    deleteTarget = nil
                }
                Button("删除", role: .destructive) {
                    if let book = deleteTarget {
                        deleteTarget = nil
                        Task {
                            await deleteBook(book)
                        }
                    }
                }
            } message: {
                Text(
                    "将删除《\(deleteTarget?.title ?? "")》的正文、封面与全部生成缓存。删除后需要重新导入 EPUB。"
                )
            }
            .onAppear {
                // 从阅读页退回来时重读一次书单，阅读进度才是最新的
                Task {
                    await loadBooks()
                }
            }
            .onChange(
                of: launcher.opened?.id
            ) { _, next in
                // 阅读页现在是盖在书库上面的一层，书库从头到尾没离开过屏幕，
                // onAppear 不会再跑一次；不补这一下，封面卡上的进度就还停在
                // 进阅读页之前那份快照。
                if next == nil {
                    Task {
                        await loadBooks()
                    }
                }
            }
        }
    }

    private func loadBooks() async {
        let loaded = await bookStore.getAll()
        await MainActor.run {
            books = loaded

            // 开屏那本合上的书等的就是这一下。
            LaunchGate.shared.markBooksLoaded()
        }
    }
}

/// 书库 → 阅读视角的一次跳转。
struct ReaderRoute: Identifiable {

    let id = UUID()

    let book: Book

    let chapterIndex: Int
}

/// 谁在书库里点了哪本书。
///
/// 状态挂在根视图而不是 LibraryView：`fullScreenCover` 的转场系统写死是硬切，
/// 想要「封面摊开成整页」就得自己叠一层，而只有自己叠的这层能同时盖住 tab 栏
/// 并让进出两个方向都吃到同一个动画。
///
/// 只有用户点书卡才会置上 `opened`——书库自己从不主动开阅读页，冷启动只列表。
///
/// `@MainActor`：它要读 `PlayerManager` 的现场（哪本书、哪一章），那个是主线程的。
@MainActor
final class ReaderLauncher: ObservableObject {

    static let shared = ReaderLauncher()

    @Published var opened: ReaderRoute?

    /// 整页摊开到哪一步：1 = 铺满屏幕，0 = 正好落在封面卡上。
    ///
    /// 打开、关闭、以及阅读页里那一下下拉都写这一个值。分开写的话就会出现
    /// 「拖到一半松手，动画又从全屏开始重放」——转场只认一把尺子。
    @Published var presentation: Double = 0

    private init() {}

    /// 点书卡：空书什么都不做，其余一律进正文。
    func open(_ book: Book) {

        guard !book.chapters.isEmpty else { return }

        // 记下这张卡现在在哪：退出阅读页时整页要缩回它上面。
        sourceFrame = frames[book.id]

        // 「返回有没有动画」只有真机说得上话，这里先把口径记下来：落点拿到了没有。
        // 拿不到落点时 CoverMatch 退回 0.86 倍等比缩放——那点位移小到和没动一样，
        // 现场看起来就是「硬切」，所以这一条必须先排除掉。
        print("[Turn] 打开 「\(book.title.prefix(12))」 落点="
            + (sourceFrame.map { "w\(Int($0.width)) 中心(\(Int($0.midX)),\(Int($0.midY)))" }
                ?? "nil ← 封面卡的位置没记上，退场会退化成等比缩放"))

        let player = PlayerManager.shared

        // 音频还活在这本书上（退回书库并没有停播）：进哪一章跟着播放器走。
        // 书单里那份进度是离开那一刻写的，声音后来又往前跑了几个字，
        // 拿它当落点就是「退出再进来，刚听的那句没了」。
        let target = player.currentBook?.id == book.id
            ? player.currentChapterIndex
            : book.lastReadChapter

        opened = ReaderRoute(
            book: book,
            chapterIndex: min(
                max(target, 0),
                book.chapters.count - 1
            )
        )

        presentation = 0

        withAnimation(
            .smooth(duration: Self.openDuration, extraBounce: 0.04)
        ) {
            presentation = 1
        }
    }

    func close(
        duration: TimeInterval = ReaderLauncher.closeDuration
    ) {

        guard let route = opened else { return }

        let from = presentation
        let started = Date()

        // 判据是「这一趟到底跑没跑动画」：动画只要注册上了，落地就要等满 duration，
        // 墙上时间就会 ≈ duration。远小于它 = 值根本没被插值 = 当场硬切，
        // 和「用户说没动画」是同一件事。
        print("[Turn] 返回 「\(route.book.title.prefix(12))」 presentation "
            + "\(String(format: "%.2f", from))→0，动画 \(duration)s")

        withAnimation(
            .easeOut(duration: duration),
            completionCriteria: .logicallyComplete
        ) {
            presentation = 0
        } completion: {
            let took = Date().timeIntervalSince(started)
            print("[Turn] 返回落位 用了 \(String(format: "%.0f", took * 1000))ms"
                + (took < duration * 0.4
                    ? " ← 动画没注册上：这就是硬切"
                    : "（跑满了，说明值在插，问题在渲染侧）"))
            // 落位跑完才拆视图：早一步拆就是硬切，缩回封面那一下白做。
            // 认一下还是不是同一次跳转——这 0.46s 里用户又点了别的书，
            // 无条件清掉会把刚打开的那本一起清没。
            if self.opened?.id == route.id {
                self.opened = nil
            }
        }
    }

    /// 阅读页里往下拖：0 = 原位，1 = 已经按到封面卡上。拖动过程中逐帧调用，不加动画。
    func pull(
        _ progress: Double
    ) {

        guard opened != nil else { return }

        presentation = min(1, max(0, 1 - progress))
    }

    /// 松手：要么继续缩到卡上关掉，要么弹回全屏。
    func releasePull(
        commit: Bool
    ) {

        if commit {
            close(duration: 0.26)
        } else {
            withAnimation(
                .spring(response: 0.34, dampingFraction: 0.9)
            ) {
                presentation = 1
            }
        }
    }

    /// 每张封面卡在全屏坐标里的位置，滚动时一直在更新。
    ///
    /// 故意不 @Published：它只是退场那一瞬要读的一个值，跟着它重画会让整个网格
    /// 每帧都失效。
    var frames: [UUID: CGRect] = [:]

    private(set) var sourceFrame: CGRect?

    /// 这两个数出现在参数默认值里，而默认值表达式不在主线程上下文中，所以要 nonisolated。
    nonisolated private static let openDuration: TimeInterval = 0.46

    nonisolated static let closeDuration: TimeInterval = 0.46
}

// MARK: - Views

private extension LibraryView {

    var emptyView: some View {
        VStack(spacing: 20) {

            Image(systemName: "books.vertical")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {

                Text("还没有小说")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("点击右上角 + 导入 EPUB 小说")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Button {
                showImporter = true
            } label: {
                Label(
                    "导入小说",
                    systemImage: "plus"
                )
                .font(.headline)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity
        )
    }

    var bookList: some View {

        // 列数按窗口宽度定，间距按列宽取比例。
        // 固定像素的间距在宽屏上会让封面挨在一起。
        GeometryReader { proxy in

            let metrics = Self.gridMetrics(for: proxy.size.width)

            ScrollView {
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(
                            .flexible(),
                            spacing: metrics.gutter
                        ),
                        count: metrics.columnCount
                    ),
                    alignment: .leading,
                    spacing: metrics.rowGap
                ) {

                    ForEach(books) { book in

                        // 点书 = 直接进正文（图书 App 的读法），落在上次读到的那一章。
                        Button {
                            launcher.open(book)
                        } label: {

                            // 长按两件事：清生成物（重新录制前的必经一步——磁盘命中会让
                            // produce 把旧的错样本原样播出来）、删除整本书。
                            BookCoverTile(book: book)
                                .onGeometryChange(
                                    for: CGRect.self
                                ) { proxy in
                                    proxy.frame(in: .global)
                                } action: { frame in
                                    launcher.frames[book.id] = frame
                                }
                                .contextMenu {
                                    Button {
                                        clearCacheTarget = book
                                    } label: {
                                        Label(
                                            "清空音频与标注",
                                            systemImage: "arrow.counterclockwise"
                                        )
                                    }

                                    Button(
                                        role: .destructive
                                    ) {
                                        deleteTarget = book
                                    } label: {
                                        Label(
                                            "删除这本书",
                                            systemImage: "trash"
                                        )
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, metrics.sidePadding)
                .padding(.top, metrics.rowGap)
                .padding(.bottom, 100)
            }
        }
    }
}

// MARK: - Grid metrics

private extension LibraryView {

    struct GridMetrics {
        let columnCount: Int
        let gutter: CGFloat
        let rowGap: CGFloat
        let sidePadding: CGFloat
    }

    /// 先定列数，再由「列间距 = 列宽 × 0.14、两侧留白 = 列间距 × 1.25」反解列宽：
    /// width = 2·side + n·t + (n-1)·gutter。这样换屏幕时封面和留白同步缩放，
    /// 而首张卡离屏幕边永远比离邻居更远，不会贴着边框。
    static func gridMetrics(for width: CGFloat) -> GridMetrics {

        let gutterRatio: CGFloat = 0.14
        let sideRatio = gutterRatio * 1.25

        let columnCount: Int
        switch width {
        case ..<520: columnCount = 2
        case ..<700: columnCount = 3
        case ..<900: columnCount = 4
        default: columnCount = 5
        }

        let tile = width / (
            CGFloat(columnCount)
            + CGFloat(columnCount - 1) * gutterRatio
            + sideRatio * 2
        )

        return GridMetrics(
            columnCount: columnCount,
            gutter: tile * gutterRatio,
            rowGap: tile * 0.22,
            sidePadding: tile * sideRatio
        )
    }
}

// MARK: - Deletion

private extension LibraryView {

    /// 删一本书要动三处：生成缓存（音频 + 解析）、解压出来的正文与封面、书单记录。
    /// 少了第一步的话调度表里会留着这本书「已完成」的任务记录，白占磁盘统计口径。
    @MainActor
    func deleteBook(_ book: Book) async {

        await pipeline.clearMediaCache(bookID: book.id)

        let rootURL = book.epubRootURL
        let cover = book.coverURL

        await Task.detached {
            try? FileManager.default.removeItem(at: rootURL)
            // 封面副本现在单独住在 `AIReader/covers/`，不在正文树里，删正文带不走它。
            // 判前缀而不是直接删：老书的封面路径还在 EPUB 树里，上面那一步已经删过了。
            if let cover, cover.path.hasPrefix(ReaderCache.coverRoot.path) {
                try? FileManager.default.removeItem(at: cover)
            }
        }.value

        await bookStore.delete(id: book.id)

        books.removeAll { $0.id == book.id }
    }
}

// MARK: - Import

private extension LibraryView {

    func handleImport(
        _ result: Result<[URL], Error>
    ) {

        switch result {

        case .success(let urls):

            guard let url = urls.first else {
                return
            }

            importEPUB(from: url)

        case .failure(let error):

            importError =
                error.localizedDescription
        }
    }

    func importEPUB(
        from url: URL
    ) {

        isImporting = true

        // fileImporter 返回的是安全作用域 URL，且文件可能仍在 iCloud
        // 未下载到本地。必须先申请权限并把文件强制拷进沙箱，
        // 否则 ZIPFoundation 直接读原始 URL 会报“no such file”。
        let didStartAccess =
            url.startAccessingSecurityScopedResource()

        Task.detached {

            defer {
                if didStartAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            do {

                let localURL =
                    try Self.copyToSandbox(from: url)

                defer {
                    try? FileManager.default.removeItem(
                        at: localURL
                    )
                }

                let epubBook =
                    try EPUBParser.importBook(
                        from: localURL
                    )

                let book =
                    epubBook.makeBook()

                await bookStore.add(book)

                // 小说落库即算导入完成；后续解析/分析只作为一条消息发给
                // 后台专用消费任务，submitImport 瞬间返回，UI 绝不等待。
                let pipeline = await MainActor.run {
                    ReaderContainer.shared.pipeline
                }
                await pipeline.submitImport(book)

                await MainActor.run {

                    books.append(book)

                    isImporting = false
                }

            } catch {

                await MainActor.run {

                    isImporting = false

                    importError =
                        error.localizedDescription
                }
            }
        }
    }

    /// 将（可能是 iCloud / 其他 App 提供的）文件读进内存再写入沙箱临时目录，
    /// 强制触发 iCloud 下载，得到可直接解压的本地文件。
    /// nonisolated：这是在 Task.detached 里跑的纯文件 IO，绑在主线程上只会
    /// 把大文件读取卡回 UI（Swift 6 下更是直接报错）。
    private nonisolated static func copyToSandbox(
        from url: URL
    ) throws -> URL {

        let data = try Data(contentsOf: url)

        let destination =
            FileManager.default
                .temporaryDirectory
                .appendingPathComponent(
                    UUID().uuidString + ".epub"
                )

        try data.write(to: destination)

        return destination
    }
}
