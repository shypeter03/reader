//
//  KokoroSpeakerTable.swift
//  SherpaKokoroKit
//

import Foundation

/// sid → 声音名，从模型自己的 ONNX metadata 里读出来。
///
/// 为什么要读模型而不是抄官方文档：`kokoro-int8-multi-lang-v1_0` 是 54 把声音
/// （`zm_yunyang` = sid 52），`kokoro-int8-multi-lang-v1_1` 是 103 把，中文声音全部
/// 换成编号名（`zf_001`…`zm_100`），sid 52 在 v1_1 里是女声 `zf_088`。
/// 也就是说换模型时硬编码表**不会越界报错**，只会静默把旁白换成别人的嗓子。
/// 越界检查挡不住这种错误，唯一可靠的来源是模型内嵌的表。
///
/// 格式：sherpa-onnx 的打包脚本（`scripts/kokoro/v1.1-zh/add_meta_data.py`）把
/// `n_speakers` / `id2speaker` / `speaker_names` 写进 `ModelProto.metadata_props`，
/// 其中 `id2speaker` 形如 `0->af_maple,1->af_sol,…`。这些条目在序列化后的文件末尾，
/// 所以只读尾部窗口即可，不必引入 protobuf 依赖。
public enum KokoroSpeakerTable {

    /// 尾部读取窗口。两个官方发布模型的 metadata 都在最后 1KB 内，留足余量。
    static let tailWindowBytes = 1024 * 1024

    /// - Returns: 按 sid 升序排列的声音名，下标即 sid；读不到或格式不认识时返回 nil
    ///   —— 调用方必须报错，绝不能退回任何「默认表」。
    public static func speakerNames(
        modelURL: URL,
        fileManager fm: FileManager = .default
    ) -> [String]? {
        guard fm.fileExists(atPath: modelURL.path),
              let handle = try? FileHandle(forReadingFrom: modelURL) else { return nil }
        defer { try? handle.close() }

        // seekToEnd()/seek(toOffset:) 都是 UInt64 接口，别混 Int64。
        let size = (try? handle.seekToEnd()) ?? 0
        guard size > 0 else { return nil }

        let window = Swift.min(size, UInt64(tailWindowBytes))
        do { try handle.seek(toOffset: size - window) } catch { return nil }
        guard let tail = try? handle.readToEnd(), !tail.isEmpty else { return nil }

        if let pairs = metadataValue(tail, key: "id2speaker").flatMap(namesBySid),
           !pairs.isEmpty {
            // 必须是从 0 开始的连续稠密表，否则 sid 与 voices.bin 的行号对不上。
            guard pairs.first?.sid == 0,
                  pairs.count == (pairs.last?.sid ?? -1) + 1 else { return nil }
            return pairs.map(\.name)
        }

        // v1_0 同样写了 speaker_names，顺序即 sid，可作等价来源。
        if let raw = metadataValue(tail, key: "speaker_names") {
            let names = raw.split(separator: ",").map(String.init).filter { !$0.isEmpty }
            if !names.isEmpty { return names }
        }
        return nil
    }

    // MARK: - Protobuf-lite 取值

    /// 读 `metadata_props` 里某个 key 的 value。
    ///
    /// `StringStringEntry { string key = 1; string value = 2; }`，所以 key 之后紧跟
    /// tag `0x12`（field 2、wire type 2）+ varint 长度 + value 字节。
    static func metadataValue(_ data: Data, key: String) -> String? {
        guard let keyBytes = key.data(using: .utf8),
              let range = data.range(of: keyBytes, options: .backwards) else { return nil }

        var i = range.upperBound
        guard i < data.count, data[data.startIndex + i] == 0x12 else { return nil }
        i += 1

        var length = 0
        var shift = 0
        while i < data.count {
            let byte = data[data.startIndex + i]
            i += 1
            length |= Int(byte & 0x7F) << shift
            shift += 7
            if byte & 0x80 == 0 { break }
        }
        guard length > 0, i + length <= data.count else { return nil }

        return String(data: data.subdata(in: i ..< (i + length)), encoding: .utf8)
    }

    private static func namesBySid(_ raw: String) -> [(sid: Int, name: String)]? {
        var pairs: [(sid: Int, name: String)] = []
        for entry in raw.split(separator: ",") {
            guard let arrow = entry.firstIndex(of: ">") else { return nil }
            let head = entry[entry.startIndex ..< arrow]
                .trimmingCharacters(in: .whitespaces)
            let name = entry[entry.index(after: arrow)...]
                .trimmingCharacters(in: .whitespaces)
            guard let sid = Int(head), !name.isEmpty else { return nil }
            pairs.append((sid, name))
        }
        return pairs.sorted { $0.sid < $1.sid }
    }
}
