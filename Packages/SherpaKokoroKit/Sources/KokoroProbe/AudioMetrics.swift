//
//  AudioMetrics.swift
//  KokoroProbe
//
//  没有耳朵时的替代量法：从 PCM 里量出「亮不亮、沙不沙、中气足不足」，
//  以及一段音频里被插入了几处停顿。全部是时域/频域直算，不依赖任何音频框架。
//

import Foundation

// MARK: - FFT

/// 就地 radix-2 FFT；长度必须是 2 的幂。
func fftRadix2(real: inout [Double], imag: inout [Double]) {
    let n = real.count
    precondition(n > 1 && n & (n - 1) == 0, "长度必须是 2 的幂")

    var j = 0
    for i in 1..<n {
        var bit = n >> 1
        while j & bit != 0 { j ^= bit; bit >>= 1 }
        j ^= bit
        if i < j {
            real.swapAt(i, j)
            imag.swapAt(i, j)
        }
    }

    var len = 2
    while len <= n {
        let angle = -2.0 * Double.pi / Double(len)
        let wr = cos(angle), wi = sin(angle)
        let half = len / 2
        var i = 0
        while i < n {
            var curR = 1.0, curI = 0.0
            for k in 0..<half {
                let ur = real[i + k], ui = imag[i + k]
                let vr = real[i + k + half] * curR - imag[i + k + half] * curI
                let vi = real[i + k + half] * curI + imag[i + k + half] * curR
                real[i + k] = ur + vr
                imag[i + k] = ui + vi
                real[i + k + half] = ur - vr
                imag[i + k + half] = ui - vi
                let nextR = curR * wr - curI * wi
                curI = curR * wi + curI * wr
                curR = nextR
            }
            i += len
        }
        len <<= 1
    }
}

// MARK: - Metrics

struct FrameStats {
    var rms: Double
    var centroidHz: Double
    /// >4kHz 的能量占比。气声、齿音、毛刺都堆在这里，是「沙」的门面指标。
    var highBandRatio: Double
    /// 归一化自相关峰值：周期性强弱。低 = 噪声多 = 沙哑/虚。
    var voicedCorrelation: Double
    var f0Hz: Double
    /// false = 这一帧没做自相关（只抽测，见 `maxPitchedFrames`）。
    /// 中位数统计不受影响，但画帧图时必须把「未测」和「测了但不浊」分开。
    var pitched: Bool
}

struct ClipStats {
    var frames: [FrameStats]
    /// 时长 ≥ minPauseMs 的静音段（毫秒），用来数「一句里被插了几处停顿」。
    var pauseRunsMs: [Double]
    var peak: Double
    var durationSeconds: Double
    /// 非有限采样数。Kokoro 对极短文本会吐 NaN，而 WAV 编码器把 NaN 夹成 ±1.0，
    /// 于是「一句噪声」听起来就是全刻度方波——必须单独量出来。
    var nonFiniteSamples: Int
}

enum AudioMetrics {

    static let frameSize = 1024
    static let hop = 512

    /// 自相关抽测上限（帧）。逐帧自相关是 O(lag×帧长)，在 -Onone 下比模型推理还慢
    /// （8 秒音频要几十秒），所以整段最多测这么多帧，等距取样。
    static let maxPitchedFrames = 64

    /// Hann 窗。每帧现算 1024 次 cos 在 debug 构建里也是一笔大开销，预先算好。
    static let hannWindow: [Double] = (0..<frameSize).map {
        0.5 - 0.5 * cos(2.0 * Double.pi * Double($0) / Double(frameSize - 1))
    }

    /// 在 55…400Hz 的 lag 区间里找归一化自相关最大值。
    static func pitch(of frame: ArraySlice<Float>, sampleRate: Int) -> (correlation: Double, f0: Double) {
        let count = frame.count
        let base = frame.startIndex
        guard count > 16 else { return (0, 0) }

        let minLag = max(2, Int(Double(sampleRate) / 400.0))
        let maxLag = min(count - 4, Int(Double(sampleRate) / 55.0))
        guard maxLag > minLag else { return (0, 0) }

        var energyA = 0.0
        for i in 0..<count {
            let v = Double(frame[base + i])
            energyA += v * v
        }
        guard energyA > 1e-9 else { return (0, 0) }

        var best = (correlation: 0.0, f0: 0.0)
        for lag in minLag...maxLag {
            let usable = count - lag
            guard usable > minLag else { break }
            var corr = 0.0
            var energyB = 0.0
            for i in 0..<usable {
                let a = Double(frame[base + i])
                let b = Double(frame[base + i + lag])
                corr += a * b
                energyB += b * b
            }
            guard energyB > 1e-9 else { continue }
            // 长度补偿：参与求和的样本随 lag 变少，不补偿会系统性偏向最大 lag。
            let bias = sqrt(Double(usable) / Double(count))
            let normalized = corr / (sqrt(energyA * energyB) / bias)
            if normalized > best.correlation {
                best = (min(normalized, 0.9999), Double(sampleRate) / Double(lag))
            }
        }
        return best
    }

    static func analyze(
        _ samples: [Float],
        sampleRate: Int,
        silenceThreshold: Double = 0.02,
        minPauseMs: Double = 120
    ) -> ClipStats {
        var frames: [FrameStats] = []
        var pauseRuns: [Double] = []
        var peak = 0.0
        var silentStart = -1
        // 逐采样数一遍，不用帧口径：帧有 50% 重叠，按帧累加会把占比算到 200%。
        let nonFinite = samples.lazy.filter { !$0.isFinite }.count

        var re = [Double](repeating: 0, count: frameSize)
        var im = [Double](repeating: 0, count: frameSize)

        // 只对等距抽到的帧做自相关
        let frameCount = max(0, (samples.count - frameSize) / hop + 1)
        let pitchStride = max(1, frameCount / maxPitchedFrames)

        var start = 0
        var frameIndex = 0
        while start + frameSize <= samples.count {
            let slice = samples[start..<(start + frameSize)]

            var sum = 0.0
            var finiteCount = 0
            for i in 0..<frameSize {
                let raw = slice[slice.startIndex + i]
                guard raw.isFinite else {
                    // NaN 不能进 peak/rms：它会污染整句统计，让「一句噪声」
                    // 在数字上看起来像正常语音。当作 0 处理，让静音检测认出它。
                    re[i] = 0
                    im[i] = 0
                    continue
                }
                let value = Double(raw)
                finiteCount += 1
                peak = max(peak, abs(value))
                sum += value * value
                re[i] = value * hannWindow[i]
                im[i] = 0
            }
            let rms = finiteCount > 0 ? sqrt(sum / Double(finiteCount)) : 0

            if rms < silenceThreshold {
                if silentStart < 0 { silentStart = frameIndex }
            } else if silentStart >= 0 {
                let ms = Double(frameIndex - silentStart) * Double(hop) * 1000 / Double(sampleRate)
                if ms >= minPauseMs { pauseRuns.append(ms) }
                silentStart = -1
            }

            var centroid = 0.0
            var highBandRatio = 0.0
            var correlation = 0.0
            var f0 = 0.0
            var pitched = false

            if rms >= silenceThreshold {
                fftRadix2(real: &re, imag: &im)
                var weighted = 0.0
                var magnitudeSum = 0.0
                var totalPower = 0.0
                var highPower = 0.0
                for bin in 1..<(frameSize / 2) {
                    let magnitude = hypot(re[bin], im[bin])
                    let freq = Double(bin) * Double(sampleRate) / Double(frameSize)
                    weighted += freq * magnitude
                    magnitudeSum += magnitude
                    let power = magnitude * magnitude
                    totalPower += power
                    if freq > 4000 { highPower += power }
                }
                if magnitudeSum > 0 { centroid = weighted / magnitudeSum }
                if totalPower > 0 { highBandRatio = highPower / totalPower }

                if frameIndex % pitchStride == 0 {
                    let pitch = self.pitch(of: slice, sampleRate: sampleRate)
                    correlation = pitch.correlation
                    f0 = pitch.f0
                    pitched = true
                }
            }

            frames.append(FrameStats(
                rms: rms,
                centroidHz: centroid,
                highBandRatio: highBandRatio,
                voicedCorrelation: correlation,
                f0Hz: f0,
                pitched: pitched
            ))

            start += hop
            frameIndex += 1
        }

        if silentStart >= 0 {
            let ms = Double(frameIndex - silentStart) * Double(hop) * 1000 / Double(sampleRate)
            if ms >= minPauseMs { pauseRuns.append(ms) }
        }

        return ClipStats(
            frames: frames,
            pauseRunsMs: pauseRuns,
            peak: peak,
            durationSeconds: Double(samples.count) / Double(sampleRate),
            nonFiniteSamples: nonFinite
        )
    }

    /// 一句话的「代表值」：只看响到、且有周期性的帧，取中位数。
    /// 中位数而不是均值，是因为句首句尾的半截帧会把统计带偏。
    struct Summary {
        var f0Hz: Double
        var hnrDb: Double
        var centroidHz: Double
        var highBandRatio: Double
        var rms: Double
        var voicedFrames: Int
    }

    static func summarize(_ stats: ClipStats) -> Summary {
        let voiced = stats.frames.filter { $0.rms >= 0.02 && $0.voicedCorrelation >= 0.3 && $0.f0Hz > 0 }
        let loud = stats.frames.filter { $0.rms >= 0.02 }

        func median(_ values: [Double]) -> Double {
            guard !values.isEmpty else { return 0 }
            let sorted = values.sorted()
            let mid = sorted.count / 2
            return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
        }

        // HNR ≈ 10·log10(r/(1-r))，r 取浊音帧自相关的中位数。
        let r = median(voiced.map(\.voicedCorrelation))
        let hnr = r > 0 ? 10.0 * log10(r / (1.0 - r)) : 0

        return Summary(
            f0Hz: median(voiced.map(\.f0Hz)),
            hnrDb: voiced.isEmpty ? 0 : hnr,
            centroidHz: median(loud.map(\.centroidHz)),
            highBandRatio: median(loud.map(\.highBandRatio)),
            rms: median(loud.map(\.rms)),
            voicedFrames: voiced.count
        )
    }
}
