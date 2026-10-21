//
//  EPUBParser.swift
//  Reader
//
//  Created by 粟海洋 on 2026/8/26.
//

import Foundation
import ImageIO
import ZIPFoundation

struct EPUBParser {

    enum EPUBError: LocalizedError {

        case invalidEPUB
        case unzipFailed(String)
        case missingContainer
        case missingOPF
        case invalidOPF
        case noChapters
        case chapterNotFound

        var errorDescription: String? {

            switch self {

            case .invalidEPUB:
                return "无效的 EPUB 文件。"

            case .unzipFailed(let reason):
                return "解压失败：\(reason)"

            case .missingContainer:
                return "EPUB 缺少 META-INF/container.xml。"

            case .missingOPF:
                return "无法找到 EPUB 的 OPF 文件。"

            case .invalidOPF:
                return "无法解析 EPUB 的 OPF 文件。"

            case .noChapters:
                return "没有找到章节。"

            case .chapterNotFound:
                return "找不到指定章节。"
            }
        }
    }

    // MARK: - Import EPUB

    /// 导入 EPUB
    ///
    /// 注意：
    /// 这里只建立 EPUBBook + ChapterDescriptor。
    /// 不解析所有章节正文。
    static func importBook(
        from sourceURL: URL
    ) throws -> EPUBBook {

        let fileManager = FileManager.default

        // ------------------------------------------------
        // 创建持久化目录
        // ------------------------------------------------

        let base =
            fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0]

        let rootURL =
            base
            .appendingPathComponent(
                "AIReader/Books",
                isDirectory: true
            )
            .appendingPathComponent(
                UUID().uuidString,
                isDirectory: true
            )

        try fileManager.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )

        // ------------------------------------------------
        // 解压 EPUB
        // ------------------------------------------------

        do {

            try fileManager.unzipItem(
                at: sourceURL,
                to: rootURL
            )

        } catch {

            try? fileManager.removeItem(
                at: rootURL
            )
            
            print("解压失败: \(error)")

            throw EPUBError.unzipFailed(
                error.localizedDescription
            )
        }

        // ------------------------------------------------
        // container.xml
        // ------------------------------------------------

        let containerURL =
            rootURL
                .appendingPathComponent(
                    "META-INF/container.xml"
                )

        guard fileManager.fileExists(
            atPath: containerURL.path
        ) else {

            throw EPUBError.missingContainer
        }

        let containerXML =
            try readText(
                from: containerURL
            )

        // ------------------------------------------------
        // 找 OPF
        // ------------------------------------------------

        guard let opfPath =
                extractOPFPath(
                    from: containerXML
                )
        else {

            throw EPUBError.missingOPF
        }

        let opfURL =
            rootURL
                .appendingPathComponent(
                    opfPath
                )

        guard fileManager.fileExists(
            atPath: opfURL.path
        ) else {

            throw EPUBError.missingOPF
        }

        let opfDirectory =
            opfURL.deletingLastPathComponent()

        let opfXML =
            try readText(
                from: opfURL
            )

        // ------------------------------------------------
        // Metadata
        // ------------------------------------------------

        let metadata =
            parseMetadata(
                from: opfXML
            )

        // ------------------------------------------------
        // Manifest
        // ------------------------------------------------

        let manifest =
            parseManifest(
                from: opfXML
            )

        // ------------------------------------------------
        // Spine
        // ------------------------------------------------

        let spine =
            parseSpine(
                from: opfXML
            )

        guard !spine.isEmpty else {
            throw EPUBError.noChapters
        }

        // ------------------------------------------------
        // Cover
        // ------------------------------------------------

        let coverURL =
            findCoverURL(
                opfXML: opfXML,
                manifest: manifest,
                opfDirectory: opfDirectory
            )

        // ------------------------------------------------
        // Chapter descriptors
        //
        // 这里只建立索引。
        // 不读取 XHTML 正文。
        // ------------------------------------------------

        // 先把「确实是正文」的书脊条目挑出来，再一次性筛掉封面。
        // 分成两趟是为了下面那条「别把整本筛空」的兜底：只看单条没法知道还剩几条。
        var candidates: [Candidate] = []

        for itemID in spine {

            guard let item =
                    manifest[itemID]
            else {
                continue
            }

            guard isHTML(
                mediaType: item.mediaType
            ) else {
                continue
            }

            let fileURL =
                EPUBHref.resolve(
                    href: item.href,
                    relativeTo: opfDirectory
                )

            guard fileManager.fileExists(
                atPath: fileURL.path
            ) else {
                continue
            }

            candidates.append(
                Candidate(
                    itemID: itemID,
                    href: item.href,
                    fileURL: fileURL,
                    properties: item.properties
                )
            )
        }

        let body = candidates.filter {
            !isCoverPage(
                itemID: $0.itemID,
                fileURL: $0.fileURL,
                properties: $0.properties
            )
        }

        // 只剩封面的书（图片本）把封面留着：宁可给你一章能看，也不要报「没有找到章节」。
        if !body.isEmpty {
            candidates = body
        }

        var chapters: [
            ChapterDescriptor
        ] = []

        // `index` 是这份书单里的第几章，不是书脊位置——筛掉的封面/扉页不该占掉一个章号，
        // 否则第一正文章的页眉会写「第二章」（见 `ChapterDescriptor.backLabel`）。
        var imageTally: [String: Int] = [:]

        for (index, candidate) in candidates.enumerated() {

            let fileURL = candidate.fileURL

            // 这里只读取 XHTML 的标题，顺带数一遍图。
            //
            // 如果你希望导入做到极致快速，
            // 这个地方也可以不读取标题，
            // 直接使用 "第N章"（图那一份统计也就跟着没了，装饰图筛不掉）。
            //
            // 标题与重复率共用**同一趟**读盘：这一圈一本书要走几百次，多开一次盘就是导入慢一倍。
            let html = try? readText(from: fileURL)

            let title = HTMLTextExtractor.cleanHTMLTitle(
                chapterTitle(in: html ?? "")
                    ?? ChapterDescriptor.chapterLabel(index: index)
            )

            if let html {
                mergeImageTally(&imageTally, html: html, chapterURL: fileURL)
            }

            let descriptor =
                ChapterDescriptor(
                    index: index,
                    title: title,
                    itemID: candidate.itemID,
                    href: candidate.href,
                    fileURL: fileURL
                )

            chapters.append(
                descriptor
            )
        }

        guard !chapters.isEmpty else {
            throw EPUBError.noChapters
        }

        return EPUBBook(
            title:
                metadata.title
                ?? sourceURL
                    .deletingPathExtension()
                    .lastPathComponent,

            author:
                metadata.author,

            rootURL:
                rootURL,

            opfDirectory:
                opfDirectory,

            coverURL:
                coverURL,

            chapters:
                chapters,

            imageTally:
                imageTally
        )
    }

    /// 书脊上一条已经过了三道校验、还没决定要不要当正文的条目。
    /// 字段摊平写：`ManifestItem` 是这份文件私有的，跟着它走就把这个类型也关住了。
    struct Candidate {

        let itemID: String

        let href: String

        let fileURL: URL

        let properties: String?
    }

    /// 这一条是不是封面/扉页。
    ///
    /// EPUB 没有一个管用的写法：标准只在 manifest 上给了 `properties="cover-page"`，
    /// 而手上两本真书都没标——牧神记是 `Text/cover.html`（内容只有书名那一行），
    /// 我欲封天是 `Text/coverpage.html`（书名 + 作者 + 简介）。所以判据只有两条：
    /// ① 有 cover-page 标记；② 名字（manifest id 或文件名）以 cover / title 开头。
    ///
    /// 按名字而不是按「有没有正文」：后者会把只有书名的封面漏掉（它有一句），
    /// 又会误伤真没文字的图片章。章节文件名是 Ch0001 / chapter1 这一类，撞不上这两个前缀。
    static func isCoverPage(
        itemID: String,
        fileURL: URL,
        properties: String?
    ) -> Bool {

        if properties?
            .lowercased()
            .split(separator: " ")
            .contains("cover-page") == true {
            return true
        }

        let names = [
            itemID,
            fileURL.deletingPathExtension().lastPathComponent
        ].map { $0.lowercased() }

        return names.contains { name in
            name.hasPrefix("cover") || name.hasPrefix("title")
        }
    }
}

// MARK: - Load Chapter

extension EPUBParser {

    /// 只解析指定章节
    ///
    /// 导入时在后台逐章跑完；打开章节只有落库缺失或 ``SentenceSplitter/textVersion``
    /// 对不上时才回落这里。
    static func loadChapter(
        _ descriptor: ChapterDescriptor
    ) throws -> Chapter {

        guard FileManager.default.fileExists(
            atPath: descriptor.fileURL.path
        ) else {

            throw EPUBError.chapterNotFound
        }

        // --------------------------------------------
        // 读取这一章 XHTML
        // --------------------------------------------

        let html =
            try readText(
                from: descriptor.fileURL
            )

        // --------------------------------------------
        // 移除章节标题
        //
        // 标题已经在 navigationTitle 中显示，
        // 不需要出现在正文里。
        // --------------------------------------------

        /// 书单上那个标题可能是导入时**补出来**的「第N章」：卷页写的是
        /// `<h1 style="display:none" title="第一卷 在澹州"></h1>`，字在属性里、标签里是空的，
        /// 加这一条兜底之前的老数据就是这么丢的（#198）。这里重读一次就能拿回来——
        /// 只在这一格确实等于按书脊顺序补的那一串时才重读，书里真写着「第五章」的一概不动。
        let title = repairedTitle(
            stored: descriptor.title,
            index: descriptor.index,
            html: html
        )

        let htmlWithoutTitle =
            removeTitleHeading(
                from: html,
                title: title
            )

        // --------------------------------------------
        // XHTML → 纯文本（图换成哨兵，src 按出现顺序拿出来）
        // --------------------------------------------

        let extracted =
            HTMLTextExtractor.extractBody(
                from: htmlWithoutTitle
            )

        // --------------------------------------------
        // 清理
        // --------------------------------------------

        let marked =
            clean(
                extracted.text
            )

        // --------------------------------------------
        // 图锚：把哨兵摘干净，交回一份「书里没图」的正文 + 每张图站在哪一句之前
        //
        // 顺序要紧：`isVolumeDivider`、`SentenceSplitter` 都只能看摘干净的那一份，
        // 不然哨兵这一个字符会混进「这一章有没有正文」的字数账里。
        // --------------------------------------------

        let anchored = imageAnchors(
            in: marked,
            hrefs: extracted.imageHrefs,
            chapterURL: descriptor.fileURL
        )

        let cleanText = anchored.body

        // --------------------------------------------
        // 卷扉页：除了卷名和「书名 / 作者」那种样板，一个字正文都没有。
        //
        // 判据放在这里而不是导入时：正文只有这一趟读得到，而老书单（没记过这个结论的
        // 那些本）也要能当场认出来。扉页交出去的是零句——不排产、不朗读，
        // 渲染端按 `isVolumeDivider` 把卷名居中印在纸上。
        //
        // 这一支顺手不交图：整面纸只印卷名，而零句的章里没有一句能挂图（渲染端走
        // `volumeDivider` 那一支，塞一块图框进去只会把卷名挤离中心）。
        // --------------------------------------------

        if isVolumeDivider(title: title, body: cleanText) {

            return Chapter(
                id: descriptor.id,
                index: descriptor.index,
                title: title,
                sentences: [],
                isVolumeDivider: true
            )
        }

        // --------------------------------------------
        // 句子切分
        // --------------------------------------------

        let sentences =
            SentenceSplitter.split(
                cleanText,
                chapterIndex: descriptor.index
            )

        // --------------------------------------------
        // 转换成你的 Chapter
        // --------------------------------------------

        return Chapter(
            id: descriptor.id,
            index: descriptor.index,
            title: title,
            sentences: sentences,
            textVersion: SentenceSplitter.textVersion,
            images: anchored.images
        )
    }
}

// MARK: - Helpers

private extension EPUBParser {

    static func readText(
        from url: URL
    ) throws -> String {

        if let text =
            try? String(
                contentsOf: url,
                encoding: .utf8
            ) {

            return text
        }

        if let text =
            try? String(
                contentsOf: url,
                encoding: .utf16
            ) {

            return text
        }

        return try String(
            contentsOf: url,
            encoding: .unicode
        )
    }

    static func isHTML(
        mediaType: String
    ) -> Bool {

        let type =
            mediaType.lowercased()

        return type.contains("html")
            || type.contains("xhtml")
    }

    static func clean(
        _ text: String
    ) -> String {

        var result = text

        result =
            result.replacingOccurrences(
                of: "\r\n",
                with: "\n"
            )

        result =
            result.replacingOccurrences(
                of: "\r",
                with: "\n"
            )

        result =
            result.replacingOccurrences(
                of: "[ \\t]+",
                with: " ",
                options: .regularExpression
            )

        result =
            result.replacingOccurrences(
                of: "\n\\s*\n+",
                with: "\n",
                options: .regularExpression
            )

        return result.trimmingCharacters(
            in: CharacterSet.whitespacesAndNewlines
        )
    }

    // MARK: - 卷扉页

    /// 「第N卷」开头（第一章那种不算）。数字这一档和 `ChapterDescriptor.chapterNumberRegex`
    /// 同一套写法，另外补上大写数字（壹贰叁）——卷页常用。
    private static let volumeTitleRegex = try! NSRegularExpression(
        pattern: "^第[0-9０-９一二三四五六七八九十百千零两壹贰叁肆伍陆柒捌玖拾佰]{1,8}卷"
    )

    /// 句末标点。正文里只要出现一个，这一章就是有正文的，不是扉页。
    private static let sentenceTerminators = ["。", "！", "？", "…", "”"]

    /// 这一章是不是卷扉页。判据两条（庆余年、我欲封天取证 #198）：
    ///
    /// ① 标题以「第N卷」开头；
    /// ② 提不出正文：除了「我欲封天 / 作者：耳根」「在澹州 / 第一卷」这种书壳样板，
    ///    一句正文都没有——每一行都短（≤8 字）、总长 ≤40 字、且一个句末标点都没有。
    ///
    /// ② 才是关键。只看 ① 会把两种真章误伤：有的书真拿「第一卷」当章名还带着正文，
    /// 而卷页本身在源文件里的形状是「`<h1 style="display:none">` + 一张 logo + 书名作者」
    /// 或者一个只写卷名的 `<table>`，正文那格（`<div class="novel_body">`）是空的。
    /// 判据写成「有没有正文」而不是「文件多大」：604 字节的短文照样能躲开这道闸。
    static func isVolumeDivider(
        title: String,
        body: String
    ) -> Bool {

        guard volumeTitleRegex.firstMatch(
            in: title,
            range: NSRange(
                location: 0,
                length: title.utf16.count
            )
        ) != nil else {
            return false
        }

        guard !body.isEmpty else {
            return true
        }

        let lines = body
            .split(separator: "\n")
            .map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            .filter {
                !$0.isEmpty
            }

        guard lines.allSatisfy({ $0.count <= 8 }),
              body.reduce(0, { $0 + ($1.isWhitespace ? 0 : 1) }) <= 40,
              sentenceTerminators.allSatisfy({ !body.contains($0) })
        else {
            return false
        }

        return true
    }
}

// MARK: - 正文图片

extension EPUBParser {

    /// 「这张图上不上纸」的口径（尺寸下限、装饰图判据、重复率表里的那枚 key）都在
    /// `ChapterImage` 上，这里不复制一份：种表的是这一侧，筛图的是书单 `Book.placedImages`
    /// 那一侧，两边各写一遍迟早分家。

    /// 摘出图锚，交回一份「书里根本没有图」的正文。
    ///
    /// 两条硬要求：
    /// ① 正文一个字不许变。句子下标是音频的锚（`Sentence.deterministicID` 拿
    ///   「章号-句号-字」做种子），多一节少一节就是全书录音集体过期；
    /// ② 锚恒等于段首句。渲染端一段一个 `Text`，图插在一段中间它画不出来。
    ///
    /// 锚 = 哨兵之后第一个句子的下标。图通常紧贴自己的图注（`<p class="imgDescript">图1.1 …</p>`），
    /// 所以图正好压在图注头顶，而图注照旧是一句正文——能点、能读，不必另存一份（存两份必有一版漂）。
    ///
    /// 整行只有哨兵的那种（图的独占段）连行一起去掉，于是剩下的正文与「`<img>` 直接不存在」
    /// 逐字相同。锚按**前缀**量：`split(图之前那些行).count`，走的是和整章同一条切分路径，
    /// 所以这个数与落库那份不会分家。
    ///
    /// 唯一的例外：图后面紧跟一个「没有可朗读字的段落」（孤零零一个「”」）——那种段落会在整章
    /// 切分时并回上一句，按前缀量它算一句，于是图往后挪一句。一行以内的事，
    /// 而且探针在真书上逐张对过图注（`.probe/image-anchor-probe.swift`）。
    ///
    /// 装饰图**不在这里筛**：那条判据要全书的重复率，而这一份逐章落库，筛在这里就得
    /// 为一次统计重解整本书。筛在用量那一侧，见 `Book.placedImages`。
    static func imageAnchors(
        in text: String,
        hrefs: [String],
        chapterURL: URL
    ) -> (body: String, images: [ChapterImage]) {

        let marker = HTMLTextExtractor.imageMarkerCharacter

        guard text.contains(marker), !hrefs.isEmpty else {
            return (text, [])
        }

        // 第一趟：把哨兵从正文里摘干净，同时记下每一张图站在「保留下来的第几行」之前。
        var keptLines: [String] = []
        var lineOfImage: [Int] = []

        for rawLine in text.components(separatedBy: "\n") {

            var inLine = 0
            for character in rawLine where character == marker {
                inLine += 1
            }

            guard inLine > 0 else {
                keptLines.append(rawLine)
                continue
            }

            // 行里还有字（图混在图注里那一类）→ 字原样留在原位，图落在这段头顶；
            // 整行只有哨兵（`<p class="bodyPic">` 那种）→ 这一段本来没字，行也不留。
            // 留下时不许 trim：段首那两个全角空格是缩进，被 `SentenceSplitter` 认着的。
            let stripped = String(rawLine.filter { $0 != marker })

            for _ in 0..<inLine {
                lineOfImage.append(keptLines.count)
            }

            if !stripped.trimmingCharacters(in: .whitespaces).isEmpty {
                keptLines.append(stripped)
            }
        }

        // 第二趟：行号 → 句下标。按前缀现切，走的是和整章同一条切分路径，
        // 所以「图之前有几个句子」这个数不会和落库那份漂。同一行多张图共用一个数。
        var anchorCache: [Int: Int] = [:]

        func sentenceAnchor(line: Int) -> Int {
            if let hit = anchorCache[line] { return hit }
            let prefix = keptLines[0..<min(line, keptLines.count)]
                .joined(separator: "\n")
            let value = SentenceSplitter.split(prefix, chapterIndex: 0).count
            anchorCache[line] = value
            return value
        }

        var images: [ChapterImage] = []

        for (index, href) in hrefs.enumerated() {

            guard index < lineOfImage.count else { break }

            guard let size = imagePixelSize(href: href, chapterURL: chapterURL),
                  min(size.width, size.height) >= ChapterImage.minimumImageEdge
            else { continue }

            images.append(
                ChapterImage(
                    href: href,
                    anchor: sentenceAnchor(line: lineOfImage[index]),
                    pixelWidth: size.width,
                    pixelHeight: size.height
                )
            )
        }

        return (keptLines.joined(separator: "\n"), images)
    }

    /// 只读图片文件头拿宽高，**不解码像素**。
    ///
    /// 为什么在解析期量：排版要先知道这一块多高才能分页，而分页就在点开那一章的路径上。
    /// `CGImageSourceCreateWithURL` + `CopyPropertiesAtIndex` 读的是 JPEG/PNG 的头，
    /// 一本 190 张图的书逐张问一遍实测在几毫秒级；整图解码留给渲染端按需下采样。
    ///
    /// EXIF 方向参与：手机拍的书横着存（orientation 6/8）时像素是竖的、看是横的，
    /// 不调换就会给出一块瘦高的框，纸上压扁一条。
    static func imagePixelSize(
        href: String,
        chapterURL: URL
    ) -> (width: Int, height: Int)? {

        let url = EPUBHref.resolve(
            href: href,
            relativeTo: chapterURL.deletingLastPathComponent()
        )

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else {
            return nil
        }

        // 1…4 = 正放（含镜像），5…8 = 转了 90/270，宽高要互换。
        let orientation = (properties[kCGImagePropertyOrientation] as? UInt32) ?? 1
        if (5...8).contains(orientation) {
            return (height, width)
        }

        return (width, height)
    }

    /// 全书的图重复率：一张图（按 `ChapterImage.imageKey` 归一）出现在多少章里，一章内重复只算一次。
    ///
    /// 导入那一趟本来就要逐章读文件取标题，图顺着同一份 html 数一遍，不多开一次盘。
    /// 老书单没有这份表：`ReaderPipeline` 在后台补算，用的还是这一个函数。
    static func mergeImageTally(
        _ tally: inout [String: Int],
        html: String,
        chapterURL: URL
    ) {
        var seen: Set<String> = []
        for href in HTMLTextExtractor.imageHrefs(in: html) {
            let key = ChapterImage.imageKey(href: href, chapterURL: chapterURL)
            if seen.insert(key).inserted {
                tally[key, default: 0] += 1
            }
        }
    }

    static func imageTally(
        chapterURLs: [URL]
    ) -> [String: Int] {

        var tally: [String: Int] = [:]

        for url in chapterURLs {
            guard let html = try? readText(from: url) else { continue }
            mergeImageTally(&tally, html: html, chapterURL: url)
        }

        return tally
    }
}

private extension EPUBParser {

    /// 书单上那个标题可能是导入时**补出来**的「第N章」：卷页写的是
    /// `<h1 style="display:none" title="第一卷 在澹州"></h1>`，字在属性里、标签里是空的，
    /// 读不到属性就一律兜底成按顺序补的那一串（#198 之前 imported 的那些本全是这样）。
    /// 正文就在这一章的 XHTML 里，重读一次能把真标题拿回来——
    /// 只在这一格确实等于补出来的那串时才重读，书里真写着「第五章」的一概不动。
    static func repairedTitle(
        stored: String,
        index: Int,
        html: String
    ) -> String {

        guard stored == ChapterDescriptor.chapterLabel(index: index),
              let read = chapterTitle(in: html).map(HTMLTextExtractor.cleanHTMLTitle),
              !read.isEmpty
        else {
            return stored
        }

        return read
    }

    /// 这一页的标题：先看 h1、h2 里写的字，再看**隐藏标题的 `title="…"` 属性**，
    /// 最后才退到 `<title>`。
    ///
    /// 属性那一手不是可有可无的补充：卷页普遍写成空标签 + 属性（见 `isVolumeDivider`），
    /// 只读内部文字的话卷名整个丢掉，页眉上写着「第五章」而纸上什么都没有——
    /// 那就是用户报的「第一卷被当作章节，但什么也不展示」。
    static func chapterTitle(
        in html: String
    ) -> String? {

        for tag in ["h1", "h2"] {

            if let title = HTMLTextExtractor.firstTagValue(
                tag,
                in: html
            ), !title.isEmpty {
                return title
            }
        }

        if let title = hiddenHeadingTitle(in: html) {
            return title
        }

        if let title = HTMLTextExtractor.firstTagValue(
            "title",
            in: html
        ), !title.isEmpty {
            return title
        }

        return nil
    }

    /// 空标签上挂着的标题：`<h1 style="display:none" title="第一卷 在澹州"></h1>`。
    ///
    /// 要求标签里是空的（`>\s*</h`）：有内部文字的标题走 `firstTagValue` 那一手，
    /// 属性只是它的备胎——两头都读的话，「<h1 title="真标题">假标题</h1>」这种就得判谁赢，
    /// 而现实里没有那种写法。
    private static func hiddenHeadingTitle(
        in html: String
    ) -> String? {

        let pattern =
            "<h[1-6]\\b[^>]*?\\btitle=[\"']([^\"']+)[\"'][^>]*>\\s*</h[1-6]>"

        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else {
            return nil
        }

        let range = NSRange(
            html.startIndex..<html.endIndex,
            in: html
        )

        guard let match = regex.firstMatch(in: html, range: range),
              let valueRange = Range(match.range(at: 1), in: html)
        else {
            return nil
        }

        return String(html[valueRange])
    }

    static func removeTitleHeading(
        from html: String,
        title: String
    ) -> String {

        let escaped =
            NSRegularExpression
                .escapedPattern(for: title)

        let pattern =
            "<(h[1-6])[^>]*>\\s*\(escaped)\\s*</\\1>"

        guard let regex =
                try? NSRegularExpression(
                    pattern: pattern,
                    options: [.caseInsensitive]
                )
        else {
            return html
        }

        let range = NSRange(
            html.startIndex..<html.endIndex,
            in: html
        )

        return regex.stringByReplacingMatches(
            in: html,
            range: range,
            withTemplate: ""
        )
    }
}

// MARK: - Metadata

private extension EPUBParser {

    struct Metadata {

        let title: String?

        let author: String?
    }

    static func parseMetadata(
        from xml: String
    ) -> Metadata {

        Metadata(
            title:
                firstTagValue(
                    "dc:title",
                    in: xml
                ),

            author:
                firstTagValue(
                    "dc:creator",
                    in: xml
                )
        )
    }

    static func firstTagValue(
        _ tag: String,
        in xml: String
    ) -> String? {

        let escaped =
            NSRegularExpression
                .escapedPattern(
                    for: tag
                )

        let pattern =
            "<\(escaped)[^>]*>(.*?)</\(escaped)>"

        guard let regex =
                try? NSRegularExpression(
                    pattern: pattern,
                    options: [
                        .caseInsensitive,
                        .dotMatchesLineSeparators
                    ]
                )
        else {
            return nil
        }

        let range =
            NSRange(
                xml.startIndex..<xml.endIndex,
                in: xml
            )

        guard let match =
                regex.firstMatch(
                    in: xml,
                    range: range
                )
        else {
            return nil
        }

        guard let valueRange =
                Range(
                    match.range(at: 1),
                    in: xml
                )
        else {
            return nil
        }

        return HTMLTextExtractor
            .decodeEntities(
                String(
                    xml[valueRange]
                )
            )
            .trimmingCharacters(
                in: CharacterSet.whitespacesAndNewlines
            )
    }
}

// MARK: - Manifest

private extension EPUBParser {

    struct ManifestItem {

        let id: String

        let href: String

        let mediaType: String

        let properties: String?
    }

    static func parseManifest(
        from xml: String
    ) -> [String: ManifestItem] {

        var result:
            [String: ManifestItem] = [:]

        let pattern =
            #"<item\b([^>]*)/?>"#

        guard let regex =
                try? NSRegularExpression(
                    pattern: pattern,
                    options: [
                        .caseInsensitive,
                        .dotMatchesLineSeparators
                    ]
                )
        else {
            return result
        }

        let range =
            NSRange(
                xml.startIndex..<xml.endIndex,
                in: xml
            )

        for match in regex.matches(
            in: xml,
            range: range
        ) {

            guard let attributesRange =
                    Range(
                        match.range(at: 1),
                        in: xml
                    )
            else {
                continue
            }

            let attributes =
                String(
                    xml[attributesRange]
                )

            guard
                let id =
                    attribute(
                        "id",
                        from: attributes
                    ),

                let href =
                    attribute(
                        "href",
                        from: attributes
                    ),

                let mediaType =
                    attribute(
                        "media-type",
                        from: attributes
                    )
            else {
                continue
            }

            let properties =
                attribute(
                    "properties",
                    from: attributes
                )

            result[id] =
                ManifestItem(
                    id: id,
                    href: href,
                    mediaType: mediaType,
                    properties: properties
                )
        }

        return result
    }

    static func attribute(
        _ name: String,
        from attributes: String
    ) -> String? {

        let pattern =
            #"\b\#(name)=["']([^"']+)["']"#

        guard let regex =
                try? NSRegularExpression(
                    pattern: pattern,
                    options: [
                        .caseInsensitive
                    ]
                )
        else {
            return nil
        }

        let range =
            NSRange(
                attributes.startIndex..<attributes.endIndex,
                in: attributes
            )

        guard let match =
                regex.firstMatch(
                    in: attributes,
                    range: range
                )
        else {
            return nil
        }

        guard let valueRange =
                Range(
                    match.range(at: 1),
                    in: attributes
                )
        else {
            return nil
        }

        return String(
            attributes[valueRange]
        )
    }
}

// MARK: - Spine

private extension EPUBParser {

    static func parseSpine(
        from xml: String
    ) -> [String] {

        let pattern =
            #"<itemref\b[^>]*\bidref=["']([^"']+)["'][^>]*/?>"#

        guard let regex =
                try? NSRegularExpression(
                    pattern: pattern,
                    options: [
                        .caseInsensitive
                    ]
                )
        else {
            return []
        }

        let range =
            NSRange(
                xml.startIndex..<xml.endIndex,
                in: xml
            )

        return regex
            .matches(
                in: xml,
                range: range
            )
            .compactMap { match in

                guard let valueRange =
                        Range(
                            match.range(at: 1),
                            in: xml
                        )
                else {
                    return nil
                }

                return String(
                    xml[valueRange]
                )
            }
    }
}

// MARK: - Cover

private extension EPUBParser {

    static func findCoverURL(
        opfXML: String,
        manifest: [
            String: ManifestItem
        ],
        opfDirectory: URL
    ) -> URL? {

        // EPUB3:
        // properties="cover-image"

        if let item =
            manifest.values.first(
                where: {
                    $0.properties?
                        .contains("cover-image")
                    == true
                }
            ) {

            return EPUBHref.resolve(
                href: item.href,
                relativeTo: opfDirectory
            )
        }

        // EPUB2:
        // <meta name="cover" content="cover-image"/>

        let pattern =
            #"<meta\b[^>]*\bname=["']cover["'][^>]*\bcontent=["']([^"']+)["'][^>]*/?>"#

        if let regex =
            try? NSRegularExpression(
                pattern: pattern,
                options: [
                    .caseInsensitive
                ]
            ) {

            let range =
                NSRange(
                    opfXML.startIndex..<opfXML.endIndex,
                    in: opfXML
                )

            if let match =
                regex.firstMatch(
                    in: opfXML,
                    range: range
                ),
               let valueRange =
                Range(
                    match.range(at: 1),
                    in: opfXML
                ) {

                let coverID =
                    String(
                        opfXML[valueRange]
                    )

                if let item =
                    manifest[coverID] {

                    return EPUBHref.resolve(
                        href: item.href,
                        relativeTo: opfDirectory
                    )
                }
            }
        }

        return nil
    }
}

// MARK: - Chapter Title

private extension EPUBParser {

    static func extractOPFPath(from xml: String) -> String? {
        let pattern =
            #"<rootfile\b[^>]*\bfull-path=["']([^"']+)["'][^>]*/?>"#

        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else {
            return nil
        }

        let range = NSRange(
            xml.startIndex..<xml.endIndex,
            in: xml
        )

        guard let match = regex.firstMatch(
            in: xml,
            range: range
        ) else {
            return nil
        }

        guard let valueRange = Range(
            match.range(at: 1),
            in: xml
        ) else {
            return nil
        }

        return String(xml[valueRange])
    }
}

