//
//  KokoroConfiguration.swift
//  SherpaKokoroKit
//

import Foundation

// MARK: - Model Files

/// 一个 Kokoro 模型目录里 sherpa-onnx 实际需要的文件。
///
/// 语言路由靠 `lexicon`：Kokoro >= v1.0 用 `lexicon-zh.txt` 做中文 G2P，
/// 英文走 `espeak-ng-data`。C 层那个 `lang` 字段对中文没有可用取值
/// （官方列的是 en/es/fr/hi/it/pt-br），官方中英文示例里也留空，
/// 所以我们不传 `lang`，避免伪造一个不存在的开关。
public struct KokoroModelFiles: Sendable {

    public let directory: URL
    public let model: URL
    public let voices: URL
    public let tokens: URL
    public let espeakData: URL
    public let lexicons: [URL]
    public let ruleFSTS: [URL]

    /// - Throws: ``KokoroTTSError/incompleteModel(directory:missing:)``
    public init(directory: URL, fileManager fm: FileManager = .default) throws {

        self.directory = directory

        let entries = (try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [])) ?? []

        func file(_ name: String) -> URL? {
            entries.first { $0.lastPathComponent == name }
        }

        func directoryExists(_ name: String) -> URL? {
            let url = directory.appendingPathComponent(name, isDirectory: true)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
                return nil
            }
            return url
        }

        var missing: [String] = []

        // int8 发布叫 model.int8.onnx，fp32 叫 model.onnx；都不满足时退到目录里
        // 唯一的 *.onnx，仍然找不到就报错，不猜路径。
        let model =
            [ "model.onnx", "model.int8.onnx", "model_int8.onnx", "model.fp32.onnx" ]
                .compactMap(file).first
            ?? entries.filter { $0.pathExtension == "onnx" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }.first
        if model == nil { missing.append("model.onnx") }

        let voices = file("voices.bin")
        if voices == nil { missing.append("voices.bin") }

        let tokens = file("tokens.txt")
        if tokens == nil { missing.append("tokens.txt") }

        let espeak = directoryExists("espeak-ng-data")
        if espeak == nil { missing.append("espeak-ng-data/") }

        let lexicons = [ "lexicon-zh.txt", "lexicon-us-en.txt", "lexicon-gb-en.txt" ]
            .compactMap(file)
        if lexicons.isEmpty { missing.append("lexicon-zh.txt / lexicon-us-en.txt") }

        guard let model, let voices, let tokens, let espeak else {
            throw KokoroTTSError.incompleteModel(directory: directory.path, missing: missing)
        }

        self.model = model
        self.voices = voices
        self.tokens = tokens
        self.espeakData = espeak
        self.lexicons = lexicons
        self.ruleFSTS = entries
            .filter { $0.pathExtension == "fst" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

// MARK: - Model Locator

/// Kokoro 模型目录解析。
///
/// 与 Qwen3-TTS 的解析逻辑完全无关，但**集成方式一致**：权重放在仓库之外
/// （`~/Models/…`），工程里只放一个 folder reference，构建时由 Xcode 拷进 .app。
/// 所以这里先查 app bundle（真机上只有这条路），再查磁盘目录（macOS 自测、
/// 以及不想重新打包就换模型的场景）。
public enum KokoroModelLocator {

    /// sherpa-onnx 官方发布目录名，第一个就是 Reader 当前用的模型。
    ///
    /// v1_1（Kokoro v1.1-zh，103 把声音、中文是 `zf_001`…`zm_100` 编号名）优先；
    /// v1_0（54 把声音、`zm_yunyang` 这类名字）继续兼容——但两者的 sid 完全不同，
    /// 声音一律按名字从模型 metadata 里解析（见 ``KokoroSpeakerTable``），
    /// 所以换目录不会换错嗓子。
    public static let defaultDirectoryNames = [
        "kokoro-int8-multi-lang-v1_1",
        "kokoro-int8-multi-lang-v1_0",
        "kokoro-multi-lang-v1_1",
        "kokoro-multi-lang-v1_0",
        "kokoro",
    ]

    /// 提示文案用的「当前应该装哪一个」。
    public static var preferredDirectoryName: String { defaultDirectoryNames[0] }

    public static let releaseURL = URL(
        string: "https://github.com/k2-fsa/sherpa-onnx/releases/tag/tts-models")!

    /// 手动放置模型时该放哪儿（iOS 沙盒没有 `~/Models`，Documents 是等价位置）。
    public static var externalDirectoryNameHint: String {
        #if os(iOS)
        return "App 的 Documents/Models/（用「文件」App 拖进去）"
        #else
        return "~/Models/"
        #endif
    }

    /// 环境变量覆盖：自测入口和换机器时不用改代码。
    public static let environmentKeys = [
        "SHERPA_KOKORO_MODEL_DIR",
        "KOKORO_MODEL_DIR",
    ]

    /// app bundle 里的 folder reference 副本（构建时拷进来的那个目录）。
    public static func bundleCandidates(bundle: Bundle = .main) -> [URL] {
        guard let resources = bundle.resourceURL else { return [] }
        return defaultDirectoryNames.map {
            resources.appendingPathComponent($0, isDirectory: true)
        }
    }

    /// 全部候选（含不存在的），既用于查找也用于「模型未安装」的提示文案。
    public static func candidateDirectories(
        env: [String: String] = ProcessInfo.processInfo.environment,
        fileManager fm: FileManager = .default
    ) -> [URL] {

        var candidates: [URL] = []

        for key in environmentKeys {
            if let raw = env[key], !raw.isEmpty {
                candidates.append(
                    URL(fileURLWithPath: (raw as NSString).expandingTildeInPath,
                        isDirectory: true))
            }
        }

        // 打包进 App 的权重优先：真机上这是唯一稳定存在的一份。
        candidates.append(contentsOf: bundleCandidates())

        let fallbackHome: URL?
        #if os(macOS)
        fallbackHome = fm.homeDirectoryForCurrentUser
        #else
        fallbackHome = fm.urls(for: .documentDirectory, in: .userDomainMask).first
        #endif

        if let home = fallbackHome {
            for name in defaultDirectoryNames {
                candidates.append(home
                    .appendingPathComponent("Models", isDirectory: true)
                    .appendingPathComponent(name, isDirectory: true))
            }
        }

        // iOS 沙盒里用户能放文件的另外两个位置。
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let documents = fm.urls(for: .documentDirectory, in: .userDomainMask).first

        for base in [support, documents] {
            guard let base else { continue }
            for name in defaultDirectoryNames {
                candidates.append(base
                    .appendingPathComponent("models", isDirectory: true)
                    .appendingPathComponent(name, isDirectory: true))
                candidates.append(base.appendingPathComponent(name, isDirectory: true))
            }
        }

        return candidates
    }

    /// 第一个存在且组件齐全的目录。
    public static func resolveKokoroModelDirectory(
        env: [String: String] = ProcessInfo.processInfo.environment,
        fileManager fm: FileManager = .default
    ) throws -> URL {

        let candidates = candidateDirectories(env: env, fileManager: fm)
        var firstIncomplete: (String, [String])?

        for url in candidates {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            do {
                return try KokoroModelFiles(directory: url, fileManager: fm).directory
            } catch let KokoroTTSError.incompleteModel(path, missing) {
                if firstIncomplete == nil { firstIncomplete = (path, missing) }
            } catch {
                continue
            }
        }

        if let (path, missing) = firstIncomplete {
            throw KokoroTTSError.incompleteModel(directory: path, missing: missing)
        }

        throw KokoroTTSError.modelNotFound(searched: candidates.map(\.path))
    }
}

// MARK: - Configuration

public struct KokoroConfiguration: Sendable {

    public enum Language: String, Sendable {
        case zh
        case en
    }

    public var modelFiles: KokoroModelFiles
    public var language: Language

    /// ONNX Runtime 推理线程数。Kokoro 只有 82M 参数，CPU 上加线程有收益，
    /// 但会和同机其它推理（Reader 里是 LLM 分析）抢核，所以交给上层显式指定。
    public var numThreads: Int

    /// 默认语速。sherpa-onnx 的 `speed` 是真参数：>1 更快，<1 更慢。
    public var defaultSpeed: Float

    /// 朗读用默认值即可，留出来方便调停顿。
    public var silenceScale: Float

    /// 是否把模型目录里的 *.fst（number-zh/date-zh/phone-zh）作为文本规范化规则
    /// 传下去。读小说时数字、日期按中文念靠它。
    public var usesTextNormalizationRules: Bool

    /// sherpa-onnx 自己的调试日志开关。
    public var debug: Bool

    public init(
        modelFiles: KokoroModelFiles,
        language: Language = .zh,
        numThreads: Int = KokoroConfiguration.recommendedThreadCount,
        defaultSpeed: Float = 1.0,
        silenceScale: Float = 0.2,
        usesTextNormalizationRules: Bool = true,
        debug: Bool = false
    ) {
        self.modelFiles = modelFiles
        self.language = language
        self.numThreads = max(1, numThreads)
        self.defaultSpeed = KokoroConfiguration.clampedSpeed(defaultSpeed)
        self.silenceScale = silenceScale
        self.usesTextNormalizationRules = usesTextNormalizationRules
        self.debug = debug
    }

    /// 从默认候选目录构造（找不到就抛 ``KokoroTTSError``）。
    public static func automatic(
        language: Language = .zh,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> KokoroConfiguration {
        let dir = try KokoroModelLocator.resolveKokoroModelDirectory(env: env)
        return KokoroConfiguration(
            modelFiles: try KokoroModelFiles(directory: dir),
            language: language
        )
    }

    // MARK: Speed

    /// Reader 侧语速范围（与 Qwen3 的标注值域一致），底层再夹一次。
    public static let minimumSpeed: Float = 0.7
    public static let maximumSpeed: Float = 1.3

    public static func clampedSpeed(_ speed: Double) -> Float {
        clampedSpeed(Float(speed))
    }

    public static func clampedSpeed(_ speed: Float) -> Float {
        min(max(speed, minimumSpeed), maximumSpeed)
    }

    public static var recommendedThreadCount: Int {
        // 留一半核给 UI / 播放 / 分析，避免合成时把前台饿死。
        max(1, min(4, ProcessInfo.processInfo.activeProcessorCount / 2))
    }

    /// 传给 C 层 `lexicon` 的逗号分隔列表。中文模型必须带 lexicon-zh.txt，
    /// 否则汉字没有 G2P 来源。
    public var lexiconArgument: String {
        let urls: [URL]
        switch language {
        case .zh:
            // 中英混排：先中文词典，再美音（官方中英文示例就是这个顺序）。
            urls = modelFiles.lexicons
        case .en:
            urls = modelFiles.lexicons.filter {
                $0.lastPathComponent.contains("en") || $0.lastPathComponent.hasSuffix("en.txt")
            }
        }
        return urls.map(\.path).joined(separator: ",")
    }

    public var ruleFSTArgument: String {
        usesTextNormalizationRules
            ? modelFiles.ruleFSTS.map(\.path).joined(separator: ",")
            : ""
    }
}
