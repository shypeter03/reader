//
//  Emotion.swift
//  Reader
//
//  Created by 粟海洋 on 2026/8/26.
//

import Foundation

enum Emotion: String, Codable, Sendable {
    case neutral
    case happy
    case sad
    case angry
    case surprised
    case fearful
    case excited
    case calm
    case tense
}

/// 各情绪的推荐目标参数。LLM 输出缺失/非法时的兜底、正则标注的起点、
/// CustomVoice instruct 的描述都读这一份，避免三处表格各说各话。
extension Emotion {

    /// 情绪强度的兜底默认（中性叙述不必用力）。
    var defaultIntensity: Double {
        0.5
    }

    /// 整句目标语速，范围 0.7...1.3。
    var defaultSpeed: Double {
        switch self {
        case .neutral: return 1.00
        case .calm: return 0.93
        case .sad: return 0.92
        case .happy: return 1.06
        case .excited: return 1.13
        case .angry: return 1.08
        case .surprised: return 1.08
        case .fearful: return 1.00
        case .tense: return 1.06
        }
    }

    /// 整句目标音调偏移，范围 -0.2...0.2。
    /// 注意：负值只代表音调略低，不代表音量小。
    var defaultPitch: Double {
        switch self {
        case .neutral: return 0.00
        case .calm: return -0.03
        case .sad: return -0.07
        case .happy: return 0.08
        case .excited: return 0.12
        case .angry: return 0.03
        case .surprised: return 0.12
        case .fearful: return 0.02
        case .tense: return 0.03
        }
    }

    /// 整句目标声音力度（0...1）：声音有多饱满、有支撑。
    /// 与 defaultIntensity 是两个独立维度——克制的情绪不等于虚弱的声音，
    /// 所以这里没有任何一档低于 0.75。
    var defaultVoiceStrength: Double {
        switch self {
        case .neutral: return 0.80
        case .calm: return 0.80
        case .sad: return 0.80
        case .happy: return 0.85
        case .angry: return 0.95
        case .surprised: return 0.90
        case .fearful: return 0.75
        case .excited: return 0.90
        case .tense: return 0.85
        }
    }
}
