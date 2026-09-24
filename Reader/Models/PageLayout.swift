//
//  PageLayout.swift
//  Reader
//
//  书本式分页：先把每句量一遍，再按页的可用高度贪心装页。
//

import SwiftUI

/// 排版的唯一口径。正文渲染和分页测量必须共用这一组常量——
/// 两边各写一份的话，量出来 30 行、实际 31 行，字就会溢到下一页去。
enum ReaderTypography {

    static func bodySize(scale: Double) -> CGFloat {
        19 * CGFloat(scale)
    }

    static func lineSpacing(size: CGFloat) -> CGFloat {
        size * 0.42
    }

    /// 段首缩进两字，中文书的排版习惯。
    static func paragraphIndent(size: CGFloat) -> CGFloat {
        size * 2
    }

    static func sentenceGap(size: CGFloat) -> CGFloat {
        size * 0.8
    }

    static func labelSize(size: CGFloat) -> CGFloat {
        size * 0.72
    }

    static func labelHeight(size: CGFloat) -> CGFloat {
        size * 1.1
    }

    static let horizontalMargin: CGFloat = 22
    static let verticalMargin: CGFloat = 18

    /// 该句要不要单独占一行角色名。只取决于「LLM 有没有认出说话人」，
    /// 不能掺进 audioURL 之类的流式状态：那样音频一到齐，整页高度就变了，
    /// 分页结果却还没重算。
    static func showsLabel(for sentence: Sentence) -> Bool {
        sentence.speaker == .character && sentence.characterName != nil
    }
}

struct PageLayout: Equatable {

    /// `pages[p]` = 第 p 页承载的句子在 `chapter.sentences` 里的下标。
    /// 用数组下标而不是 `Sentence.index`：PlayerManager 也是按数组下标取句子的，
    /// 两边口径一致才不会点到A句播B句。
    let pages: [[Int]]

    let bodySize: CGFloat

    var pageCount: Int { pages.count }

    static let placeholder = PageLayout(pages: [[]], bodySize: 19)

    /// 该句落在第几页。句子比页数「超范围」时（比如刚重排、或播放已推进到
    /// 未渲染的句子）返回最后一页，而不是崩掉。
    func page(containing sentence: Int) -> Int {
        var last = 0
        for (index, page) in pages.enumerated() {
            if let first = page.first, sentence < first {
                return max(index - 1, 0)
            }
            last = index
        }
        return last
    }

    // MARK: - Paginate

    static func paginate(
        _ sentences: [Sentence],
        in area: CGSize,
        scale: Double
    ) -> PageLayout {

        guard area.width > 40, area.height > 40 else {
            return placeholder
        }

        let body = ReaderTypography.bodySize(scale: scale)
        let font = UIFont.systemFont(ofSize: body)
        let indent = ReaderTypography.paragraphIndent(size: body)
        let gap = ReaderTypography.sentenceGap(size: body)

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = ReaderTypography.lineSpacing(size: body)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: paragraph,
        ]

        let textWidth = max(
            area.width - ReaderTypography.horizontalMargin * 2 - indent,
            40
        )
        // 量高用的是 CoreText 的 boundingRect，SwiftUI 的 Text 行高由字体度量
        // 自己算，两者差几个百分点。留 5% 余量，把误差固定朝安全方向偏：
        // 宁可页尾略空，也不要字溢到下一页去（那只能靠滚动兜底）。
        let usableHeight = max(
            (area.height - ReaderTypography.verticalMargin * 2) * 0.95,
            body * 3
        )

        var pages: [[Int]] = []
        var current: [Int] = []
        var used: CGFloat = 0

        for (position, sentence) in sentences.enumerated() {

            let bounds = NSAttributedString(
                string: sentence.text,
                attributes: attributes
            ).boundingRect(
                with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil
            )

            var height = ceil(bounds.height) + gap
            if ReaderTypography.showsLabel(for: sentence) {
                height += ReaderTypography.labelHeight(size: body)
            }

            // 装不下就另起一页。整页装不下一句时让它独占一页：
            // 宁可溢出，也不能反复往空页里塞同一句（那会死循环）。
            if !current.isEmpty, used + height > usableHeight {
                pages.append(current)
                current = []
                used = 0
            }

            current.append(position)
            used += height
        }

        if !current.isEmpty {
            pages.append(current)
        }
        if pages.isEmpty {
            pages.append([])
        }

        return PageLayout(pages: pages, bodySize: body)
    }
}
