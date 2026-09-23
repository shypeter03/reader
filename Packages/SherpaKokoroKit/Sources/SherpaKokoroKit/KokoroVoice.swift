//
//  KokoroVoice.swift
//  SherpaKokoroKit
//

import Foundation

/// Kokoro 的说话人性别。直接来自 Kokoro 官方 voice 命名约定
/// （`zf_` = 中文女声，`zm_` = 中文男声，`af_/am_` = 美音女/男……），不是推测。
public enum KokoroVoiceGender: String, Sendable {
    case female
    case male
    case unknown
}

/// Kokoro 的说话人 = 一个整数 sid + 官方声音名。
///
/// 与 Qwen3-TTS 的 speaker 体系完全无关：Qwen3 用 `config.json` 里的 spk_id 名字
/// （Vivian / Ryan / Uncle_Fu…）+ 自然语言 instruct，Kokoro 只有一个 `sid`
/// 索引，没有任何 instruction 接口。
///
/// - Important: **不要**在这里写死任何 sid 表。v1_0 与 v1_1 的声音数量和顺序都不同
///   （v1_0 的 sid 52 是男声 `zm_yunyang`，v1_1 的 sid 52 是女声 `zf_088`），
///   写死会在换模型时静默换嗓。实例一律来自 ``KokoroTTSEngine/voices``
///   （由 ``KokoroSpeakerTable`` 从模型 metadata 解析）。
public struct KokoroVoice: Hashable, Sendable {

    /// 传给 sherpa-onnx `GenerationConfig.sid` 的索引。
    public let sid: Int

    /// 模型 metadata 里的官方声音名。日志、按名挑选、跨模型核对都靠它。
    public let name: String

    public let gender: KokoroVoiceGender

    /// Kokoro 语言前缀（名字首字母）：z=中文, a=美音, b=英音, e=西语,
    /// f=法语, h=印地, i=意语, j=日语, p=葡语。
    public let languagePrefix: Character

    public init(sid: Int, name: String) {
        self.sid = sid
        self.name = name
        let letters = Array(name)
        self.languagePrefix = letters.first ?? "?"
        self.gender =
            letters.count > 1
            ? (letters[1] == "f" ? .female : letters[1] == "m" ? .male : .unknown)
            : .unknown
    }

    /// 中文声音：`zf_`/`zm_` 前缀。英文声音读小说里的中文人名会跑调。
    public var isChinese: Bool {
        languagePrefix == "z" && gender != .unknown
    }

    /// 把 ``KokoroSpeakerTable`` 读出来的名字列表变成 sid 表（下标即 sid）。
    public static func table(from names: [String]) -> [KokoroVoice] {
        names.enumerated().map { KokoroVoice(sid: $0.offset, name: $0.element) }
    }
}

// MARK: - Table helpers

extension Array where Element == KokoroVoice {

    /// 只保留中文声音。
    public var chinese: [KokoroVoice] { filter(\.isChinese) }

    public func chinese(gender: KokoroVoiceGender) -> [KokoroVoice] {
        filter { $0.isChinese && $0.gender == gender }
    }

    /// 按优先级列表挑声音：第一个在当前模型里存在的就用它。
    ///
    /// 这样同一份代码在 v1_0（有 `zm_yunyang`）和 v1_1（只有编号名）上都能拿到
    /// 合理的旁白，而不是在 v1_1 上退回到 sid 0 的英文女声。
    public func first(named preferred: [String]) -> KokoroVoice? {
        for name in preferred {
            if let voice = first(where: { $0.name == name }) { return voice }
        }
        return nil
    }

    /// 按稳定 key 从池子里挑一个声音：同一个 key 永远同一把嗓子，不同 key 尽量分散。
    /// 角色身份（characterID / 上游解析出的 speaker 名）就是这个 key。
    ///
    /// 只用字符串哈希、不依赖数组下标，所以章节重载、换模型顺序变化都不会让
    /// 角色当场换声（换模型时音色本身会变，但至少不是「随机换个性别」）。
    public func stableVoice(for key: String) -> KokoroVoice? {
        guard !isEmpty else { return nil }
        // 自己实现 FNV-1a：Swift 的 hashValue 每次进程启动加随机种子，
        // 用它做角色分配会让同一角色下次启动换声音。
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return self[Int(hash % UInt64(count))]
    }
}
