//
//  BookPagination.swift
//  Reader
//
//  按当前排版档把整本书量一遍：每一章几面纸、全书一共几面。
//
//  口径只有一条：页数一律问 `PageLayout.paginate`，和纸上同一把尺。别处不许再拿字数
//  折算一套——「全书第 N 页」和读者手上那一面必须对得上，两把尺就是一眼看得出的错。
//
//  成本（探针实测：`.probe/out/before/paginate-check.log`、`justify-probe.log:319`）：
//  单章 75 句 84ms、96 句 128ms、205 句（7020 字）196ms，另加取正文一次（落库的
//  `chapter.json` 204 句那种约 233KB，没落库的现读现切 EPUB）。四百章一趟一分多钟，
//  所以结果落盘复用，只有换排版档（纸宽×高、字号、行距）才重算——那一档换了本来
//  整本书的纸都要重排，重算是应付的账。
//
//  落点是缓存树（`ReaderCache`）：这份数随时能从正文重算出来，「清空音频与标注」把它
//  一起带走是对的，代价只是底部那一行重新量一趟。
//

import Foundation

/// 一本书按某一档排版分出来的页数。
struct BookPageMap: Codable, Equatable {

    /// 还没量到的那一格。
    static let unmeasured = -1

    /// 排版档，就是 `ReaderView.pageMetrics` 那一个串（纸宽×高|字号|行距|图的口径）。
    let metrics: String

    /// 每章几面纸，按 `Book.chapters` 的顺序。
    var counts: [Int]

    var isComplete: Bool { !counts.contains(Self.unmeasured) }

    /// 全书一共几面。没量完就没有这个数——底部宁可写「共 … 页」，
    /// 也不报一个「读着读着自己变大」的总数：那个数看着就是算错了。
    var total: Int? {
        guard isComplete, !counts.isEmpty else { return nil }
        return counts.reduce(0, +)
    }

    /// 第 `index` 章之前一共几面。前面只要有一格没量到就给不出准数，返回 nil。
    func pages(before index: Int) -> Int? {

        guard counts.indices.contains(index) else { return nil }

        let head = counts[0..<index]

        return head.contains(Self.unmeasured) ? nil : head.reduce(0, +)
    }
}

enum BookPagination {

    /// `ChapterStore` 只是 `chapter.json` 那棵树的名字空间，里面不存任何状态，
    /// 所以这一趟自己开一个实例，不为一个只读的路径往 `ReaderContainer` 上再挂一条出口。
    private static let chapterStore = ChapterStore()

    /// 已经落盘的那一份，排版档对得上、章数没变才算数。
    ///
    /// 只读一份 JSON，不做任何量算：给阅读页在开页那一拍先垫上「全书第 N 页」，
    /// 第二次以后打开同一本书不该先看到「量页中」。
    static func stored(
        bookID: UUID,
        metrics: String,
        chapters: Int
    ) -> BookPageMap? {
        held(bookID: bookID, metrics: metrics, chapters: chapters)
    }

    /// 量全书。
    ///
    /// 已量完的档直接交回落盘那份（零成本）；没量完接着往下量。
    /// 每量到一段就用 `onProgress` 把当前的图交出去（底部那一行的「第 N 页」要在
    /// 前面的章量完时立刻变准，不该等整本书），取消（换了排版档、退出阅读页）时
    /// 把量到的那一截先落盘——下次接着跑，前面那些章不用重量。
    ///
    /// `imagesOf` 由手上真有书单的那一侧给（`ReaderView` 里就是 `book.placedImages`）。
    /// 这一层不 import 书单、也不自己判装饰图：判据只许有一份（见 `Book.placedImages`），
    /// 而一张图进不进这一页是要**问高度**的——这里量的是面数，漏了图就比纸上少一面，
    /// 底部「第 N 页」和读者手上那一面对不上。默认交空表只留给探针那种没有图的路径。
    static func measure(
        bookID: UUID,
        metrics: String,
        descriptors: [ChapterDescriptor],
        area: CGSize,
        scale: Double,
        lineScale: Double,
        imagesOf: @escaping @Sendable (Chapter, ChapterDescriptor) -> [ChapterImage] = { _, _ in [] },
        onProgress: @escaping @Sendable (BookPageMap) -> Void
    ) async -> BookPageMap? {

        guard !descriptors.isEmpty else { return nil }

        var map = held(bookID: bookID, metrics: metrics, chapters: descriptors.count)
            ?? BookPageMap(
                metrics: metrics,
                counts: Array(
                    repeating: BookPageMap.unmeasured,
                    count: descriptors.count
                )
            )

        if let done = map.total {
            print("[Pages] book=\(bookID.uuidString.prefix(8)) 排版档 \(metrics) 已量完，全书 \(done) 面（复用落盘）")
            return map
        }

        let started = CFAbsoluteTimeGetCurrent()
        /// 取不到正文的那些章（章号 + 原因），跑完一次性打出来：底部那一行的数对不上时，
        /// 要知道是哪些章在这一趟里交了白卷。
        var unreadable: [String] = []

        for (index, descriptor) in descriptors.enumerated()
        where map.counts[index] == BookPageMap.unmeasured {

            if Task.isCancelled {
                save(map, bookID: bookID)
                await progress(map, onProgress)
                print("[Pages] book=\(bookID.uuidString.prefix(8)) 量到 \(index)/\(descriptors.count) 章被取消，已落盘接着跑")
                return nil
            }

            guard let chapter = await chapter(for: descriptor, bookID: bookID) else {
                // 正文读不到（⌘R 之后解压出来的 EPUB 不在容器里那一类，见 #29 取证）：
                // 这一格记 0，不是留洞。理由：这样的章在纸上也翻不出面——它给读者的页数
                // 就是 0，按 0 记才是同一把尺。留洞的代价更大：一个洞让「全书共 N 页」
                // 永远不成立，一本书哪怕只有一章取不到，底部就再也没有书籍口径。
                map.counts[index] = 0
                unreadable.append(
                    "\(index + 1)(\(descriptor.title.prefix(12)))"
                )
                continue
            }

            let sentences = chapter.sentences
            let title = chapter.title
            let images = imagesOf(chapter, descriptor)

            // 整章量高挪出主线程，和翻页预取同一条优先级：这一趟几百次，压在 UI 线程上
            // 就是「读一句卡一下」。
            map.counts[index] = await Task.detached(priority: .utility) {
                PageLayout.paginate(
                    sentences,
                    in: area,
                    scale: scale,
                    lineScale: lineScale,
                    chapterTitle: title,
                    images: images
                ).pageCount
            }.value

            // 每 8 章往外报一次：读者位置之前的那些章一量完，「第 N 页」就该是对的数，
            // 没道理再等后半本。落盘慢一档（24 章），那份 JSON 不值得每 8 章重写一次。
            if index % 8 == 0 {
                await progress(map, onProgress)
            }

            if index % 24 == 0 {
                save(map, bookID: bookID)
            }
        }

        save(map, bookID: bookID)
        await progress(map, onProgress)

        if !unreadable.isEmpty {
            print("[Pages] book=\(bookID.uuidString.prefix(8)) \(unreadable.count) 章取不到正文按 0 面计：\(unreadable.prefix(20).joined(separator: " "))")
        }

        guard let total = map.total else {
            print("[Pages] book=\(bookID.uuidString.prefix(8)) 量完仍不闭合（\(map.counts.filter { $0 == BookPageMap.unmeasured }.count) 格没量到）")
            return nil
        }

        print("[Pages] book=\(bookID.uuidString.prefix(8)) \(descriptors.count) 章共 \(total) 面（排版档 \(metrics)），耗时 \(String(format: "%.1f", CFAbsoluteTimeGetCurrent() - started))s")

        return map
    }

    /// 进度往外走一律回主线程：`bookPages` 是 `@State`。
    private static func progress(
        _ map: BookPageMap,
        _ onProgress: @escaping @Sendable (BookPageMap) -> Void
    ) async {
        await MainActor.run {
            onProgress(map)
        }
    }

    // MARK: - 取正文

    /// 这一章有什么字。口径抄 `ReaderPipeline.loadParsedChapter`：落库那份要断句版本
    /// 对得上才用，对不上或没落库就从 EPUB 现读现切。
    ///
    /// 为什么必须有 EPUB 这一条：**解析是按窗口补产的**（200 批 / 40 章），一本四百章的
    /// 书绝大多数章根本没有 `chapter.json`。只问落库的话，这一趟会在前三四十章量完、
    /// 剩下全是洞，「全书共 N 页」永远出不来——用户要的那个数就等于没做。
    /// 而分页只要「一句多长、是不是段首」，情绪和说话人一个都不需要，
    /// `EPUBParser.loadChapter` 一次同步读完切完就够（不过 LLM、不落库、不进 `ChapterCache`，
    /// 免得几百章把真正在读的章挤出缓存）。
    private static func chapter(
        for descriptor: ChapterDescriptor,
        bookID: UUID
    ) async -> Chapter? {

        if let saved = await chapterStore.load(
            bookID: bookID,
            chapterID: descriptor.id
        ), saved.textVersion == SentenceSplitter.textVersion,
           saved.isVolumeDivider != nil,
           saved.imagesVersion == ImageExtraction.version {
            // 后两条和 `loadParsedChapter` 同一口径：扉页判据与图的锚点都落在字段缺失的那批老数据上，
            // 那时候还没判过、没记过，让它回 parser 重切一次。不然量页这一趟按「样板句也算正文」数、
            // 按「这一章没有图」留白，纸上是扉页和一块图框、底下那行页码却数着两行字——两把尺又是分家。
            return saved
        }

        return await Task.detached(priority: .utility) {
            try? EPUBParser.loadChapter(descriptor)
        }.value
    }

    // MARK: - 落盘

    /// 落盘的这一份要现在还作数才用：排版档换了、章数变了（重导入换了一茬 id）都算不作数。
    private static func held(
        bookID: UUID,
        metrics: String,
        chapters: Int
    ) -> BookPageMap? {

        guard
            let data = try? Data(contentsOf: fileURL(bookID)),
            let stored = try? JSONDecoder().decode(BookPageMap.self, from: data),
            stored.metrics == metrics,
            stored.counts.count == chapters
        else {
            return nil
        }

        return stored
    }

    private static func save(
        _ map: BookPageMap,
        bookID: UUID
    ) {

        let url = fileURL(bookID)

        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        guard let data = try? JSONEncoder().encode(map) else { return }

        try? data.write(to: url, options: .atomic)
    }

    /// 和 `chapters/` 同一层：统计与清理都按书走。
    private static func fileURL(_ bookID: UUID) -> URL {
        ReaderCache.bookAnalysisDirectory(bookID)
            .appendingPathComponent("pages.json")
    }
}
