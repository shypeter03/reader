//
//  ReaderPageText.swift
//  Reader
//
//  纸面渲染：把内核算好的 `Run` 摊成 SwiftUI 认的 `AttributedString`。
//
//  从 `ReaderBlock` 搬出来只为一条：内核不碰颜色、不碰 SwiftUI 的字体。断行、
//  补齐、量高都在 `Reader/Engine/ReaderBlock.swift`，这里照着它的 `layout` 上色，
//  两边共用同一个 `width`——否则量的是一版、排的是一版，页尾就溢出。
//

import SwiftUI

extension ReaderBlock {

    static func font(
        _ run: Run,
        body: CGFloat
    ) -> Font {

        switch weight(run) {
        case .regular: return .system(size: body)
        case .semibold: return .system(size: body, weight: .semibold)
        }
    }
    /// 渲染用的串。颜色由调用方逐句给（把上色写进测量端只会让「改了字色页就跳」）。
    ///
    /// `width` 是版心宽，用来算硬换行的落点——**必须和 `height` 拿到的是同一个数**，
    /// 否则量的是一版、排的是一版，页尾就溢出了。
    ///
    /// 每句一个 `link` run 是给点读定位用的。注意副作用：SwiftUI 不肯在两个 link 域
    /// 之间断行，所以「一句能不能和上一句挤在同一行」在这里和测量端必须算同一种——
    /// 测量端靠句界插零宽 U+2060 对齐，见 `height`。
    ///
    /// 每句一个 `link` run 是给点读定位用的：并成一块以后「点到哪一句」不再是哪个
    /// `Text` 被点了，只能靠 run。探针实测：run 上显式给的前景色不会被链接色盖掉，
    /// 也不会画下划线，所以「当前句上色、其余淡一档」照旧成立。
    static func attributedString(
        runs: [Run],
        body: CGFloat,
        width: CGFloat,
        color: (Run) -> Color
    ) -> AttributedString {

        var result = AttributedString()

        for piece in layout(runs: runs, width: width, body: body) {

            let run = runs[piece.runIndex]

            var part = AttributedString(piece.text)

            part.font = font(run, body: body)

            // 两端对齐摊开的那点字距。`layout` 每格最多补 `ReaderBlock.justifyGapCap` 字宽，
            // 补不平就让它空着；无论补没补齐，那道「按落纸行回炉」的闸都担保这一行还是
            // 只占一行——所以这里画出来的和 `height` 量到的是同一版。
            if piece.kern > 0 { part.kern = Double(piece.kern) }

            part[AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self] = color(run)

            part.link = URL(string: "reader://sentence/\(run.position)")

            result.append(part)
        }

        return result
    }
}
