//
//  ChapterDescriptor.swift
//  Reader
//
//  Created by 粟海洋 on 2026/8/26.
//

import Foundation

struct ChapterDescriptor: Identifiable, Codable {

    let id: UUID

    /// 在 EPUB spine 中的顺序
    let index: Int

    /// 章节标题
    let title: String

    /// manifest item id
    let itemID: String

    /// XHTML 相对于 OPF 的路径
    let href: String

    /// XHTML 实际文件位置
    let fileURL: URL

    init(
        id: UUID = UUID(),
        index: Int,
        title: String,
        itemID: String,
        href: String,
        fileURL: URL
    ) {
        self.id = id
        self.index = index
        self.title = title
        self.itemID = itemID
        self.href = href
        self.fileURL = fileURL
    }

    /// 换一个 `fileURL`，其余字段（含 `id`）原样。
    ///
    /// 只能走这里，不能就地重建：`id` 一换，这一章的解析结果和音频缓存全成孤儿，
    /// 表现是「重接路径之后每章都要重新生成」。
    func replacingFileURL(_ url: URL) -> ChapterDescriptor {
        ChapterDescriptor(
            id: id,
            index: index,
            title: title,
            itemID: itemID,
            href: href,
            fileURL: url
        )
    }

    /// 换一个 `index`，其余字段（含 `id`）原样。理由同 ``replacingFileURL``：
    /// 拿掉封面/扉页之后要按新的第几章重排，但 `id` 一动，这一章的解析结果和音频缓存就成孤儿。
    func replacingIndex(_ index: Int) -> ChapterDescriptor {
        ChapterDescriptor(
            id: id,
            index: index,
            title: title,
            itemID: itemID,
            href: href,
            fileURL: fileURL
        )
    }

    /// 顶部页眉上那串字，形如「第2章 李火旺」。
    ///
    /// EPUB 的 h1 有时写全「第1章 重生」，有时只写「重生」，还有的是空的。
    /// 没带章号就按书脊顺序补一个——章号是排出来的事实，不是编的标题。
    var backLabel: String {
        // 书名号里常见「<span>第2章</span><br/>李火旺」：抽出来是一个夹在中间的换行。
        // 单行显示时换行后面整截被切掉，页眉就只剩「第2章」——所以先并成空格再判章号。
        let trimmed = title
            .replacingOccurrences(
                of: "[ \\t]*\\n+[ \\t]*",
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            return Self.chapterLabel(index: index)
        }

        return Self.chapterNumberRegex.firstMatch(
            in: trimmed,
            range: NSRange(
                location: 0,
                length: trimmed.utf16.count
            )
        ) != nil
            ? trimmed
            : "\(Self.chapterLabel(index: index)) \(trimmed)"
    }

    /// 「第N章 / 第N节 / 第N回…」开头。
    private static let chapterNumberRegex = try! NSRegularExpression(
        pattern: "^第[0-9０-９一二三四五六七八九十百千零两]+[章节回卷集篇]"
    )

    /// 补出来的章序号一律用中文大写：第一章、第一千一百章。
    static func chapterLabel(index: Int) -> String {
        "第\(chineseNumber(index + 1))章"
    }

    /// 0~9999 转中文数字，按读数写（101 是「一百零一」，110 是「一百一十」）。
    /// 超出范围的书脊不猜写法，退回阿拉伯数字。
    static func chineseNumber(_ value: Int) -> String {

        guard value > 0, value <= 9999 else {
            return String(value)
        }

        let digits = ["零", "一", "二", "三", "四", "五", "六", "七", "八", "九"]
        let divisors = [1000, 100, 10, 1]
        let units = ["千", "百", "十", ""]

        var result = ""
        var started = false
        var pendingZero = false

        for (i, divisor) in divisors.enumerated() {

            let n = (value / divisor) % 10

            if n == 0 {
                if started { pendingZero = true }
                continue
            }

            if pendingZero {
                result += digits[0]
                pendingZero = false
            }

            // 「十一」不写「一十一」。
            if !(divisor == 10 && n == 1 && !started) {
                result += digits[n]
            }

            result += units[i]
            started = true
        }

        return result
    }
}
