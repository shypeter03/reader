//
//  BackgroundAudioHold.swift
//  Reader
//
//  一段**数字静音**的循环播放，唯一的作用是「让 iOS 认为这个 App 正在出声」。
//
//  为什么需要它：`UIBackgroundModes: audio` 给的豁免只在真的放出声的时候有效。一旦没有
//  任何音频在出声，系统就把 App 冻进 suspended——而这一句之后什么都不会自己醒过来：
//  网络合成（Edge）的 socket 被掐、本地合成（Kokoro/Qwen）的线程不再跑、排产任务也停。
//  于是「播放器追上音频边界 → 等音频 → 被冻结 → 永远等不到」是一个自我闭合的死局，
//  表现就是熄屏后朗读停住，解锁回来还是停着。
//
//  这个 hold 就塞在那个缝里：本来该出声、却暂时没有东西可放的那一段（等下一句的音频、
//  等下一章的正文），由它顶着音频会话。它是静音的，用户听不到任何差别；句子一到就停，
//  声音交回给真的那一路。
//
//  只在**后台**开：前台不可能被冻结，没必要多占一路音频。
//

import Foundation
import AVFoundation

final class BackgroundAudioHold {

    private var player: AVAudioPlayer?

    /// 有没有在顶着。幂等：已经在跑就别重建。
    var isActive: Bool {
        player?.isPlaying ?? false
    }

    /// 开始顶。已经在顶了什么都不做。
    func start() {
        guard !isActive else { return }
        if player == nil {
            player = Self.makePlayer()
        }
        player?.currentTime = 0
        player?.play()
    }

    /// 不顶了：把这一路彻底放下，好让别的 App 拿回音频焦点。
    func stop() {
        player?.stop()
        player = nil
    }

    /// 200ms 的 16bit 单声道全零采样，循环放。
    /// 不落资源文件：那要往工程里加一个二进制，而它的内容就是「零」——现写比查文件便宜。
    private static func makePlayer() -> AVAudioPlayer? {
        guard let data = silentWAV(seconds: 0.2) else { return nil }
        do {
            let player = try AVAudioPlayer(data: data)
            player.numberOfLoops = -1
            // 采样本来就全是 0；音量保持满的，免得系统把「零音量输出」当成没在播。
            player.volume = 1.0
            player.prepareToPlay()
            return player
        } catch {
            print("⚠️ [Hold] 静音保活建不出来（不影响正常朗读）：\(error)")
            return nil
        }
    }

    private static func silentWAV(seconds: Double) -> Data? {
        let sampleRate = 22_050
        let sampleCount = Int(seconds * Double(sampleRate))
        guard sampleCount > 0 else { return nil }

        let bytesPerSample = 2
        let dataSize = sampleCount * bytesPerSample

        var out = Data()
        func ascii(_ text: String) { out.append(contentsOf: text.utf8) }
        func u32(_ value: Int) {
            withUnsafeBytes(of: UInt32(value).littleEndian) { out.append(contentsOf: $0) }
        }
        func u16(_ value: Int) {
            withUnsafeBytes(of: UInt16(value).littleEndian) { out.append(contentsOf: $0) }
        }

        ascii("RIFF")
        // RIFF 长度 = 之后的总字节数：8（WAVE+fmt 头名与长度）+ 16（fmt 内容）+ 8（data 头）+ 采样
        u32(36 + dataSize)
        ascii("WAVE")
        ascii("fmt ")
        u32(16)
        u16(1)                    // PCM
        u16(1)                    // 单声道
        u32(sampleRate)
        u32(sampleRate * bytesPerSample)  // byte rate
        u16(bytesPerSample)       // block align
        u16(8 * bytesPerSample)   // bits per sample
        ascii("data")
        u32(dataSize)
        out.append(Data(count: dataSize))   // 全零 = 数字静音

        return out
    }
}
