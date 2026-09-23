//
//  KokoroAudio.swift
//  SherpaKokoroKit
//

import Foundation

/// Kokoro 的输出：归一化到 -1...1 的单声道 Float PCM。
///
/// 刻意不返回 MLXArray——这条链路上没有 MLX，Kokoro 走 ONNX Runtime。
/// Reader 现有缓存是 WAV 文件，所以这里提供一个独立的 16-bit PCM WAV 编码器，
/// 与 Qwen3-TTS 的编码器互不影响。
public struct KokoroAudio: Sendable {

    public let samples: [Float]
    public let sampleRate: Int

    public init(samples: [Float], sampleRate: Int) {
        self.samples = samples
        self.sampleRate = sampleRate
    }

    public var duration: Double {
        guard sampleRate > 0 else { return 0 }
        return Double(samples.count) / Double(sampleRate)
    }

    /// 峰值（用于自检：0 峰值 = 静音 = 合成其实失败了）。
    public var peakAmplitude: Float {
        samples.reduce(0) { max($0, abs($1)) }
    }

    public func wavData() -> Data {
        var pcm = Data(capacity: samples.count * 2)
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            let intSample = Int16(clamped < 0 ? clamped * 32768 : clamped * 32767)
            withUnsafeBytes(of: intSample.littleEndian) { pcm.append(contentsOf: $0) }
        }
        return WAVWriter.mono16BitPCM(pcm, sampleRate: sampleRate)
    }
}

/// 44 字节标准 WAV 头 + PCM。
enum WAVWriter {

    static func mono16BitPCM(_ pcm: Data, sampleRate: Int) -> Data {
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(sampleRate) * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let dataSize = UInt32(pcm.count)
        let chunkSize = 36 + dataSize

        var data = Data(capacity: pcm.count + 44)
        func append(_ string: String) { data.append(contentsOf: string.utf8) }
        func append_u16(_ value: UInt16) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        func append_u32(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }

        append("RIFF"); append_u32(chunkSize); append("WAVE")
        append("fmt "); append_u32(16)
        append_u16(1)                       // PCM
        append_u16(channels)
        append_u32(UInt32(sampleRate))
        append_u32(byteRate)
        append_u16(blockAlign)
        append_u16(bitsPerSample)
        append("data"); append_u32(dataSize)
        data.append(pcm)
        return data
    }
}
