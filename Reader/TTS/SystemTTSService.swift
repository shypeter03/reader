//
//  SystemTTSService.swift
//  Reader
//

import AVFoundation

actor SystemTTSService: TTSService {

    func synthesize(
        text: String,
        voiceID: String,
        emotion: Emotion,
        intensity: Double,
        speed: Double,
        pitch: Double
    ) async throws -> Data {

        let sanitizedText = Self.sanitizeText(text)

        let trimmedText = sanitizedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            return Data()
        }

        let utterance = AVSpeechUtterance(string: trimmedText)

        // Voice
        if !voiceID.isEmpty,
           voiceID != "default",
           voiceID != "narrator",
           let voice = AVSpeechSynthesisVoice(identifier: voiceID) {
            utterance.voice = voice
        } else {
            utterance.voice = AVSpeechSynthesisVoice(identifier: VoiceManager.fallbackVoice())
        }

        // Emotion-based adjustments
        let (emotionSpeed, emotionPitch) = Self.emotionAdjustment(for: emotion, intensity: intensity)

        let adjustedSpeed = speed * emotionSpeed
        let adjustedPitch = pitch + emotionPitch

        utterance.rate = Self.convertSpeed(adjustedSpeed)
        utterance.pitchMultiplier = Float(
            max(0.5, min(2.0, 1.0 + adjustedPitch))
        )

        // Post-sentence pause
        utterance.postUtteranceDelay = 0.15

        return try await synthesizeToData(utterance)
    }

    // MARK: - Emotion Adjustments

    private static func emotionAdjustment(
        for emotion: Emotion,
        intensity: Double
    ) -> (speed: Double, pitch: Double) {

        let factor = max(0, min(1, intensity))

        switch emotion {

        case .neutral:
            return (1.0, 0.0)

        case .happy, .excited:
            return (1.0 + 0.15 * factor, 0.05 * factor)

        case .sad:
            return (1.0 - 0.15 * factor, -0.05 * factor)

        case .angry:
            return (1.0 + 0.2 * factor, 0.08 * factor)

        case .surprised:
            return (1.0 + 0.1 * factor, 0.1 * factor)

        case .fearful, .tense:
            return (1.0 + 0.12 * factor, 0.03 * factor)

        case .calm:
            return (1.0 - 0.1 * factor, -0.03 * factor)
        }
    }

    // MARK: - Speed Conversion

    private static func convertSpeed(_ speed: Double) -> Float {
        return Float(
            max(
                AVSpeechUtteranceMinimumSpeechRate,
                min(
                    AVSpeechUtteranceMaximumSpeechRate,
                    Float(speed * Double(AVSpeechUtteranceDefaultSpeechRate))
                )
            )
        )
    }

    // MARK: - Text Sanitization

    private nonisolated static func sanitizeText(_ input: String) -> String {
        var text = input

        text = text.replacingOccurrences(of: "\\", with: " ")
        text = text.replacingOccurrences(of: "-\\Y", with: " ")
        text = text.replacingOccurrences(of: "\\Yo", with: " ")

        return text
    }

    // MARK: - Synthesis to Data

    private nonisolated func synthesizeToData(_ utterance: AVSpeechUtterance) async throws -> Data {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("caf")

        let localSynthesizer = AVSpeechSynthesizer()

        return try await withCheckedThrowingContinuation { continuation in
            var audioFile: AVAudioFile? = nil
            var hasResumed = false

            let safeResumeOnce: (Result<Data, Error>) -> Void = { result in
                guard !hasResumed else { return }
                hasResumed = true
                continuation.resume(with: result)
            }

            localSynthesizer.write(utterance) { buffer in
                guard let pcmBuffer = buffer as? AVAudioPCMBuffer else {
                    return
                }

                if pcmBuffer.frameLength == 0 {
                    audioFile = nil

                    do {
                        let fileManager = FileManager.default
                        if fileManager.fileExists(atPath: tempURL.path) {
                            let fileAttributes = try fileManager.attributesOfItem(atPath: tempURL.path)
                            let fileSize = fileAttributes[.size] as? Int64 ?? 0

                            if fileSize > 0 {
                                let data = try Data(contentsOf: tempURL)
                                try? fileManager.removeItem(at: tempURL)
                                safeResumeOnce(.success(data))
                            } else {
                                try? fileManager.removeItem(at: tempURL)
                                safeResumeOnce(.success(Data()))
                            }
                        } else {
                            safeResumeOnce(.success(Data()))
                        }
                    } catch {
                        try? FileManager.default.removeItem(at: tempURL)
                        safeResumeOnce(.failure(error))
                    }
                    return
                }

                guard pcmBuffer.audioBufferList.pointee.mBuffers.mDataByteSize > 0 else {
                    return
                }

                do {
                    if audioFile == nil {
                        audioFile = try AVAudioFile(
                            forWriting: tempURL,
                            settings: pcmBuffer.format.settings
                        )
                    }
                    try audioFile?.write(from: pcmBuffer)
                } catch {
                    audioFile = nil
                    try? FileManager.default.removeItem(at: tempURL)
                    safeResumeOnce(.failure(error))
                }
            }
        }
    }
}
