//
//  Character.swift
//  Reader
//
//  Created by 粟海洋 on 2026/8/26.
//

import Foundation

enum Gender: String, Codable, Sendable {
    case male
    case female
    case unknown
}

enum AgeType: String, Codable, Sendable {
    case child
    case young
    case adult
    case middleAged
    case old
    case unknown
}

struct Character: Identifiable, Codable, Hashable, Sendable {

    let id: UUID

    var name: String

    var gender: Gender

    var age: AgeType

    var voiceID: String?

    var description: String?

    init(
        id: UUID = UUID(),
        name: String,
        gender: Gender = .unknown,
        age: AgeType = .unknown,
        voiceID: String? = nil,
        description: String? = nil
    ) {
        self.id = id
        self.name = name
        self.gender = gender
        self.age = age
        self.voiceID = voiceID
        self.description = description
    }
}
