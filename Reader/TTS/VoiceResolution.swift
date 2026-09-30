//
//  VoiceResolution.swift
//  Reader
//
//  「这句话由谁来说」的唯一口径。
//
//  为什么单独一份：三处都要问它，而且答案必须一模一样——
//  - 合成前（``TTSGenerator``）：查音频缓存命中后还要核对声音，不对就删了重录；
//  - 开章时（``ReaderPipeline`` 的过期检查）：句子已经 `.completed` 就永远不会再排产，
//    不在这里开口子，人物档案补齐之前录错的那半本书会一直错下去；
//  - 标注改动后（同文件的 diff 判断）：换人才需要重录，换情绪不需要。
//  它必须**不碰任何 actor、不碰 GPU、不碰模型**：开章那 1 秒预算里也要调它。
//
//  返回的是 ``VoiceManager`` 那套 speaker 名——全 App 的声音身份，
//  Edge/Kokoro/Qwen3 三个后端各自翻译，这里只认名字。
//

import Foundation

enum VoiceResolution {

    /// 旁白 → 唯一那把讲述声；认得出男女的人 → 档案里钉死的那把；
    /// **其余全部还是那把讲述声**。
    ///
    /// 后半句是这条链的不变式，也是「旁白前后必须是一个人」的实现：只有「书级档案里
    /// 判得出性别的那个人」才拿得到区别于旁白的嗓，其余一律由旁白念。以前这一格落到
    /// 一把独立的无名嗓上，于是「有引号但认不出是谁说的」那一大批句子（真书实测占正文
    /// 一到两成）全在旁白中间换人——耳朵里就是「这一句旁白 A、下一句旁白 B」。
    /// 顺带把判定的后果也兜住了：万一「这句到底有没有人说话」看走眼，代价从
    /// 「换成别人的嗓」降成「没人换嗓」，听感不再依赖提取精度。
    static func resolve(sentence: Sentence, chapter: Chapter, bookID: UUID) -> String {
        guard sentence.speaker == .character else {
            return VoiceManager.narratorVoice()
        }
        guard let characterID = sentence.characterID,
              let character = chapter.characters.first(where: { $0.id == characterID })
        else {
            return VoiceManager.narratorVoice()
        }

        // 书级人物档案排在章内 Character 之前：它是扫完整本书的结论，而且同名一定同名，
        // 不会像章内那份那样每章各判一次性别、换一章换个嗓。
        let name = sentence.characterName ?? character.name
        if let voice = CharacterRoster.shared.voice(bookID: bookID, name: name) {
            return voice
        }

        // 手工指定过的声音（老数据里可能有）仍然优先于按性别现算。
        if let existing = character.voiceID, !existing.isEmpty, existing != "default" {
            return existing
        }

        return VoiceManager.voiceForCharacter(name: name, gender: character.gender)
    }

    /// 音频文件在「还没有人物档案」那套口径下会用哪把声音：旁白 Uncle_Fu，其余一律
    /// 无名那把（那时章内性别恒为 unknown）。老 chapter.json 没有 `recordedVoiceID`，
    /// 判过期只能按这条折算——按「没记就是错的」处理会把整本书好端端的旁白全重录一遍。
    static func legacy(for sentence: Sentence) -> String {
        sentence.speaker == .narrator
            ? VoiceManager.narratorVoice()
            : VoiceManager.unnamedVoice()
    }
}
