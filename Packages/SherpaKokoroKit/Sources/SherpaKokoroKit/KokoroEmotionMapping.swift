//
//  KokoroEmotionMapping.swift
//  SherpaKokoroKit
//

import Foundation

/// 上层标注的情绪 -> Kokoro 实际能做的调节。
///
/// **这是一份「有限映射」，不是情绪控制。** sherpa-onnx 的 Kokoro 只暴露
/// `sid` / `speed` / `silence_scale`，没有 instruct、没有情感 embedding、
/// 没有 pitch、没有音量力度。所以这里唯一真正生效的量是语速。
///
/// 刻意不做的几件事，避免上层误以为它们有用：
/// - 不把 `voiceStrength` 映射成音量增益：把整句压小音量正是 Qwen3 侧
///   「句尾泄气」的成因，Kokoro 也没有逐句增益入口；
/// - 不把 `pitch` 映射成 anything：没有这个接口；
/// - 不因为 sad/tense 就换 voice：换嗓子等于换人。
///
/// rawValue 与 Reader 的 `Emotion` 枚举字面量一致，靠字符串对接，
/// 包本身不依赖 app 类型。
public enum KokoroEmotion: String, CaseIterable, Sendable {

    case neutral
    case happy
    case sad
    case angry
    case surprised
    case fearful
    case excited
    case calm
    case tense

    /// 只调语速，幅度刻意小：Kokoro 的韵律由权重自己决定，语速偏移一大
    /// 就容易听着不像同一个人在读。
    public var speedDelta: Double {
        switch self {
        case .neutral: return 0
        case .calm: return -0.04
        case .sad: return -0.06
        case .happy: return 0.05
        case .excited: return 0.10
        case .angry: return 0.06
        case .surprised: return 0.06
        case .fearful: return 0.04
        case .tense: return 0.04
        }
    }

    /// 把情绪叠加到标注语速上，并夹到 Kokoro 后端的可用区间。
    public func applySpeed(_ base: Double) -> Double {
        Double(KokoroConfiguration.clampedSpeed(base + speedDelta))
    }
}
