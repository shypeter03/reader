//
//  FastChapterAnalyzer.swift
//  Reader
//
//  Created by 粟海洋 on 2026/9/21.
//

import Foundation

actor FastChapterAnalyzer {

    // MARK: - Analyze

    func analyze(
        chapter: Chapter,
        context: StoryContext
    ) async throws -> Chapter {

        var chapter = chapter

        chapter.audioStatus = .analyzing

        for index in chapter.sentences.indices {
            chapter.sentences[index] = annotate(chapter.sentences[index], in: &chapter)
        }

        chapter.audioStatus = .pending

        return chapter
    }

    /// 只标注「尚无参数」的句子并返回快照：这些句子随即可以送进 TTS，
    /// 开播不必等 LLM。已有参数的句子（可能来自 LLM 校准）原样保留，
    /// 避免每次翻章把更好的标注退回正则结果。
    /// 传 `range` 可把标注限制在播放位置附近：远处的句子留给 LLM 定参数，
    /// 正则那套强情绪指令不该抢先决定整章的听感。
    func prime(_ chapter: Chapter, in range: Range<Int>? = nil) -> Chapter {

        var chapter = chapter

        let lower = max(0, range?.lowerBound ?? 0)
        let upper = min(chapter.sentences.count, range?.upperBound ?? chapter.sentences.count)
        guard lower < upper else { return chapter }

        for index in lower..<upper
        where chapter.sentences[index].analysisStatus != .completed {
            chapter.sentences[index] = annotate(chapter.sentences[index], in: &chapter)
        }

        return chapter
    }

    private func annotate(
        _ sentence: Sentence,
        in chapter: inout Chapter
    ) -> Sentence {

        let analysis = analyzeSentence(sentence.text)
        var updated = sentence

        updated.type = analysis.type
        updated.speaker = analysis.speaker
        updated.characterName = analysis.characterName
        updated.emotion = analysis.emotion
        updated.emotionIntensity = analysis.emotionIntensity
        updated.speed = analysis.speed
        updated.pitch = analysis.pitch
        updated.voiceStrength = analysis.voiceStrength
        updated.analysisStatus = .completed

        if analysis.speaker == .character,
           let characterName = analysis.characterName {

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

    private func analyzeSentence(_ text: String) -> SentenceAnalysis {

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
            return analyzeDialogue(trimmed)
        } else {
            return analyzeNarration(trimmed)
        }
    }

    // MARK: - Dialogue Detection

    private func containsDialogue(_ text: String) -> Bool {

        let dialoguePatterns = [
            "\u{201C}[^\u{201D}]*\u{201D}",
            "\u{2018}[^\u{2019}]*\u{2019}",
            "\u{300C}[^\u{300D}]*\u{300D}",
            "\u{300E}[^\u{300F}]*\u{300F}"
        ]

        for pattern in dialoguePatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                let range = NSRange(text.startIndex..<text.endIndex, in: text)
                if regex.firstMatch(in: text, options: [], range: range) != nil {
                    return true
                }
            }
        }

        return false
    }

    // MARK: - Dialogue Analysis

    private func analyzeDialogue(_ text: String) -> SentenceAnalysis {

        var speakerName: String? = nil

        let speakerPatterns = [
            "([^，。！？\\s]{1,10})说道[：:]",
            "([^，。！？\\s]{1,10})说[：:]",
            "([^，。！？\\s]{1,10})问道[：:]",
            "([^，。！？\\s]{1,10})问[：:]",
            "([^，。！？\\s]{1,10})喊道[：:]",
            "([^，。！？\\s]{1,10})喊[：:]",
            "([^，。！？\\s]{1,10})叫道[：:]",
            "([^，。！？\\s]{1,10})叫[：:]",
            "([^，。！？\\s]{1,10})答道[：:]",
            "([^，。！？\\s]{1,10})答[：:]"
        ]

        for pattern in speakerPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                let range = NSRange(text.startIndex..<text.endIndex, in: text)
                if let match = regex.firstMatch(in: text, options: [], range: range) {
                    if let nameRange = Range(match.range(at: 1), in: text) {
                        speakerName = String(text[nameRange])
                        break
                    }
                }
            }
        }

        let emotion = detectEmotion(from: text)
        let intensity = detectIntensity(from: text, emotion: emotion)
        let speed = detectSpeed(from: text, emotion: emotion)
        let pitch = detectPitch(from: text, emotion: emotion)
        let voiceStrength = detectVoiceStrength(from: text, emotion: emotion)

        return SentenceAnalysis(
            type: .dialogue,
            speaker: .character,
            characterName: speakerName,
            emotion: emotion,
            emotionIntensity: intensity,
            speed: speed,
            pitch: pitch,
            voiceStrength: voiceStrength
        )
    }

    // MARK: - Narration Analysis

    private func analyzeNarration(_ text: String) -> SentenceAnalysis {

        let emotion = detectEmotion(from: text)
        let intensity = detectIntensity(from: text, emotion: emotion)
        let speed = detectSpeed(from: text, emotion: emotion)
        let pitch = detectPitch(from: text, emotion: emotion)
        let voiceStrength = detectVoiceStrength(from: text, emotion: emotion)

        return SentenceAnalysis(
            type: .narration,
            speaker: .narrator,
            characterName: nil,
            emotion: emotion,
            emotionIntensity: intensity,
            speed: speed,
            pitch: pitch,
            voiceStrength: voiceStrength
        )
    }

    // MARK: - Emotion Detection

    private func detectEmotion(from text: String) -> Emotion {

        if text.contains("！") || text.contains("!") {
            if containsKeywords(text, ["怒", "恨", "愤"]) {
                return .angry
            } else if containsKeywords(text, ["惊", "啊", "哇"]) {
                return .surprised
            } else if containsKeywords(text, ["快", "乐", "喜", "笑"]) {
                return .excited
            } else {
                return .tense
            }
        }

        if text.contains("？") || text.contains("?") {
            return .surprised
        }

        if text.contains("……") || text.contains("...") {
            if containsKeywords(text, ["泪", "哭", "悲", "伤"]) {
                return .sad
            } else {
                return .calm
            }
        }

        if containsKeywords(text, ["笑", "喜", "乐", "欢", "开心", "高兴"]) {
            return .happy
        }

        if containsKeywords(text, ["哭", "泪", "悲", "伤", "痛", "哀"]) {
            return .sad
        }

        if containsKeywords(text, ["怒", "恨", "愤", "气"]) {
            return .angry
        }

        if containsKeywords(text, ["惊", "吓", "怕", "恐"]) {
            return .fearful
        }

        if containsKeywords(text, ["紧", "急", "快", "冲"]) {
            return .tense
        }

        if containsKeywords(text, ["静", "安", "平", "缓"]) {
            return .calm
        }

        return .neutral
    }

    private func containsKeywords(_ text: String, _ keywords: [String]) -> Bool {
        for keyword in keywords {
            if text.contains(keyword) {
                return true
            }
        }
        return false
    }

    // MARK: - Intensity Detection

    private func detectIntensity(from text: String, emotion: Emotion) -> Double {

        var intensity = 0.3

        let exclamationCount = text.filter { $0 == "！" || $0 == "!" }.count
        intensity += Double(exclamationCount) * 0.2

        let questionCount = text.filter { $0 == "？" || $0 == "?" }.count
        intensity += Double(questionCount) * 0.1

        if text.contains("……") || text.contains("...") {
            intensity -= 0.1
        }

        switch emotion {
        case .angry, .surprised, .excited, .fearful, .tense:
            intensity += 0.2
        case .happy:
            intensity += 0.1
        case .sad, .calm, .neutral:
            break
        }

        return max(0.0, min(1.0, intensity))
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

    private func detectPitch(from text: String, emotion: Emotion) -> Double {
        max(-0.2, min(0.2, emotion.defaultPitch))
    }

    // MARK: - Voice Strength Detection

    /// 声音力度不跟随情绪强度：克制的情绪照样要中气充足。
    /// 只有明确的轻声/耳语线索才往下调，并且不越过 AITools 的地板值。
    private func detectVoiceStrength(from text: String, emotion: Emotion) -> Double {

        var strength = emotion.defaultVoiceStrength

        if containsKeywords(text, ["轻声", "低声", "小声", "耳语", "悄悄", "喃喃"]) {
            strength -= 0.15
        }

        return max(AITools.voiceStrengthFloor, min(1.0, strength))
    }
}
