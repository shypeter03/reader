//
//  TTSEngineType.swift
//  Reader
//
//  TTS 后端选择。**当前默认是 Kokoro（sherpa-onnx）**：轻、快、省内存。
//  Qwen3-TTS 仍然完整保留，在设置里显式选回来即可。
//  切换需要重启 App 生效——ReaderContainer 是进程内单例，组合根只在启动时跑一次。
//

import Foundation

enum TTSEngineType: String, CaseIterable, Sendable {

    case sherpaKokoro
    case qwen3

    /// 与 SettingsView 里 `@AppStorage` 的键保持一致（改名字要一起改）。
    static let storageKey = "ttsEngineType"

    var displayName: String {
        switch self {
        case .sherpaKokoro: return "Kokoro（sherpa-onnx，默认：轻快省内存）"
        case .qwen3: return "Qwen3-TTS（音质更好，但慢且吃内存）"
        }
    }

    /// 未显式设置过的用户走 Kokoro；模型没装时 ReaderContainer 会退回 Qwen3。
    static var current: TTSEngineType {
        guard let raw = UserDefaults.standard.string(forKey: storageKey),
              let value = TTSEngineType(rawValue: raw) else {
            return .sherpaKokoro
        }
        return value
    }

    var usesKokoro: Bool { self == .sherpaKokoro }
}
