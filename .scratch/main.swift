// 断句验证：直接编进真源码（SentenceSplitter / HTMLTextExtractor / Sentence / Emotion），
// 不复制逻辑——复制出来的测试只能测到副本。
import Foundation

var failures = 0

func check(_ label: String, _ condition: Bool, _ detail: String = "") {
    if condition {
        print("[OK]   \(label)")
    } else {
        failures += 1
        print("[FAIL] \(label) \(detail)")
    }
}

// MARK: - HTML 软换行

let softWrapped = """
<html><body><p>他把书轻轻放在
桌上，望着窗外
绵绵的雨。</p>
<p>“你好。”他说。</p></body></html>
"""

let extracted = HTMLTextExtractor.extractText(from: softWrapped)
print("extracted = \(extracted.debugDescription)")
check("段内折行接回同一句", extracted.contains("放在桌上") && extracted.contains("望着窗外绵绵"), extracted)
check("段落之间仍是换行", extracted.contains("\n"), extracted)

let brWrapped = "<p>第一行没有结束\n第二行继续。<br/>第三行也接上<br>第四行。</p>"
let brText = HTMLTextExtractor.extractText(from: brWrapped)
print("brText = \(brText.debugDescription)")
check("<br> 不再切断句子", brText.contains("接上第四行"), brText)

let english = "<p>This is a first\nsecond line. And next paragraph.</p><p>New para.</p>"
let engText = HTMLTextExtractor.extractText(from: english)
print("engText = \(engText.debugDescription)")
check("英文软换行补空格，不粘成单词", engText.contains("first second"), engText)

// 断词连字符：`infor-\nmation` 若原样接回会变成「infor mation」，
// espeak 当成两个词念 → 句尾冒出一个怪英文词。
let hyphenBroken = "<p>He walked across the infor-\nmation today.</p>"
let hyphenText = HTMLTextExtractor.extractText(from: hyphenBroken)
print("hyphenText = \(hyphenText.debugDescription)")
check("断词连字符接回原词", hyphenText.contains("information") && !hyphenText.contains("- "), hyphenText)

// 中文正文里夹一个被排版拆开的英文词（设备日志那句「句尾冒出 xformation」的真实形状）：
// 旧版把换行原样留着 → 切句器在换行处下刀 → 前半句以「infor-」结尾，
// espeak 把这截当英文念出来，听感就是句尾凭空多一个怪词。
let mixedBroken = "<p>他盯着屏幕上一行行滚过的字，觉得整个世界的形 infor-\nmation 都在朝他压过来。</p>"
let mixedText = HTMLTextExtractor.extractText(from: mixedBroken)
let mixedSentences = SentenceSplitter.split(mixedText, chapterIndex: 0).map(\.text)
print("mixedSentences = \(mixedSentences)")
check("中文夹断词仍是一整句", mixedSentences.count == 1, "\(mixedSentences)")
check("没有句子以连字符收尾", mixedSentences.allSatisfy { !$0.hasSuffix("-") }, "\(mixedSentences)")

// 破折号/列表符不是断词连字符，不能被误删。
let dashKept = "<p>他把书放下——\n然后走了。</p>"
let dashText = HTMLTextExtractor.extractText(from: dashKept)
check("破折号折行不吞字", dashText.contains("——"), dashText)

// 软连字符（&shy;）只是换行提示，绝不该被念出来。
let softHyphen = HTMLTextExtractor.extractText(from: "<p>unbel\u{00AD}ievable</p>")
check("软连字符被去掉", softHyphen == "unbelievable", softHyphen.debugDescription)

// MARK: - 断句

let prose = "他把书轻轻放在桌上，望着窗外绵绵的雨。忽然想起很多年以前那个闷热的傍晚。“我们走。”她说道。"
let sentences = SentenceSplitter.split(prose, chapterIndex: 0)
let texts = sentences.map(\.text)
print("切分结果：")
for (index, text) in texts.enumerated() { print("  \(index) 「\(text)」") }

check("引导语不再被切开", !texts.contains { $0.hasSuffix("：") }, "\(texts)")
check("没有 <4 字碎片", texts.allSatisfy { SentenceSplitter.spokenCharacterCount($0) >= 4 }, "\(texts)")
check("整段字数守恒（没有丢字）",
      texts.reduce(0) { $0 + SentenceSplitter.spokenCharacterCount($1) }
      == SentenceSplitter.spokenCharacterCount(prose), "\(texts)")

// 冒号后面接话：应该整句留着
let colon = "他说：今天很好。然后转身走了。"
let colonSentences = SentenceSplitter.split(colon, chapterIndex: 0).map(\.text)
print("colon = \(colonSentences)")
check("「他说：」不单独成句", !colonSentences.contains("他说："), "\(colonSentences)")

// 独立成行的收尾引号
let closing = "“我们走吧。\n”\n他先出了门。"
let closingSentences = SentenceSplitter.split(closing, chapterIndex: 0).map(\.text)
print("closing = \(closingSentences)")
check("收尾引号并回上一句", closingSentences.allSatisfy { !$0.isEmpty && $0 != "”" }, "\(closingSentences)")

// MARK: - 缓存键

let a = Sentence(index: 0, text: "第一句内容。", chapterIndex: 3)
let b = Sentence(index: 0, text: "改过的第一句。", chapterIndex: 3)
let c = Sentence(index: 0, text: "第一句内容。", chapterIndex: 3)
check("重解析后同一句仍同 ID", a.id == c.id)
check("文本变了则 ID 变了（旧音频不会串）", a.id != b.id)

// MARK: - 48 字上限（整段引语/并列长句）

let long = "他走过长长的走廊，推开那扇沉重的木门，看见房间里满地都是昨天没有收拾的报纸和信件，桌上那盏台灯还亮着，窗外的雪已经下了很大一层，他没有去关。"
let longTexts = SentenceSplitter.split(long, chapterIndex: 0).map(\.text)
print("long = \(longTexts)")
check("长句被裁开", longTexts.count > 1, "\(longTexts)")
check("裁开后每段都在上限附近",
      longTexts.allSatisfy { SentenceSplitter.spokenCharacterCount($0) <= 54 }, "\(longTexts)")
check("裁开不丢字",
      longTexts.reduce(0) { $0 + SentenceSplitter.spokenCharacterCount($1) }
      == SentenceSplitter.spokenCharacterCount(long), "\(longTexts)")
check("下刀只落在标点后（不从字中间切）",
      longTexts.dropLast().allSatisfy { "，、；：,;:".contains($0.last!) }, "\(longTexts)")

// 一整段没有弱边界的极端情况：按上限硬切，但绝不产生 <4 字碎片
let noPunctuation = String(repeating: "雨", count: 120)
let hardPieces = SentenceSplitter.split(noPunctuation, chapterIndex: 0).map(\.text)
check("无标点长串也被裁出上界",
      hardPieces.allSatisfy { SentenceSplitter.spokenCharacterCount($0) <= 54 }, "\(hardPieces.map(\.count))")
check("无标点裁切不丢字",
      hardPieces.reduce(0) { $0 + $1.count } == 120, "\(hardPieces.map(\.count))")

// MARK: - 送合成前的拉丁片段清洗

let noisy = "他盯着屏幕，觉得整个世界的形 infor- mation 都在朝他压过来。"
let stripped = KokoroSpeechText.speakable(noisy)
print("stripped = \(stripped.0.debugDescription) 吞掉 \(stripped.1)")
check("中文里的英文片段被吞掉", !stripped.0.contains("infor") && !stripped.0.contains("mation"), stripped.0)
check("吞掉的东西如实上报", stripped.1 == ["infor", "mation"], "\(stripped.1)")
check("中文一个字不少", stripped.0.replacingOccurrences(of: " ", with: "")
      == noisy.replacingOccurrences(of: " ", with: "")
         .replacingOccurrences(of: "infor-", with: "").replacingOccurrences(of: "mation", with: ""), stripped.0)
check("不留双空格", !stripped.0.contains("  "), stripped.0)

// 纯英文句子不归它管：交给 espeak 正常念，不能吞成空。
let pureEnglish = KokoroSpeechText.speakable("Hello world, she said.")
check("纯英文句原样保留", pureEnglish.0 == "Hello world, she said." && pureEnglish.1.isEmpty, pureEnglish.0)
let noLatin = KokoroSpeechText.speakable("他把书放在桌上。")
check("没有拉丁字母时不动", noLatin.0 == "他把书放在桌上。" && noLatin.1.isEmpty, noLatin.0)
// 数字是合法内容（要念成「三」），只吞字母。
let digits = KokoroSpeechText.speakable("3 号房间的 MP3 坏了。")
check("数字留下、字母吞掉", digits.0 == "3 号房间的 坏了。" && digits.1 == ["MP3"], digits.0)
// 单个字母是中文里的合法用法（T恤、U盘、C++），吞掉会把词念成「恤」「盘」——所以只吞两个以上。
let single = KokoroSpeechText.speakable("他穿了件 T恤，用 U盘 存了 K歌。")
check("单个字母不动", single.0 == "他穿了件 T恤，用 U盘 存了 K歌。" && single.1.isEmpty, single.0)
let singleWithWord = KokoroSpeechText.speakable("他穿了件 T恤，说了句 hello。")
check("单字母留下、旁边的英文词吞掉",
      singleWithWord.0 == "他穿了件 T恤，说了句 。" && singleWithWord.1 == ["hello"], singleWithWord.0)
let fullWidth = KokoroSpeechText.speakable("门口站着 Ａ 和Ｂ 两个人。")
check("全角单字母同样不动", fullWidth.0 == "门口站着 Ａ 和Ｂ 两个人。" && fullWidth.1.isEmpty, fullWidth.0)
let fullWidthWord = KokoroSpeechText.speakable("门口站着 ＡＢ 两个人。")
check("全角两个字母算英文片段", fullWidthWord.1 == ["ＡＢ"], fullWidthWord.0)

print(failures == 0 ? "\n全部通过" : "\n失败 \(failures) 项")
exit(failures == 0 ? 0 : 1)
