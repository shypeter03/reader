//
//  BookStore.swift
//  Reader
//
//  Created by 粟海洋 on 2026/9/21.
//

import Foundation

actor BookStore {

    static let shared = BookStore()

    private let booksFileURL: URL

    private var books: [Book] = []

    private var booksLoaded = false

    private init() {

        let base =
            FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0]

        let rootURL =
            base
            .appendingPathComponent(
                "AIReader",
                isDirectory: true
            )

        try? FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )

        booksFileURL =
            rootURL
            .appendingPathComponent(
                "books.json"
            )
    }

    // MARK: - Public API

    func getAll() -> [Book] {
        loadIfNeeded()
        return books
    }

    func add(_ book: Book) {
        loadIfNeeded()
        books.append(book)
        saveToDisk()
    }

    func update(_ book: Book) {
        loadIfNeeded()
        if let index = books.firstIndex(where: { $0.id == book.id }) {
            books[index] = book
            saveToDisk()
        }
    }

    func delete(id: UUID) {
        loadIfNeeded()
        books.removeAll { $0.id == id }
        saveToDisk()
    }

    /// 落一次阅读位置：章在 `chapters` 里的下标 + 章内句序。
    /// 每切一句都会调到这里，所以值没变就绝不写盘（整份书单会被重新编码一遍）。
    func setProgress(
        bookID: UUID,
        chapterIndex: Int,
        sentenceIndex: Int
    ) {
        loadIfNeeded()
        // 「上次在读哪本」单独记一个键：换了一本书但章/句数字恰好相同，
        // 下面那个「值没变就不写」会直接 return，续播就会回到旧的那本书上。
        UserDefaults.standard.set(bookID.uuidString, forKey: Self.lastReadBookKey)
        guard let index = books.firstIndex(where: { $0.id == bookID }) else {
            return
        }
        guard books[index].lastReadChapter != chapterIndex
            || books[index].lastReadSentence != sentenceIndex else {
            return
        }
        books[index].lastReadChapter = chapterIndex
        books[index].lastReadSentence = sentenceIndex
        saveToDisk()
    }

    /// 上次落过位置的那本书。没有标记（第一次用）或书已被删掉时返回 nil。
    func lastReadBook() -> Book? {
        loadIfNeeded()
        guard let raw = UserDefaults.standard.string(forKey: Self.lastReadBookKey),
              let id = UUID(uuidString: raw) else {
            return nil
        }
        return books.first { $0.id == id }
    }

    /// 记在 UserDefaults 而不是给 `Book` 加字段：书单是整份 JSON 编码的，
    /// 新增一个非可选字段会让现存 books.json 直接解码失败。
    private static let lastReadBookKey = "readerLastReadBookID"

    // MARK: - Persistence

    /// init 是 nonisolated 的，读盘必须延到首次 actor 隔离访问时做。
    private func loadIfNeeded() {
        guard !booksLoaded else { return }
        booksLoaded = true
        loadFromDisk()
    }

    private func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: booksFileURL.path) else {
            return
        }

        do {
            let data = try Data(contentsOf: booksFileURL)
            let decoded = try JSONDecoder().decode([Book].self, from: data)
            let root = storageRoot.path
            var relocated = 0
            var dropped = 0
            books = decoded.map { book in
                let fixed = Self.relocated(book, toRoot: root)
                // 比路径而不是比 URL：容器没换时这一步是恒等的，计数才不虚高
                if fixed.coverURL?.path != book.coverURL?.path
                    || fixed.epubRootURL.path != book.epubRootURL.path {
                    relocated += 1
                }
                let clean = Self.withoutCoverChapters(fixed)
                dropped += fixed.chapters.count - clean.chapters.count
                return clean
            }
            print("BookStore: 加载了 \(books.count) 本书"
                + (relocated > 0 ? "，其中 \(relocated) 本的路径接回了当前沙盒" : "")
                + (dropped > 0 ? "，拿掉 \(dropped) 条混进章节里的封面/扉页" : ""))
        } catch {
            print("BookStore: 加载失败 - \(error)")
            books = []
        }
    }

    // MARK: - 沙盒路径重接

    /// `AIReader/` 那一层。`books.json` 就放在它下面，所以去掉文件名就是它。
    private var storageRoot: URL {
        booksFileURL.deletingLastPathComponent()
    }

    private static let sandboxMarker = "/AIReader/"

    /// 把一本书里所有绝对路径接回当前沙盒。
    ///
    /// 书单记的是绝对路径（`coverURL`、`epubRootURL`、每章的 `fileURL`），而**重新部署**
    /// 会给 App 换一个新的容器 UUID：文件一个都没动，路径却整条前缀变了，于是全部读不到
    /// ——表现就是「装一次之后封面全没了」。容器没换时那是恒等变换，所以每次读盘
    /// 无条件做，不必先去判文件在不在。
    ///
    /// 之所以拆成静态函数、把根目录当参数传：单例只有一份、读的是设备沙盒，
    /// 探针在别处碰不到它，而这段逻辑要能喂真机形状的假路径验一遍。
    static func relocated(_ book: Book, toRoot root: String) -> Book {

        guard book.epubRootURL.path.contains(sandboxMarker)
            || book.coverURL?.path.contains(sandboxMarker) == true
        else {
            return book
        }

        return Book(
            id: book.id,
            title: book.title,
            author: book.author,
            coverURL: book.coverURL.map {
                URL(fileURLWithPath: rebasedPath($0.path, under: root))
            },
            epubRootURL: URL(
                fileURLWithPath: rebasedPath(book.epubRootURL.path, under: root)
            ),
            chapters: book.chapters.map {
                $0.replacingFileURL(
                    URL(fileURLWithPath: rebasedPath($0.fileURL.path, under: root))
                )
            },
            lastReadChapter: book.lastReadChapter,
            lastReadSentence: book.lastReadSentence
        )
    }

    /// 只认 `AIReader/` 以下那一截；不是这个形状的路径（外部文件、别的 App）原样交回。
    static func rebasedPath(_ path: String, under root: String) -> String {

        guard let range = path.range(of: sandboxMarker) else {
            return path
        }

        return root + "/" + path[range.upperBound...]
    }

    /// 把已经进了书单的封面/扉页拿掉。判据和新导入那条共用 `EPUBParser.isCoverPage`，
    /// 两边口径不会分家（这里没有 manifest 的 `properties` 可用，走的是名字那一条）。
    ///
    /// 为什么在读盘时补一遍，而不是只改导入：设备上这两本书已经带着封面进书单了，
    /// 而重新导入会换掉每一章的 `id`（随机 UUID）——那些章的解析结果和合成好的音频
    /// 全成孤儿，等于把几小时的活重做一遍。所以旧书要在打开的时候自己修好。
    static func withoutCoverChapters(_ book: Book) -> Book {

        let isCover = book.chapters.map {
            EPUBParser.isCoverPage(
                itemID: $0.itemID,
                fileURL: $0.fileURL,
                properties: nil
            )
        }

        let kept = book.chapters.enumerated()
            .filter { !isCover[$0.offset] }
            .map(\.element)

        // 一本不剩地全判成封面：留着，别把这本书变成空的。
        guard !kept.isEmpty, kept.count != book.chapters.count else {
            return book
        }

        // `index` 按新的第几章重排：页眉的「第N章」和目录里那列序号都读它。
        // 进度下标按「它前面被拿掉几条」往前挪，否则记着「第 6 条」而第 6 条已经不是当初那一章。
        let droppedBefore = isCover
            .prefix(min(book.lastReadChapter, isCover.count))
            .filter { $0 }
            .count

        return Book(
            id: book.id,
            title: book.title,
            author: book.author,
            coverURL: book.coverURL,
            epubRootURL: book.epubRootURL,
            chapters: kept.enumerated()
                .map { $0.element.replacingIndex($0.offset) },
            lastReadChapter: max(
                0,
                book.lastReadChapter - droppedBefore
            ),
            lastReadSentence: book.lastReadSentence
        )
    }

    private func saveToDisk() {
        do {
            let data = try JSONEncoder().encode(books)
            try data.write(to: booksFileURL)
            // 成功不打：读阅读进度时每 8 句就落一次盘，打出来只会淹掉日志
        } catch {
            print("BookStore: 保存失败 - \(error)")
        }
    }
}
