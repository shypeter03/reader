//
//  ReaderTheme.swift
//  Reader
//
//  纸色与墨色：五档主题，外加卷页那层 UIKit 要的动态色。
//  属于渲染端——排版内核不算颜色，改字色不该让页重排。
//

import SwiftUI
import UIKit

/// 阅读主题：底色 + 字色。
///
/// 颜色刻意**不进**分页测量——它一个像素都不影响行高，进去只会让「改了颜色页就跳」
/// 这类bug 有藏身地方。要调疏密走 `ReaderTypography.lineSpacing`，那条才参与。
enum ReaderTheme: String, CaseIterable, Identifiable {

    case paper
    case cream
    case sepia
    case night
    case system

    static let storageKey = "readerTheme"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .paper: return "宣纸"
        case .cream: return "米黄"
        case .sepia: return "羊皮"
        case .night: return "夜间"
        case .system: return "跟随"
        }
    }

    /// 底色的两份 RGB：浅色一套、深色一套。固定档两边给同一个值，只有「跟随」真的分家。
    /// `background`（SwiftUI）和 `uiBackground`（UIKit）都从这里出，
    /// 免得改了纸色忘了卷页那张纸。
    private var backgroundRGB: (
        light: (Double, Double, Double),
        dark: (Double, Double, Double)
    ) {
        switch self {
        case .paper: return ((0.99, 0.99, 0.98), (0.99, 0.99, 0.98))
        case .cream: return ((0.96, 0.94, 0.87), (0.96, 0.94, 0.87))
        case .sepia: return ((0.93, 0.87, 0.76), (0.93, 0.87, 0.76))
        case .night: return ((0.08, 0.08, 0.10), (0.08, 0.08, 0.10))
        case .system: return ((0.99, 0.99, 0.98), (0.07, 0.07, 0.09))
        }
    }

    var background: Color {
        Color(uiColor: uiBackground)
    }

    /// 同一份纸色的 UIColor 版。卷页那层是 UIKit（`UIPageViewController` 和它缓存的
    /// `UIHostingController.view`），只认 UIColor：喂不进 Color，纸就是白的——
    /// 深色模式下翻起页来一张亮纸，正是用户报的那个样子。
    var uiBackground: UIColor {
        let rgb = backgroundRGB
        return UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? rgb.dark : rgb.light
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        }
    }

    var text: Color {
        switch self {
        case .paper: return Color(red: 0.13, green: 0.13, blue: 0.14)
        case .cream: return Color(red: 0.22, green: 0.20, blue: 0.15)
        case .sepia: return Color(red: 0.29, green: 0.22, blue: 0.13)
        case .night: return Color(red: 0.80, green: 0.80, blue: 0.83)
        case .system: return adaptive(
            light: (0.13, 0.13, 0.14),
            dark: (0.85, 0.85, 0.88)
        )
        }
    }

    /// 这一档纸在视觉上属于哪套外观——卷页那层（UIKit）照着它把 traits 钉死。
    ///
    /// 为什么不由系统外观裸决定：`uiBackground` 是动态色，取值要看宿主视图的
    /// traits，而翻页的纸是缓存里的 `UIHostingController`，脱离视图树时系统从浅
    /// 切深它收不到更新——表现就是「底色已经黑了，翻起来那张纸还是亮的」。
    /// 另一层：夜间档配系统浅色时，页眉那些 `.secondary` 语义色会解成深灰，
    /// 落在深纸上就是看不见。固定档自己说死深浅，「跟随」才把决定权交回系统。
    /// 判据和 `backgroundRGB` 同一份：那里只有 `.system` 真的分了 light/dark 两套纸。
    func userInterfaceStyle(
        matching systemStyle: UIUserInterfaceStyle
    ) -> UIUserInterfaceStyle {
        switch self {
        case .paper, .cream, .sepia: return .light
        case .night: return .dark
        case .system: return systemStyle
        }
    }

    /// 由系统 traits 现算的颜色。
    ///
    /// 不用 `@Environment(\.colorScheme)` 在读的地方判断：那样每个用到 theme 的视图
    /// 都得自己接一遍环境值，漏一处就是「切深色了正文还是白底」。
    private func adaptive(
        light: (Double, Double, Double),
        dark: (Double, Double, Double)
    ) -> Color {
        Color(
            uiColor: UIColor { traits in
                let c = traits.userInterfaceStyle == .dark ? dark : light
                return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
            }
        )
    }

    /// 没在播的句子淡一档。用透明度而不是换个颜色：主题给的字色只有一种，
    /// 淡档跟着它走，夜间模式才不会出现「黑底上一片灰字看不见」。
    var inactiveOpacity: Double { 0.72 }
}