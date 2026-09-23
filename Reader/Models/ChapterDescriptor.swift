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
}
