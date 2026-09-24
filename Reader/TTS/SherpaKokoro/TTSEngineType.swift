//
//  TTSEngineType.swift
//  Reader
//
//  TTS 后端选择。**当前默认是 Edge TTS（在线，合成首选）**：单句出得快，且不在进程里
//  压权重（Kokoro / Qwen3 都要常驻几百 MB～GB）。它在本地仍留一条兜底：Edge 连续失败时
//  由 Kokoro 接手（见 ``FallbackTTSService``）。
//  Kokoro 与 Qwen3-TTS 都完整保留，在设置里显式选回即可。
//  切换需要重启 App 生效——ReaderContainer 是进程内单例，组合根只在启动时跑一次。
//

import Foundation

enum TTSEngineType: String, CaseIterable, Sendable {

    case edge
    case sherpaKokoro
    case qwen3

    /// 与 SettingsView 里 `@AppStorage` 的键保持一致（改名字要一起改）。
    static let storageKey = "ttsEngineType"

    var displayName: String {
        switch self {
        case .edge: return "Edge TTS（在线，默认：合成快、不占内存，失败时 Kokoro 兜底）"
        case .sherpaKokoro: return "Kokoro（本地 sherpa-onnx，离线可用）"
        case .qwen3: return "Qwen3-TTS（音质更好，但慢且吃内存）"
        }
    }

    /// 未显式设置过的用户走 Edge；它不通时降级链自己会转到 Kokoro，
    /// 所以这里不需要像 Kokoro 那样先检查模型在不在。
    static var current: TTSEngineType {
        guard let raw = UserDefaults.standard.string(forKey: storageKey),
              let value = TTSEngineType(rawValue: raw) else {
            return .edge
        }
        return value
    }

    var usesKokoro: Bool { self == .sherpaKokoro }
}
