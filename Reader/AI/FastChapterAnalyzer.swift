//
//  FastChapterAnalyzer.swift
//  Reader
//
//  Created by 粟海洋 on 2026/9/21.
//

import Foundation

actor FastChapterAnalyzer {

    // MARK: - Scope

    /// 一次章节标注要共用的上下文。承前需要整章的文本与段落标记，所以它们在循环外算一次
    /// （放在循环里就是每句重摊一遍整章，实测 306 句的章会白多几毫秒）。
    private struct Scope {
        let bookID: UUID
        let knownNames: Set<String>
        /// 改名字用的池子（档案 + 账本里证据够密的那些），外加账本判过的前缀对。
        /// 每章取一次，别每句查一遍档案（`snapshot` 要过锁）。
        let renamePool: Set<String>
        let folds: [String: String]
        /// 这本书引号配对干净、允许段内承前（见 ``CharacterRoster/allowsParagraphCarry``）。
        let carry: Bool
        let texts: [String]
        let paragraphStarts: [Bool]
    }

    private func makeScope(_ chapter: Chapter, bookID: UUID) -> Scope {
        Scope(
            bookID: bookID,
            knownNames: CharacterRoster.shared.names(bookID: bookID),
            renamePool: CharacterRoster.shared.renamePool(bookID: bookID),
            folds: CharacterRoster.shared.foldMap(bookID: bookID),
            carry: CharacterRoster.shared.allowsParagraphCarry(bookID: bookID),
            texts: chapter.sentences.map(\.text),
            paragraphStarts: chapter.sentences.map(\.startsParagraph)
        )
    }

    /// 落库之前把「韩世忠骤」这种前缀残渣换成真名。
    ///
    /// 两步同一条口径：先查账本判过的前缀对（``CharacterRoster/fold(_:folds:)``，两边都有整本书
    /// 的出场次数当证据），再退一步按池子折（``DialogueAttribution/folded(name:pool:)``，池子里
    /// 包含还没入档的那个人）。认不出人、只认出一截串的句子一律不动——这条只改写法，不猜谁。
    private func foldedName(_ name: String?, scope: Scope) -> String? {
        guard let name else { return nil }
        let folded = CharacterRoster.fold(name, folds: scope.folds)
        return DialogueAttribution.folded(name: folded, pool: scope.renamePool) ?? folded
    }

    // MARK: - Analyze

    func analyze(
        chapter: Chapter,
        bookID: UUID,
        context: StoryContext
    ) async throws -> Chapter {

        var chapter = chapter

        chapter.audioStatus = .analyzing

        let scope = makeScope(chapter, bookID: bookID)
        for index in chapter.sentences.indices {
            chapter.sentences[index] = annotate(chapter.sentences[index], at: index, in: &chapter, scope: scope)
        }

        chapter.audioStatus = .pending

        return chapter
    }

    /// 只标注「尚无参数」的句子并返回快照：这些句子随即可以送进 TTS，
    /// 开播不必等 LLM。已有参数的句子（可能来自 LLM 校准）原样保留，
    /// 避免每次翻章把更好的标注退回正则结果。
    /// 传 `range` 可把标注限制在播放位置附近：远处的句子留给 LLM 定参数，
    /// 正则那套强情绪指令不该抢先决定整章的听感。
    func prime(_ chapter: Chapter, bookID: UUID, in range: Range<Int>? = nil) -> Chapter {

        var chapter = chapter

        let lower = max(0, range?.lowerBound ?? 0)
        let upper = min(chapter.sentences.count, range?.upperBound ?? chapter.sentences.count)
        guard lower < upper else { return chapter }

        // 候选人名取自这一本书的人物档案：提示语被逗号切断时靠它救回说话人
        // （见 `DialogueAttribution.personName(in:knownNames:)`）。调用方保证档案至少
        // 覆盖到播放章及其前几章（ReaderPipeline 的 ensureRoster 排在合成之前），
        // 所以这里通常查得到人；整本还在后台补，补上之后由漂移分支重录那几句。
        let scope = makeScope(chapter, bookID: bookID)
        for index in lower..<upper
        where chapter.sentences[index].analysisStatus != .completed {
            chapter.sentences[index] = annotate(chapter.sentences[index], at: index, in: &chapter, scope: scope)
        }

        return chapter
    }

    private func annotate(
        _ sentence: Sentence,
        at index: Int,
        in chapter: inout Chapter,
        scope: Scope
    ) -> Sentence {

        let analysis = analyzeSentence(sentence.text, knownNames: scope.knownNames)
        var updated = sentence

        updated.type = analysis.type
        updated.speaker = analysis.speaker
        updated.emotion = analysis.emotion
        updated.emotionIntensity = analysis.emotionIntensity
        updated.speed = analysis.speed
        updated.pitch = analysis.pitch
        updated.voiceStrength = analysis.voiceStrength
        updated.analysisStatus = .completed

        // 这句台词自己认不出人时试着借同段上一句的（规则与闸门都在 ``CharacterAnalysis/carriedSpeaker``）。
        // 借来的名字只许复用**已经在档案里的人**，所以它不会给任何人开新嗓，也就没有
        // 「同一个人两句换个声音」的风险——那是需求里明确禁止的，而认不出退回无名嗓是一致且无害的。
        var characterName = analysis.characterName
        if analysis.type == .dialogue, characterName == nil {
            characterName = CharacterAnalysis.carriedSpeaker(
                at: index,
                texts: scope.texts,
                paragraphStarts: scope.paragraphStarts,
                knownNames: scope.knownNames,
                rosterName: { CharacterRoster.shared.person(bookID: scope.bookID, name: $0)?.name },
                enabled: scope.carry
            )
        }
        updated.characterName = foldedName(characterName, scope: scope)

        if analysis.speaker == .character, let characterName = updated.characterName {

            if let character = chapter.characters.first(where: { $0.name == characterName }) {
                updated.characterID = character.id
            } else {
                let newCharacter = Character(
                    name: characterName,
                    gender: .unknown,
                    age: .unknown
                )
                chapter.characters.append(newCharacter)
                updated.characterID = newCharacter.id
            }
        }

        return updated
    }

    func unloadModel() async {
    }

    /// 只重算「这句是谁说的」：提取口径升级后给已经落库的老章节补说话人。
    ///
    /// 情绪、语速、强度一个字段都不碰——那些可能有 LLM 校准过的好结果，重跑一遍正则
    /// 会把它们冲掉。正文与音频也不碰：声音真的变了的那几句由 ``ReaderPipeline``
    /// 的漂移分支退回待合成，这里只负责把「谁在说话」这件事回到当前口径上。
    /// `characters` 整份重建：旧档案里的「认真」这种脏名随之消失，章内人名和句子重新对得上。
    func refreshSpeakers(_ chapter: Chapter, bookID: UUID) -> Chapter {
        var chapter = chapter
        var characters: [Character] = []
        let scope = makeScope(chapter, bookID: bookID)
        for index in chapter.sentences.indices {
            var sentence = chapter.sentences[index]
            let (type, direct) = speakerOnly(sentence.text, knownNames: scope.knownNames)
            // 迁移也要走承前：否则「已存章节按老口径重标」这一遍会把新规则借到的名字漏掉，
            // 同一句话在迁移前后落到两把嗓上，正是「一个人两段对话换个声音」。
            let name = foldedName(
                direct ?? CharacterAnalysis.carriedSpeaker(
                    at: index,
                    texts: scope.texts,
                    paragraphStarts: scope.paragraphStarts,
                    knownNames: scope.knownNames,
                    rosterName: { CharacterRoster.shared.person(bookID: scope.bookID, name: $0)?.name },
                    enabled: type == .dialogue && scope.carry
                ),
                scope: scope
            )
            sentence.type = type
            sentence.speaker = type == .dialogue ? .character : .narrator
            sentence.characterName = name
            sentence.characterID = nil
            if type == .dialogue, let name {
                if let existing = characters.first(where: { $0.name == name }) {
                    sentence.characterID = existing.id
                } else {
                    let created = Character(name: name, gender: .unknown, age: .unknown)
                    characters.append(created)
                    sentence.characterID = created.id
                }
            }
            chapter.sentences[index] = sentence
        }
        chapter.characters = characters
        return chapter
    }

    /// 只回答「这句是不是台词、是谁说的」。迁移用这一条，不走 ``analyzeSentence``：
    /// 情绪那几百个线索词（``lexicon``）在这里跑一遍是白跑——结果马上被丢掉，而它占了
    /// 整次迁移九成时间（实测 306 句：带字典 121ms，不带 16ms）。
    private func speakerOnly(_ text: String, knownNames: Set<String>) -> (SentenceType, String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, containsDialogue(trimmed) else { return (.narration, nil) }
        return (.dialogue, DialogueAttribution.personName(in: trimmed, knownNames: knownNames))
    }

    // MARK: - Sentence Analysis

    private struct SentenceAnalysis {
        let type: SentenceType
        let speaker: SpeakerType
        let characterName: String?
        let emotion: Emotion
        let emotionIntensity: Double
        let speed: Double
        let pitch: Double
        let voiceStrength: Double
    }

    private func analyzeSentence(_ text: String, knownNames: Set<String>) -> SentenceAnalysis {

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            return SentenceAnalysis(
                type: .narration,
                speaker: .narrator,
                characterName: nil,
                emotion: .neutral,
                emotionIntensity: Emotion.neutral.defaultIntensity,
                speed: Emotion.neutral.defaultSpeed,
                pitch: Emotion.neutral.defaultPitch,
                voiceStrength: Emotion.neutral.defaultVoiceStrength
            )
        }

        let hasDialogue = containsDialogue(trimmed)

        if hasDialogue {
            return analyzeDialogue(trimmed, knownNames: knownNames)
        } else {
            return analyzeNarration(trimmed)
        }
    }

    // MARK: - Dialogue Detection

    private static let quotePairs: [(open: String.Element, close: String.Element)] = [
        ("\u{201C}", "\u{201D}"), ("\u{2018}", "\u{2019}"),
        ("「", "」"), ("『", "』"),
    ]

    /// 这一句里有没有「一段引起来的话」。四对引号扫一遍就行——原来是每句现编译四条
    /// NSRegularExpression，整章迁移实测 0.3ms/句 全花在编译上（300 句 120ms 起跳）。
    private func containsDialogue(_ text: String) -> Bool {
        for pair in Self.quotePairs {
            var opened = false
            for character in text {
                if character == pair.open { opened = true }
                else if character == pair.close, opened { return true }
            }
        }
        return false
    }

    // MARK: - Dialogue Analysis

    private func analyzeDialogue(_ text: String, knownNames: Set<String>) -> SentenceAnalysis {

        // 说话人提取和书级人物分析（``CharacterAnalysis``）走同一份口径：两边各认各的
        // 名字，同一个人就会在档案里成两个人、两句换个嗓。
        // `knownNames` 是档案里那批人：提示语被逗号切断时（「宁毅看着她，低声道：“…”」）
        // 靠他们把说话人救回来——严格口径在真书上只认得出 20% 的台词。
        let speakerName = DialogueAttribution.personName(in: text, knownNames: knownNames)

        let detected = detectEmotion(from: text)
        let speed = detectSpeed(from: text, emotion: detected.emotion)
        let pitch = detectPitch(detected.emotion)
        let voiceStrength = Self.voiceStrength(for: text, emotion: detected.emotion)

        return SentenceAnalysis(
            type: .dialogue,
            speaker: .character,
            characterName: speakerName,
            emotion: detected.emotion,
            emotionIntensity: detected.intensity,
            speed: speed,
            pitch: pitch,
            voiceStrength: voiceStrength
        )
    }

    // MARK: - Narration Analysis

    private func analyzeNarration(_ text: String) -> SentenceAnalysis {

        let detected = detectEmotion(from: text)
        let speed = detectSpeed(from: text, emotion: detected.emotion)
        let pitch = detectPitch(detected.emotion)
        let voiceStrength = Self.voiceStrength(for: text, emotion: detected.emotion)

        return SentenceAnalysis(
            type: .narration,
            speaker: .narrator,
            characterName: nil,
            emotion: detected.emotion,
            emotionIntensity: detected.intensity,
            speed: speed,
            pitch: pitch,
            voiceStrength: voiceStrength
        )
    }

    // MARK: - Emotion Detection

    /// 情绪线索词表：词 →（情绪，这个词自带的强度）。
    ///
    /// 取代旧的两处病灶：①「有！就分类，没有情绪词一律 tense」，②强度靠
    /// 「0.3 + 0.2×感叹号 + 类别加成」堆出来，于是单个「！」就能把句子推到 0.7，
    /// 配上强 instruct 正好是音频跑偏的触发条件。现在强度只由词本身决定，
    /// 标点只做 ±0.08 级别的微调，不再决定情绪类别。
    ///
    /// 分档：0.35~0.45 弱（'静''急'这类单字）/ 0.5~0.6 中 / 0.7~0.75 强 / 0.85~0.9 极。
    /// 匹配按最长优先，所以「苦笑、冷笑、嘲笑」能盖住「笑」，「哈哈大笑」盖住「大」。
    private static let lexicon: [String: (Emotion, Double)] = [
        // 喜
        "笑": (.happy, 0.45), "微笑": (.happy, 0.5), "轻笑": (.happy, 0.5), "大笑": (.happy, 0.75),
        "哈哈大笑": (.happy, 0.8), "哄笑": (.happy, 0.7), "咯咯": (.happy, 0.55), "嘻嘻": (.happy, 0.5),
        "哈哈": (.happy, 0.6), "喜": (.happy, 0.6), "欢喜": (.happy, 0.7), "欣喜": (.happy, 0.75),
        "喜欢": (.happy, 0.5), "高兴": (.happy, 0.65), "开心": (.happy, 0.65), "快乐": (.happy, 0.6),
        "愉快": (.happy, 0.6), "畅快": (.happy, 0.6), "乐": (.happy, 0.45), "甜": (.happy, 0.4),
        "暖": (.happy, 0.4), "满足": (.happy, 0.5), "眉开眼笑": (.happy, 0.8), "心花怒放": (.happy, 0.85),
        "亮起来": (.happy, 0.55),
        // 悲
        "哭": (.sad, 0.6), "哭了": (.sad, 0.75), "痛哭": (.sad, 0.9), "大哭": (.sad, 0.8),
        "抽泣": (.sad, 0.7), "呜咽": (.sad, 0.75), "哽咽": (.sad, 0.7), "流泪": (.sad, 0.65),
        "眼泪": (.sad, 0.6), "泪": (.sad, 0.5), "悲": (.sad, 0.7), "悲伤": (.sad, 0.75),
        "悲哀": (.sad, 0.75), "哀": (.sad, 0.6), "伤心": (.sad, 0.7), "难过": (.sad, 0.6),
        "心酸": (.sad, 0.7), "心痛": (.sad, 0.75), "疼": (.sad, 0.45), "痛": (.sad, 0.5),
        "苦": (.sad, 0.4), "苦涩": (.sad, 0.6), "委屈": (.sad, 0.6), "失落": (.sad, 0.55),
        "沮丧": (.sad, 0.65), "黯然": (.sad, 0.65), "绝望": (.sad, 0.85), "崩溃": (.sad, 0.85),
        "无力": (.sad, 0.45), "疲惫": (.sad, 0.4), "叹气": (.sad, 0.5), "叹息": (.sad, 0.5),
        "苦笑": (.sad, 0.55), "咬着嘴唇": (.sad, 0.5), "咬唇": (.sad, 0.5), "低下头": (.sad, 0.4),
        // 怒
        "怒": (.angry, 0.7), "愤怒": (.angry, 0.8), "恼": (.angry, 0.6), "恼火": (.angry, 0.7),
        "火气": (.angry, 0.65), "火": (.angry, 0.5), "气": (.angry, 0.45), "生气": (.angry, 0.7),
        "气愤": (.angry, 0.75), "愤愤": (.angry, 0.65), "恨": (.angry, 0.7), "憎恨": (.angry, 0.85),
        "骂": (.angry, 0.65), "吼": (.angry, 0.8), "怒吼": (.angry, 0.9), "咆哮": (.angry, 0.9),
        "大喝": (.angry, 0.75), "厉声": (.angry, 0.75), "摔": (.angry, 0.65), "砸": (.angry, 0.65),
        "掀翻": (.angry, 0.8), "拍桌": (.angry, 0.75), "踢": (.angry, 0.5), "揍": (.angry, 0.6),
        "粗暴": (.angry, 0.6), "咬牙切齿": (.angry, 0.8), "怒视": (.angry, 0.75),
        "凭什么": (.angry, 0.75), "该死": (.angry, 0.7), "闭嘴": (.angry, 0.7), "住口": (.angry, 0.7),
        "滚": (.angry, 0.7), "混账": (.angry, 0.8),
        // 惧
        "怕": (.fearful, 0.55), "害怕": (.fearful, 0.7), "恐惧": (.fearful, 0.85), "惊恐": (.fearful, 0.85),
        "吓得": (.fearful, 0.65), "吓人": (.fearful, 0.55), "胆": (.fearful, 0.4), "慌": (.fearful, 0.55),
        "慌乱": (.fearful, 0.65), "慌张": (.fearful, 0.6), "发抖": (.fearful, 0.7), "颤抖": (.fearful, 0.65),
        "哆嗦": (.fearful, 0.65), "战战兢兢": (.fearful, 0.85), "冷汗": (.fearful, 0.7), "逃": (.fearful, 0.55),
        "退缩": (.fearful, 0.5), "求饶": (.fearful, 0.7), "救救": (.fearful, 0.7), "别过来": (.fearful, 0.75),
        "僵住": (.fearful, 0.55), "颤声": (.fearful, 0.6),
        // 惊
        "惊": (.surprised, 0.6), "惊讶": (.surprised, 0.7), "吃惊": (.surprised, 0.7), "震惊": (.surprised, 0.85),
        "愣": (.surprised, 0.6), "愣住": (.surprised, 0.65), "怔": (.surprised, 0.6), "呆": (.surprised, 0.5),
        "呆住": (.surprised, 0.65), "居然": (.surprised, 0.5), "没想到": (.surprised, 0.55), "竟": (.surprised, 0.45),
        "天哪": (.surprised, 0.75), "我的天": (.surprised, 0.75), "突然": (.surprised, 0.5), "骤然": (.surprised, 0.5),
        "张口结舌": (.surprised, 0.6), "瞪大": (.surprised, 0.55),
        //  Excited 激动
        "兴奋": (.excited, 0.75), "亢奋": (.excited, 0.8), "激动": (.excited, 0.7), "热血": (.excited, 0.7),
        "迫不及待": (.excited, 0.75), "跃跃欲试": (.excited, 0.65), "终于": (.excited, 0.55), "太好了": (.excited, 0.8),
        "做到了": (.excited, 0.65), "赢了": (.excited, 0.6), "狂": (.excited, 0.6), "跳起来": (.excited, 0.7),
        "心跳如鼓": (.excited, 0.7), "冲": (.excited, 0.45),
        // 平静
        "平静": (.calm, 0.5), "安静": (.calm, 0.45), "静": (.calm, 0.35), "缓缓": (.calm, 0.4),
        "慢慢": (.calm, 0.4), "沉稳": (.calm, 0.5), "淡然": (.calm, 0.55), "淡淡": (.calm, 0.45),
        "从容": (.calm, 0.55), "悠闲": (.calm, 0.55), "惬意": (.calm, 0.6), "恬静": (.calm, 0.5),
        "安详": (.calm, 0.55), "平和": (.calm, 0.5), "缓和": (.calm, 0.4), "松弛": (.calm, 0.45),
        "微微一笑": (.calm, 0.5), "沉默": (.calm, 0.35), "没有回答": (.calm, 0.35),
        // 紧张
        "紧张": (.tense, 0.7), "急": (.tense, 0.45), "赶紧": (.tense, 0.55), "连忙": (.tense, 0.5),
        "逼近": (.tense, 0.6), "对峙": (.tense, 0.65), "僵持": (.tense, 0.6), "危机": (.tense, 0.55),
        "千钧一发": (.tense, 0.9), "电光石火": (.tense, 0.75), "剑拔弩张": (.tense, 0.8),
        "屏住呼吸": (.tense, 0.65), "死死": (.tense, 0.65), "猛地": (.tense, 0.55), "一把": (.tense, 0.4),
        "咬牙": (.tense, 0.55), "倒计时": (.tense, 0.6), "刺耳": (.tense, 0.5),
        "越来越近": (.tense, 0.6), "脚步声": (.tense, 0.5), "追": (.tense, 0.5)
    ]

    /// 程度副词乘子。同一个词只取窗口内最大的那一个，不累加。
    private static let degreeAdverbs: [(String, Double)] = [
        ("透顶", 1.4), ("彻骨", 1.35), ("无比", 1.35), ("极度", 1.35), ("最", 1.3),
        ("非常", 1.25), ("特别", 1.25), ("十分", 1.25), ("太", 1.2), ("好生", 1.2),
        ("很", 1.15), ("更", 1.12), ("真", 1.12), ("这么", 1.1), ("那么", 1.1),
        ("有些", 0.8), ("有点", 0.8), ("微微", 0.78), ("略", 0.75), ("一丝", 0.75)
    ]

    private static let negators = ["没有", "不", "没", "未", "别", "无", "莫", "非"]

    /// 转折之后才是情绪重心：转折前的分句只留三成。
    private static let contrastives = ["但是", "可是", "然而", "不过", "只是", "但", "却", "可"]

    /// 提示语动词直接决定声音力度——这是唯一能让 voiceStrength 离开情绪默认档的线索。
    /// 数值刻意与 LLM prompt 里那条「只有明写轻声/低声才给 0.6~0.75」对齐，两边不打架。
    private static let loudCues: [(String, Double)] = [
        ("咆哮", 0.98), ("怒吼", 0.98), ("吼", 0.95), ("尖叫", 0.95), ("大喊", 0.95), ("喊", 0.92),
        ("嚷", 0.92), ("大喝", 0.9), ("高声", 0.9), ("大声", 0.9), ("厉声", 0.9), ("喝", 0.88)
    ]
    private static let softCues: [(String, Double)] = [
        ("耳语", 0.6), ("嗫嚅", 0.6), ("气若游丝", 0.6), ("喃喃", 0.62), ("细声", 0.62),
        ("低声", 0.65), ("轻声", 0.65), ("小声", 0.65), ("悄悄", 0.65), ("咕哝", 0.68)
    ]

    private struct CueHit { let emotion: Emotion; var weight: Double }

    /// 判定入口：返回情绪与该情绪的强度（0.2...0.85）。
    private func detectEmotion(from text: String) -> (emotion: Emotion, intensity: Double) {
        let clauses = splitClauses(text)
        let exclaim = text.contains("！") || text.contains("!")
        let question = text.contains("？") || text.contains("?")
        let ellipsis = text.contains("……") || text.contains("...")

        var contrastAt: Int?
        for (i, clause) in clauses.enumerated() where containsAny(clause, Self.contrastives) {
            contrastAt = i
            break
        }

        // 同一情绪的多个线索取 max 而非累加：三个 0.45 的词不该顶得上一个 0.85 的词。
        var scores: [Emotion: Double] = [:]
        for (i, clause) in clauses.enumerated() {
            let damping = contrastAt.map { i < $0 ? 0.35 : 1.0 } ?? 1.0
            for hit in cueHits(in: clause) {
                let value = hit.weight * damping
                scores[hit.emotion] = max(scores[hit.emotion] ?? 0, value)
            }
        }

        guard let winner = scores.max(by: { $0.value < $1.value }) else {
            // 一个情绪词都没命中：这时标点只给一个「略高于中性」的保守值。
            // 旧版在这里把「！」一律判成 tense 0.7，是它最大的错源。
            if exclaim { return (.surprised, 0.45) }
            if question { return (.neutral, 0.35) }
            if ellipsis { return (.calm, 0.3) }
            return (.neutral, 0.3)
        }

        var intensity = winner.value
        if exclaim { intensity += 0.08 }
        if question { intensity += 0.04 }
        if ellipsis { intensity -= 0.05 }
        // 规则给的强度封顶 0.85：0.9~1.0 那一档要留给明确读过上下文的人或 LLM，
        // 规则没有上下文，越界给高值正是音频失控的条件。
        return (winner.key, min(0.85, max(0.2, intensity)))
    }

    /// 句内按标点切段。转折和否定都只在段内生效，跨段推断会把「他笑着，眼里却是泪」读平。
    private func splitClauses(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        for ch in text {
            if "。，、！？；：…～,.!?;: \n\u{201C}\u{201D}\u{2018}\u{2019}「」『』—-".contains(ch) {
                if !current.isEmpty { parts.append(current) }
                current = ""
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    /// 段内所有线索词，已按最长匹配去重，并乘上程度副词/否定的作用。
    private func cueHits(in clause: String) -> [CueHit] {
        var matches: [(range: Range<String.Index>, emotion: Emotion, weight: Double)] = []
        for (word, cue) in Self.lexicon {
            guard let range = clause.range(of: word) else { continue }
            matches.append((range, cue.0, cue.1))
        }
        // 最长优先：被更长的匹配整体包住的短词丢掉（「笑」在「苦笑」里不该再算一次 happy）。
        matches.sort { $0.range.lowerBound == $1.range.lowerBound
            ? $0.range.upperBound > $1.range.upperBound
            : $0.range.lowerBound < $1.range.lowerBound }
        var kept: [(range: Range<String.Index>, emotion: Emotion, weight: Double)] = []
        for m in matches where !(kept.last.map { m.range.upperBound <= $0.range.upperBound } ?? false) {
            kept.append(m)
        }

        return kept.map { m in
            var weight = m.weight
            if let degree = multiplier(in: clause, before: m.range.lowerBound, table: Self.degreeAdverbs, window: 4) {
                weight *= degree
            }
            if negated(in: clause, before: m.range.lowerBound) {
                weight *= 0.55
            }
            return CueHit(emotion: m.emotion, weight: weight)
        }
    }

    private func multiplier(
        in clause: String,
        before target: String.Index,
        table: [(String, Double)],
        window: Int
    ) -> Double? {
        var best: Double?
        for (word, factor) in table {
            guard let range = clause.range(of: word),
                  range.upperBound <= target,
                  clause.distance(from: range.upperBound, to: target) <= window
            else { continue }
            best = max(best ?? 0, factor)
        }
        return best
    }

    private func negated(in clause: String, before target: String.Index) -> Bool {
        for word in Self.negators {
            guard let range = clause.range(of: word),
                  range.upperBound <= target,
                  clause.distance(from: range.upperBound, to: target) <= 6
            else { continue }
            return true
        }
        return false
    }

    private func containsAny(_ text: String, _ words: [String]) -> Bool {
        for word in words where text.contains(word) { return true }
        return false
    }

    // MARK: - Speed Detection

    /// 以该情绪的整句目标语速为起点，再按标点做极小的调整。
    private func detectSpeed(from text: String, emotion: Emotion) -> Double {

        var speed = emotion.defaultSpeed

        if text.contains("……") || text.contains("...") {
            speed -= 0.03
        }

        return max(0.7, min(1.3, speed))
    }

    // MARK: - Pitch Detection

    private func detectPitch(_ emotion: Emotion) -> Double {
        max(-0.2, min(0.2, emotion.defaultPitch))
    }

    // MARK: - Voice Strength Detection

    /// 声音力度归规则，两条路径都调这里：正则标注自己用，LLM 校准完情绪也要用它
    /// 重算一遍（模型不再报这一列，留着旧情绪的默认档就是句尾泄气又回来了）。
    /// 命中提示语动词就用它，否则回该情绪的默认档；克制的取值压到 0.6 地板为止。
    static func voiceStrength(
        for text: String,
        emotion: Emotion
    ) -> Double {

        var strength = emotion.defaultVoiceStrength

        for (word, value) in softCues where text.contains(word) {
            strength = min(strength, value)
            return max(AITools.voiceStrengthFloor, min(1.0, strength))
        }
        for (word, value) in loudCues where text.contains(word) {
            strength = max(strength, value)
            break
        }

        return max(AITools.voiceStrengthFloor, min(1.0, strength))
    }
}
