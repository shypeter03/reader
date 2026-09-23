//
//  KokoroTTSError.swift
//  SherpaKokoroKit
//

import Foundation

/// Kokoro 后端的错误。上层（Reader）用它区分「模型没装」和「合成失败」：
/// 前者只是功能不可用，绝不能拖垮整个 App。
public enum KokoroTTSError: Error, Sendable {

    /// 在所有候选目录里都没找到 Kokoro 模型。
    case modelNotFound(searched: [String])

    /// 找到了目录但组件不齐（比如只下载了一半）。
    case incompleteModel(directory: String, missing: [String])

    /// sherpa-onnx 自己创建引擎失败（权重损坏、算子不支持等）。
    case engineCreateFailed(directory: String)

    /// 还没 load() 就调用 generate()。
    case engineNotLoaded

    /// sid 超出模型实际支持的说话人数量。
    case invalidVoice(sid: Int, speakerCount: Int)

    /// 传进来的 voice 名字与当前模型在该 sid 上的声音不一致。
    ///
    /// 典型场景：代码里写死了 v1_0 的 `zm_yunyang`（sid 52），实际加载的却是
    /// v1_1（sid 52 = 女声 `zf_088`）。这种错位**不会越界**，只能靠名字校验拦住。
    case speakerNameMismatch(sid: Int, expected: String, given: String)

    /// 模型 ONNX 里没有可用的 sid→声音名表。宁可不合成，也不猜一张表。
    case speakerTableUnavailable(modelFile: String)

    /// metadata 里的声音条数与 sherpa-onnx 报的说话人数不一致（模型被改过或下坏了）。
    case speakerTableMismatch(metadataCount: Int, engineCount: Int)

    /// 引擎返回了空音频（文本被全部规范化掉了，或者只有标点）。
    case emptyAudio(text: String)
}

extension KokoroTTSError: CustomStringConvertible {
    public var description: String {
        switch self {

        case .modelNotFound(let searched):
            return "Kokoro 模型未安装。已在以下位置查找: \(searched.joined(separator: ", "))。"
                + "下载 \(KokoroModelLocator.releaseURL.absoluteString) 里的 "
                + "\(KokoroModelLocator.preferredDirectoryName).tar.bz2，"
                + "以 folder reference 方式挂进工程（与 Qwen3-TTS 一样，构建时才拷进 App），"
                + "或放到 \(KokoroModelLocator.externalDirectoryNameHint) 后重启。"

        case .incompleteModel(let directory, let missing):
            return "Kokoro 模型不完整（\(directory)）：缺少 \(missing.joined(separator: "、"))。"

        case .engineCreateFailed(let directory):
            return "sherpa-onnx 创建 Kokoro 引擎失败（\(directory)）。请检查 model.onnx 是否完整。"

        case .engineNotLoaded:
            return "Kokoro 引擎尚未加载，请先调用 load()。"

        case .invalidVoice(let sid, let speakerCount):
            return "Kokoro voice sid \(sid) 越界：该模型只有 \(speakerCount) 个说话人。"

        case .speakerNameMismatch(let sid, let expected, let given):
            return "Kokoro sid \(sid) 在当前模型里是「\(expected)」，代码却传了「\(given)」。"
                + "sid 表必须来自加载后的模型（KokoroTTSEngine.voices），v1_0 与 v1_1 的编号不通用。"

        case .speakerTableUnavailable(let modelFile):
            return "Kokoro 模型 \(modelFile) 里没有 speaker_names/id2speaker 元数据，"
                + "无法确定 sid 对应哪把声音。这里不用任何默认表兜底，以免静默换声。"

        case .speakerTableMismatch(let metadataCount, let engineCount):
            return "Kokoro sid 表不一致：metadata 写了 \(metadataCount) 把声音，"
                + "sherpa-onnx 报 \(engineCount) 个说话人。模型文件可能被改动或未下载完整。"

        case .emptyAudio(let text):
            return "Kokoro 返回空音频：\"\(text.prefix(20))\""
        }
    }
}

/// 让 UI 直接 `error.localizedDescription` 就拿到人话（例如
/// 「Kokoro TTS 模型未安装」），而不是系统占位文案。
/// 声明在本包内，避免宿主 App 做追溯协议 conformance。
extension KokoroTTSError: LocalizedError {
    public var errorDescription: String? { description }
}
