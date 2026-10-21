//
//  ModelManifest.swift
//  Reader
//
//  千问两套权重的下载清单：谁在哪个仓库、多大、sha256 是多少、落到哪个目录。
//
//  清单里每个字节数和每个 sha256 都是两侧实测对过的那一份：一侧是本机 `~/Models` 下
//  现在打进 App 的那两个目录（也就是「这样能加载成功」的真相），另一侧是
//  `hf-mirror.com/<repo>/resolve/main/<path>` 实际发出来的内容。13 个走网络的文件里，
//  4 个大权重由 HF 的 tree API 报的 LFS `oid`（就是 sha256）对上，其余 9 个是真下一遍
//  再算 sha256 对上的，全部一致。
//
//  两个来源都是 `Qwen/Qwen3-0.6B-MLX-4bit`、`aitytech/Qwen3-TTS-...-MLX-4bit`、
//  `Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice`（声码 decoder 只在官方那个仓库里）。
//  TTS 的 `tokenizer.json` 三个仓库都没有，所以它走 bundle 复制（见 `Source.appBundle`）。
//

import Foundation

enum ModelID: String, CaseIterable, Equatable, Sendable {
    /// 整书解析：每批句子的情绪与强度标注。
    case qwen3LLM
    /// 本地语音合成后端。
    case qwen3TTS
}

/// 一套权重里要落地的一个文件。
struct ModelFile: Equatable, Sendable {

    enum Source: Equatable, Sendable {
        /// HF 仓库里的路径，从 `resolve/main/` 取。
        case repository(String)
        /// 从 app bundle 里那个 folder reference 复制。
        ///
        /// 只有 TTS 的 `tokenizer.json` 走这一条：4,762,740 字节的这一份不在任何仓库里
        /// （`Qwen/Qwen3-0.6B-MLX-4bit` 那个 11,422,654 字节的是另一把 tokenizer，
        /// 词表不同，不能拿来顶），而加载必须有它。
        case appBundle(folder: String)
    }

    /// 仓库内路径，同时就是模型目录里的相对落地路径——两边同名，省掉一张映射表，
    /// 也让 `speech_tokenizer/` 那种子目录自己长出层级。
    let relativePath: String

    let bytes: Int64

    /// 小写十六进制。
    let sha256: String

    let source: Source

    var fileName: String { (relativePath as NSString).lastPathComponent }

    /// 走网络的那个仓库名；bundle 复制的那一个返回 nil。
    var repository: String? {
        if case .repository(let repo) = source { return repo }
        return nil
    }

    /// 能不能安全落在模型目录里面：不带绝对前缀、不穿 `..`、不是空段。
    /// 清单是写死的常量，这一条判据是给「以后有人改清单」准备的。
    var isPathWithinModelDirectory: Bool {
        !relativePath.isEmpty
            && !relativePath.hasPrefix("/")
            && !relativePath.contains("..")
            && !relativePath.contains("//")
    }

    /// 某个源上这个文件的下载地址。bundle 复制的那一个没有 URL。
    func url(from host: String) -> URL? {
        guard let repository else { return nil }
        let encoded = relativePath
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { segment -> String in
                let text = String(segment)
                return text.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? text
            }
            .joined(separator: "/")
        return URL(string: "\(host)/\(repository)/resolve/main/\(encoded)")
    }
}

/// 一套模型：一个目录、一批文件。
struct ModelSpec: Equatable, Sendable {
    let id: ModelID

    /// 设置页那一行的名字。
    let displayName: String

    /// 这套权重是干什么的（一行，给人看的）。
    let blurb: String

    /// 模型目录名。和拆包前 bundle 里那个 folder reference 逐字相同，
    /// 因为加载方（MLX 的 `loadModel(from:)`、`Qwen3TTSModel.fromPretrained(_:)`）
    /// 只认目录，不认它是从 bundle 来的还是从网络来的。
    let directoryName: String

    let files: [ModelFile]

    /// 要联网下的那部分字节（bundle 复制的不在里面）。
    var downloadBytes: Int64 {
        files.filter { $0.repository != nil }.reduce(0) { $0 + $1.bytes }
    }

    /// 落地以后的总体积。
    var installedBytes: Int64 {
        files.reduce(0) { $0 + $1.bytes }
    }
}

enum ModelManifest {

    /// 依次试的源。官方域名排在前面；镜像留着是因为这台机器上 `huggingface.co` 只有走系统
    /// 代理才通（实测：直连 30 秒 0 字节，经代理 200），代理没开的一方就得靠 `hf-mirror.com`
    /// （实测直连 0.72 秒 200，它只有 A 记录 160.16.86.14，内容由自己那份 resolve-cache 供）。
    static let hosts = [
        "https://huggingface.co",
        "https://hf-mirror.com",
    ]

    static let all: [ModelSpec] = [llm, tts]

    static func spec(_ id: ModelID) -> ModelSpec {
        switch id {
        case .qwen3LLM: return llm
        case .qwen3TTS: return tts
        }
    }

    private static let llm = ModelSpec(
        id: .qwen3LLM,
        displayName: "Qwen3-0.6B 解析模型",
        blurb: "整书解析用它标每句的情绪与强度。不下也能读、也能听，只是标注走正则那一档。",
        directoryName: "Qwen3-0.6B-MLX-4bit",
        files: [
            ModelFile(
                relativePath: "config.json",
                bytes: 988,
                sha256: "0a07b68f1699472c68859db0fe6b46415c3ea1dee4d842216aadc1d2cda2e9c7",
                source: .repository("Qwen/Qwen3-0.6B-MLX-4bit")
            ),
            ModelFile(
                relativePath: "model.safetensors",
                bytes: 316_825_742,
                sha256: "36162e7f72fe3eca308471e55161269e4605ab87d2666ae1f33ef800749c97dd",
                source: .repository("Qwen/Qwen3-0.6B-MLX-4bit")
            ),
            ModelFile(
                relativePath: "model.safetensors.index.json",
                bytes: 49_731,
                sha256: "70b3eb63114d68f40936b2cad3bec174af9c4d85849a88b36f308e8e9dd05ccb",
                source: .repository("Qwen/Qwen3-0.6B-MLX-4bit")
            ),
            ModelFile(
                relativePath: "tokenizer.json",
                bytes: 11_422_654,
                sha256: "aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4",
                source: .repository("Qwen/Qwen3-0.6B-MLX-4bit")
            ),
            ModelFile(
                relativePath: "tokenizer_config.json",
                bytes: 9_689,
                sha256: "a6389dfe64f259c5626a9b7e6d7e5a152bfe2973eae9b20e362bc450fea09239",
                source: .repository("Qwen/Qwen3-0.6B-MLX-4bit")
            ),
            ModelFile(
                relativePath: "vocab.json",
                bytes: 2_776_833,
                sha256: "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910",
                source: .repository("Qwen/Qwen3-0.6B-MLX-4bit")
            ),
            ModelFile(
                relativePath: "merges.txt",
                bytes: 1_671_853,
                sha256: "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5",
                source: .repository("Qwen/Qwen3-0.6B-MLX-4bit")
            ),
        ]
    )

    private static let tts = ModelSpec(
        id: .qwen3TTS,
        displayName: "Qwen3-TTS 语音模型",
        blurb: "选它做语音后端就要下这一套：talker 加声码 decoder，两个模型里的大头。",
        directoryName: "Qwen3-TTS-12Hz-0.6B-CustomVoice-MLX-4bit",
        files: [
            ModelFile(
                relativePath: "config.json",
                bytes: 6_058,
                sha256: "612cb591b44547319e5c68a78c0e93e4defb57882a4aa9ef5f06cc2f071ed036",
                source: .repository("aitytech/Qwen3-TTS-12Hz-0.6B-CustomVoice-MLX-4bit")
            ),
            ModelFile(
                relativePath: "model.safetensors",
                bytes: 1_006_772_520,
                sha256: "4ab02a20be381700f6e73dbb5efdc424cadf9f1d0652cbffd662872ea41e296a",
                source: .repository("aitytech/Qwen3-TTS-12Hz-0.6B-CustomVoice-MLX-4bit")
            ),
            ModelFile(
                relativePath: "model.safetensors.index.json",
                bytes: 71_447,
                sha256: "f3b84ec5c1b38220008c3a300b8a73502f7d4ec67b232e0193d9376909fc4e3e",
                source: .repository("aitytech/Qwen3-TTS-12Hz-0.6B-CustomVoice-MLX-4bit")
            ),
            ModelFile(
                relativePath: "tokenizer_config.json",
                bytes: 7_344,
                sha256: "dc3c31c3bdaedd5016382bb3cbe07323026775ad51f5a4fb564505992ae4a670",
                source: .repository("aitytech/Qwen3-TTS-12Hz-0.6B-CustomVoice-MLX-4bit")
            ),
            ModelFile(
                relativePath: "vocab.json",
                bytes: 2_776_833,
                sha256: "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910",
                source: .repository("aitytech/Qwen3-TTS-12Hz-0.6B-CustomVoice-MLX-4bit")
            ),
            ModelFile(
                relativePath: "merges.txt",
                bytes: 1_671_839,
                sha256: "599bab54075088774b1733fde865d5bd747cbcc7a547c5bc12610e874e26f5e3",
                source: .repository("aitytech/Qwen3-TTS-12Hz-0.6B-CustomVoice-MLX-4bit")
            ),
            // 声码 decoder 只在这套权重的官方仓库里；talker 的 4bit 版是别人转的。
            ModelFile(
                relativePath: "speech_tokenizer/config.json",
                bytes: 2_336,
                sha256: "ee65bb901c876664ab8707c487157aa1a6ee57c65969b28fb5ec9dc211e68167",
                source: .repository("Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice")
            ),
            ModelFile(
                relativePath: "speech_tokenizer/configuration.json",
                bytes: 76,
                sha256: "6bc26d64eb5024b4d1dab5a52371958b429256d6c9d59787f1f5294a54e0cebd",
                source: .repository("Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice")
            ),
            ModelFile(
                relativePath: "speech_tokenizer/model.safetensors",
                bytes: 682_293_092,
                sha256: "836b7b357f5ea43e889936a3709af68dfe3751881acefe4ecf0dbd30ba571258",
                source: .repository("Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice")
            ),
            ModelFile(
                relativePath: "speech_tokenizer/preprocessor_config.json",
                bytes: 234,
                sha256: "fcb3805e597e786d4067706e602f6688524640f8d3396790e2e09b5942fcbdfb",
                source: .repository("Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice")
            ),
            ModelFile(
                relativePath: "tokenizer.json",
                bytes: 4_762_740,
                sha256: "b8d386f01d4880367a273b269519dd3ed22519577912296c608d89065d77bb61",
                source: .appBundle(folder: "Qwen3TTSTokenizer")
            ),
        ]
    )
}
