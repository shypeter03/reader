//
//  TurnSpine.swift
//  Reader
//
//  卷页容器里现在摊着哪些纸：正文那一段，加上提前摊进来的相邻那一两章。
//
//  单独拆成一个文件：这里只有下标算术，不碰 SwiftUI，所以探针能把它连同真分页
//  （`PageLayout`）一起编进去离线核对——跨章那一下演不演卷页，看的就是这里的下标
//  动不动。
//

import Foundation

/// 卷页容器里现在有哪些纸：正文那一段，加上提前摊进来的相邻那一两章。
///
/// 为什么要这一层：`UIPageViewController` 只肯卷「自己页序里的下一面」。以前每章自己
/// 从第 0 面数起，跨章就是整份页序换一版——容器只能丢缓存、不动画地重新供一页，
/// 读者看到的是纸不卷、闪一下白出下一章；而那一面纸还是翻到边界才现算的。
/// 现在相邻那一章的分页提前算好贴进同一段页序，跨章就成了「往前多走一面」，动画照演。
///
/// 口径只有一条：**已经给出去的下标永远不动**。新纸只贴两头，丢纸只丢两头。
/// 于是「换代」（`generation`，也就是容器的 `revision`）只在正文换成一个不在页序里的章
/// 时才升——那种情况下同一个下标真的换了另一面纸，缓存必须作废。跨章不升：两段都在
/// 页序里，每个下标对应的还是同一面纸，容器那边等于什么都没发生（这正是我们要的）。
struct TurnSpine {

    /// 一章的纸，和它的第 0 面在整份页序里的下标。`base` 在它贴进来那一刻定下，之后不再移动。
    struct Sheet {

        let descriptor: ChapterDescriptor

        let chapter: Chapter

        let layout: PageLayout

        let base: Int

        /// 这一版分页是按哪些输入算出来的（`ReaderView.layoutKey` 那一套）。
        /// 跨章时它跟着纸交回视图，视图据此认出「这一章已经量过了」，不再重跑整章量高。
        let key: String
    }

    /// 正文第 0 面的下标。可以不是 0：上一章的纸贴在它前面时它是负的。
    private(set) var mainBase = 0

    /// 上一章的纸，贴在正文前面。还没预取到就是 nil。
    private(set) var before: Sheet?

    /// 下一章的纸，贴在正文后面。
    private(set) var after: Sheet?

    private(set) var generation = 0

    func startIndex(main: Sheet) -> Int {
        before?.base ?? main.base
    }

    func pageCount(main: Sheet) -> Int {
        (before?.layout.pageCount ?? 0)
            + main.layout.pageCount
            + (after?.layout.pageCount ?? 0)
    }

    func neighbor(forward: Bool) -> Sheet? {
        forward ? after : before
    }

    /// 某一章的纸现在在不在页序里（不在两头的邻段里就是不在）。
    func sheet(ofChapter id: UUID) -> Sheet? {

        if before?.chapter.id == id {
            return before
        }

        return after?.chapter.id == id ? after : nil
    }

    /// 第 index 面是哪一章的第几页。nil = 这一段页序没有这一面（两头之外）。
    func sheet(at index: Int, main: Sheet) -> (sheet: Sheet, local: Int)? {

        if let before, index >= before.base,
           index < before.base + before.layout.pageCount {
            return (before, index - before.base)
        }

        if main.layout.pages.indices.contains(index - main.base) {
            return (main, index - main.base)
        }

        if let after, index >= after.base,
           index < after.base + after.layout.pageCount {
            return (after, index - after.base)
        }

        return nil
    }

    /// 声音那句落在哪一面纸。它那一章不在页序里就比不出高低（nil）。
    func spacePage(
        ofSentence sentence: Int,
        in playing: Chapter,
        main: Sheet
    ) -> Int? {

        if let before, before.chapter.id == playing.id {
            return before.base + before.layout.page(containing: sentence)
        }

        if let after, after.chapter.id == playing.id {
            return after.base + after.layout.page(containing: sentence)
        }

        guard main.chapter.id == playing.id else { return nil }

        return main.base + main.layout.page(containing: sentence)
    }

    /// 预取到的上一章贴到头上。只动头，中间那些下标一个都不换。
    mutating func attachBefore(_ sheet: Sheet, main: Sheet) {

        before = Sheet(
            descriptor: sheet.descriptor,
            chapter: sheet.chapter,
            layout: sheet.layout,
            base: main.base - sheet.layout.pageCount,
            key: sheet.key
        )
    }

    mutating func attachAfter(_ sheet: Sheet, main: Sheet) {

        after = Sheet(
            descriptor: sheet.descriptor,
            chapter: sheet.chapter,
            layout: sheet.layout,
            base: main.base + main.layout.pageCount,
            key: sheet.key
        )
    }

    /// 两头丢掉。正文那一面重排过（补进来的说话人、改的字号行距、改的页宽）就得走这条：
    /// 两头那两段的起点是照旧的页数算的，留着要么和正文叠在一起、要么中间空出一段。
    /// 预取那条 task 会重新贴上。
    mutating func detachNeighbors() {
        before = nil
        after = nil
    }

    /// 整份页序重数：正文换成一个不在页序里的章（目录跳章、声音推进到没预取到的那一章）。
    /// 同一个下标从此是另一面纸，所以换代——容器会丢缓存、不动画地落页。
    mutating func reset() {
        before = nil
        after = nil
        mainBase = 0
        generation += 1
    }

    /// 正文换成后面那一段：原来那段退成「上一章」，两段的下标都不动。
    /// 后面没有纸就什么都不做（读者翻到了这本书的最后一面）。
    mutating func commitForward(from main: Sheet) {

        guard let after else { return }

        before = main
        mainBase = after.base
        self.after = nil
    }

    /// 正文换成前面那一段。
    mutating func commitBackward(from main: Sheet) {

        guard let before else { return }

        after = main
        mainBase = before.base
        self.before = nil
    }
}
