//
//  Chapter.swift
//  Reader
//
//  Created by 粟海洋 on 2026/8/26.
//

import Foundation

enum AudioGenerationStatus: String, Codable, Sendable {
    case pending
    case analyzing
    case generating
    case completed
    case failed
}

/// 正文、AI 标注与音频是三份独立资源；任何增强资源失败都不能阻塞正文。
enum TextStatus: String, Codable, Sendable { case available }
enum AnalysisStatus: String, Codable, Sendable { case pending, running, completed, failed }
enum TTSStatus: String, Codable, Sendable { case pending, running, partial, completed, failed }

struct Chapter: Identifiable, Codable, Sendable {

    let id: UUID

    var index: Int

    var title: String

    var sentences: [Sentence]

    var characters: [Character]

    var audioStatus: AudioGenerationStatus

    var textStatus: TextStatus
    var analysisStatus: AnalysisStatus
    var ttsStatus: TTSStatus

    /// 正文是按哪一版断句规则切出来的。读路径会直接用落库的正文，不再每次点开
    /// 都跑 parser，所以规则一变就得有个东西认出旧数据——对不上的章节重解析一次。
    var textVersion: Int

    init(
        id: UUID = UUID(),
        index: Int,
        title: String,
        sentences: [Sentence] = [],
        characters: [Character] = [],
        audioStatus: AudioGenerationStatus = .pending,
        textStatus: TextStatus = .available,
        analysisStatus: AnalysisStatus = .pending,
        ttsStatus: TTSStatus = .pending,
        textVersion: Int = SentenceSplitter.textVersion
    ) {
        self.id = id
        self.index = index
        self.title = title
        self.sentences = sentences
        self.characters = characters
        self.audioStatus = audioStatus
        self.textStatus = textStatus
        self.analysisStatus = analysisStatus
        self.ttsStatus = ttsStatus
        self.textVersion = textVersion
    }

    enum CodingKeys: String, CodingKey {
        case id, index, title, sentences, characters, audioStatus
        case textStatus, analysisStatus, ttsStatus, textVersion
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        index = try c.decode(Int.self, forKey: .index)
        title = try c.decode(String.self, forKey: .title)
        sentences = try c.decode([Sentence].self, forKey: .sentences)
        characters = try c.decode([Character].self, forKey: .characters)
        audioStatus = try c.decodeIfPresent(AudioGenerationStatus.self, forKey: .audioStatus) ?? .pending
        textStatus = try c.decodeIfPresent(TextStatus.self, forKey: .textStatus) ?? .available
        analysisStatus = try c.decodeIfPresent(AnalysisStatus.self, forKey: .analysisStatus) ?? .pending
        ttsStatus = try c.decodeIfPresent(TTSStatus.self, forKey: .ttsStatus) ?? .pending
        // 缺字段就是「规则改过之前存的」，不能沿用当前版本号：兜底成 0 让它重解析一次。
        textVersion = try c.decodeIfPresent(Int.self, forKey: .textVersion) ?? 0
    }
}
