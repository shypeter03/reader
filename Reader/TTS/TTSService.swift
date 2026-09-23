//
//  TTSService.swift
//  Reader
//
//  Created by 粟海洋 on 2026/8/26.
//

import Foundation

protocol TTSService: Sendable {

    func synthesize(
        text: String,
        voiceID: String,
        emotion: Emotion,
        intensity: Double,
        speed: Double,
        pitch: Double
    ) async throws -> Data
}
