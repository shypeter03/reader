//
//  TTSEngineType.swift
//  Reader
//
//  三套 TTS 后端的身份：显示名、UserDefaults 里存的那一个、各自的磁盘缓存子目录。
//
//  「选哪个」只是**顺位**：``FallbackTTSService`` 把选中的那个挪到链首，剩下两个按
//  `edge → kokoro → qwen` 的相对次序接着排，前一个抛错就轮到后一个。所以这一份只管身份，
//  不管「谁在跑、跑不了怎么办」——那都在外层。
//
//  换这里不需要重启 App：外层每句重读一次 `current`。
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
        case .edge: return "Edge TTS（在线，默认：合成快、不占内存）"
        case .sherpaKokoro: return "Kokoro（本地 sherpa-onnx，离线可用）"
        case .qwen3: return "Qwen3-TTS（本地 MLX，音质更好，但慢且吃内存）"
        }
    }

    /// 没显式设置过的用户走 Edge：它不出声时链条自己往后走。
    static var current: TTSEngineType {
        guard let raw = UserDefaults.standard.string(forKey: storageKey),
              let value = TTSEngineType(rawValue: raw) else {
            return .edge
        }
        return value
    }

    /// 这个后端的音频落在 `{书}/{章}/` 下哪个子目录；nil = Qwen3 的平铺老路径（一个字不改它）。
    ///
    /// 缓存键只有「书/章/句」，不含声音也不含后端，所以**每个后端各占一个目录**是必要的：
    /// 共用的话换了后端旧音频照样命中，表现就是「换了个寂寞」。
    /// 反过来，读缓存要按顺位把几个目录都问一遍（见 ``FallbackTTSService/cacheNamespaces()``），
    /// 换后端才不至于把整本书重录一遍。
    var audioNamespace: String? {
        switch self {
        case .edge: return EdgeTTSService.audioNamespace
        case .sherpaKokoro: return SherpaKokoroTTSService.audioNamespace
        case .qwen3: return nil
        }
    }

    /// 这一格会不会往 Metal 里提交推理。后台提交 GPU 会崩（见 `AppBackgroundGate`），
    /// 所以「进后台要不要停掉语音合成」由它决定：Edge 走网络、Kokoro 走 CPU 都能继续，
    /// 只有 Qwen3-TTS（MLX）必须停。
    var submitsToGPU: Bool { self == .qwen3 }

    /// 这句音频当初由**哪个后端**合成——从落盘路径反推，不新增字段。
    ///
    /// 「谁出的声」本来就是声音身份的一部分（`voiceID` 三个后端共用同一套名字，但它们翻译
    /// 出来的嗓门完全不同：Uncle_Fu 在 Edge 是 YunyangNeural，在 Kokoro 是 zm_098），
    /// 而缓存键只有书/章/句，所以这一层信息只剩在 `{书}/{章}/` 下面那个子目录名里。
    /// 不这样也查不回来：`recordedVoiceID` 存的是名字，降级那几句记的同样是那个人。
    ///
    /// - Note: 认不出来（路径不是这两层形状）就返回 nil，调用方按「不知道」放过，别删。
    static func backend(ofAudioAt url: URL) -> TTSEngineType? {
        let parent = url.deletingLastPathComponent().lastPathComponent
        if let match = allCases.first(where: { $0.audioNamespace == parent }) { return match }
        // Qwen3 是老平铺形状：句子直接住在以 chapterID 命名的目录里，没有子目录这一层。
        return UUID(uuidString: parent) != nil ? .qwen3 : nil
    }
}
