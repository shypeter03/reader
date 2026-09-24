//
//  KokoroSpeechText.swift
//  SherpaKokoroKit
//
//  送合成前的文本清洗。放在包里而不是 App 里有两个理由：它是「Kokoro 会把拉丁字母
//  当英文念出来」这个引擎行为的一部分，属于引擎的输入契约；且 `kokoro-selftest`
//  能直接断言它，不会因为 App target 拖着一堆依赖而测不到。
//

import Foundation

public enum KokoroSpeechText {

    /// 把夹在中文里的拉丁字母片段整段去掉，返回（要念的文本, 被吞掉的片段）。
    ///
    /// 中文小说里这类片段基本都是噪声（排版残留、被拆开的英文词、OCR 杂字），
    /// 而 Kokoro 的中英混排路径会**照英文念出来**——听感就是句子正常念到一半
    /// 或念完后凭空冒出一个怪英文词（「xformation」那种）。
    ///
    /// 只在「这句主体是中文且含两个以上拉丁字母」时动手：纯英文句子原样交给 espeak，不吞。
    /// 只吞**两个字母以上**的片段：单个字母在中文里基本是合法用法（T恤、U盘、K歌、C++），
    /// 吞掉会把词念坏（「恤」「盘」），而 espeak 的字母读法恰好接近中国人的说法。
    ///
    /// 只影响音频：调用方的显示文本、持久层、缓存键都不动。
    /// 代价：`OK`、`QQ` 这类两字母的词仍会被吞，所以调用方每次吞东西都要打日志，便于按句核对。
    public static func speakable(_ text: String) -> (String, [String]) {
        var cjkCount = 0
        var latinCount = 0
        for scalar in text.unicodeScalars {
            if isLatinLetter(scalar) { latinCount += 1 }
            else if scalar.value >= 0x4E00 && scalar.value <= 0x9FFF { cjkCount += 1 }
        }
        guard latinCount > 1, cjkCount > 0 else { return (text, []) }

        var output = ""
        var dropped: [String] = []
        var run = ""
        let trimmers = CharacterSet(charactersIn: " -")

        // 片段从字母起，往后把数字和连字符也算进同一个词（`MP3`、`4G`、`infor-` 都是一处），
        // 但独立的数字不动 —— 它们要念成「三」「四」。
        func flushRun() {
            guard !run.isEmpty else { return }
            let piece = run.trimmingCharacters(in: trimmers)
            run = ""
            guard !piece.isEmpty else { return }
            if piece.unicodeScalars.filter(isLatinLetter).count >= 2 {
                dropped.append(piece)
            } else {
                output += piece
            }
        }
        for scalar in text.unicodeScalars {
            let continuesRun = (scalar.value == 0x2D && !run.isEmpty)
                || (scalar.value >= 0x30 && scalar.value <= 0x39 && !run.isEmpty)
            if isLatinLetter(scalar) || continuesRun {
                run.unicodeScalars.append(scalar)
                continue
            }
            flushRun()
            output.unicodeScalars.append(scalar)
        }
        flushRun()

        var cleaned = output
        while cleaned.contains("  ") { cleaned = cleaned.replacingOccurrences(of: "  ", with: " ") }
        cleaned = cleaned.trimmingCharacters(in: trimmers)
        // 吞到什么都不剩（整句只有一个拉丁词加标点）时退回原文：
        // 念出英文总比念一串标点好。
        guard cleaned.contains(where: { $0.isLetter || $0.isNumber }) else { return (text, []) }
        return (cleaned, dropped)
    }

    /// 半角与全角拉丁字母。全角（ＡＢＣ）常见于 HTML 实体转换后的残留，
    /// 一样会被当英文念，所以一并算。
    private static func isLatinLetter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x41...0x5A, 0x61...0x7A, 0xFF21...0xFF3A, 0xFF41...0xFF5A: return true
        default: return false
        }
    }
}
