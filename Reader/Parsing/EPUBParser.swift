//
//  EPUBParser.swift
//  Reader
//
//  Created by 粟海洋 on 2026/8/26.
//

import Foundation
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
                resolve(
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
        for (index, candidate) in candidates.enumerated() {

            let fileURL = candidate.fileURL

            // 这里只读取 XHTML 的标题。
            //
            // 如果你希望导入做到极致快速，
            // 这个地方也可以不读取标题，
            // 直接使用 "第N章"。
            let title = HTMLTextExtractor.cleanHTMLTitle(readChapterTitle(
                    from: fileURL
                )
                ?? ChapterDescriptor.chapterLabel(index: index))

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
                chapters
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

        let htmlWithoutTitle =
            removeTitleHeading(
                from: html,
                title: descriptor.title
            )

        // --------------------------------------------
        // XHTML → 纯文本
        // --------------------------------------------

        let text =
            HTMLTextExtractor.extractText(
                from: htmlWithoutTitle
            )

        // --------------------------------------------
        // 清理
        // --------------------------------------------

        let cleanText =
            clean(
                text
            )

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
            title: descriptor.title,
            sentences: sentences,
            textVersion: SentenceSplitter.textVersion
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

    static func resolve(
        href: String,
        relativeTo baseURL: URL
    ) -> URL {

        let cleanHref =
            href
                .removingPercentEncoding
            ?? href

        return baseURL
            .appendingPathComponent(
                cleanHref
            )
            .standardizedFileURL
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

            return resolve(
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

                    return resolve(
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

    static func readChapterTitle(
        from url: URL
    ) -> String? {

        guard let html =
                try? readText(
                    from: url
                )
        else {
            return nil
        }

        if let title =
            HTMLTextExtractor.firstTagValue(
                "h1",
                in: html
            ) {

            if !title.isEmpty {
                return title
            }
        }

        if let title =
            HTMLTextExtractor.firstTagValue(
                "h2",
                in: html
            ) {

            if !title.isEmpty {
                return title
            }
        }

        if let title =
            HTMLTextExtractor.firstTagValue(
                "title",
                in: html
            ) {

            if !title.isEmpty {
                return title
            }
        }

        return nil
    }
    
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

