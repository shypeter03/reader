//
//  AudioSegment.swift
//  Reader
//
//  Created by 粟海洋 on 2026/8/26.
//

import Foundation

struct AudioSegment: Identifiable, Codable, Sendable {

    let id: UUID

    let sentenceID: UUID

    let url: URL

    let duration: Double

    var startTime: Double

    var endTime: Double
}
