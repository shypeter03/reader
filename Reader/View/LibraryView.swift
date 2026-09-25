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
        }
    }

    private func loadBooks() async {
        let loaded = await bookStore.getAll()
        await MainActor.run {
            books = loaded
        }
    }
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

                        NavigationLink {
                            BookDetailView(book: book)
                        } label: {

                            // 长按两件事：清生成物（重新录制前的必经一步——磁盘命中会让
                            // produce 把旧的错样本原样播出来）、删除整本书。
                            BookCoverTile(book: book)
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

        await Task.detached {
            try? FileManager.default.removeItem(at: rootURL)
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
