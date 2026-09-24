let cases = [
    "他在写 C++ 和 Rust。",
    "打开 A＆B 两个开关。",
    "他用 5% 的电量撑到 3 号房间。",
    "T恤、U盘、K歌 都放进了包里。",
    "她说了句 hello，然后离开。",
    "「infor- mation」出现在页边。",
]
for text in cases {
    let (cleaned, dropped) = KokoroSpeechText.speakable(text)
    print("原文「\(text)」→「\(cleaned)」吞掉 \(dropped)")
}
