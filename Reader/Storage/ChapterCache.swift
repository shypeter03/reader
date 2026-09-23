//
//  ChapterCache.swift
//  Reader
//
//  Created by 粟海洋 on 2026/9/21.
//

import Foundation

/// 内存级 LRU 缓存：只保留最近访问的少量章节，
/// 其余章节落盘在 ChapterStore，命中时再从磁盘读回。
/// 避免整本逐章处理后把所有章节常驻内存导致内存溢出闪退。
actor ChapterCache {

    private let maxCount: Int

    /// MRU 排在数组末尾
    private var order: [UUID] = []

    private var storage: [UUID: Chapter] = [:]

    init(maxCount: Int = 8) {
        self.maxCount = max(maxCount, 1)
    }

    func get(_ id: UUID) -> Chapter? {
        guard let chapter = storage[id] else {
            return nil
        }

        touch(id)

        return chapter
    }

    func set(_ chapter: Chapter) {
        let id = chapter.id

        if storage[id] != nil {
            storage[id] = chapter
            touch(id)
            return
        }

        storage[id] = chapter
        order.append(id)

        while order.count > maxCount {
            let evicted = order.removeFirst()
            storage[evicted] = nil
        }
    }

    /// 磁盘上的解析结果被整体清掉后必须一起清：否则内存里的旧 Chapter
    /// 还会带着已失效的 audioURL 被读出来。
    func removeAll() {
        storage.removeAll()
        order.removeAll()
    }

    private func touch(_ id: UUID) {
        if let index = order.firstIndex(of: id) {
            order.remove(at: index)
        }
        order.append(id)
    }
}
