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
            .navigationTitle("我的小说")
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
                        }
                    }
                }
            } message: {
                Text(
                    "删除《\(clearCacheTarget?.title ?? "")》已合成的音频与句子标注，正文与书单保留，重新打开章节会按新流程重新生成。请在没有播放时操作。"
                )
            }
            .task {
                await loadBooks()
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
        ScrollView {
            LazyVStack(spacing: 16) {

                ForEach(books) { book in

                    NavigationLink {
                        BookDetailView(book: book)
                    } label: {

                        // 长按清理：重新生成音频前必须先清掉旧的错样本，
                        // 否则 produce 的磁盘命中会把它原样播出来。
                        #if DEBUG
                        BookCard(book: book)
                            .contextMenu {
                                Button {
                                    clearCacheTarget = book
                                } label: {
                                    Label(
                                        "清空音频与标注",
                                        systemImage: "arrow.counterclockwise"
                                    )
                                }
                            }
                        #else
                        BookCard(book: book)
                        #endif
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 100)
        }
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
    private static func copyToSandbox(
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
