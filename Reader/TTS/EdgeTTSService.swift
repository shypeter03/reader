//
//  EdgeTTSService.swift
//  Reader
//

import AVFoundation
import Foundation

actor EdgeTTSService: TTSService {

    // MARK: - Edge TTS Voices

    enum Voice {

        static let xiaoxiao = "zh-CN-XiaoxiaoNeural"
        static let yunxi = "zh-CN-YunxiNeural"
        static let yunyang = "zh-CN-YunyangNeural"
        static let xiaoyi = "zh-CN-XiaoyiNeural"
        static let yunjian = "zh-CN-YunjianNeural"

        static let all: [(id: String, gender: Gender)] = [
            (xiaoxiao, .female),
            (yunxi, .male),
            (yunyang, .male),
            (xiaoyi, .female),
            (yunjian, .male),
        ]
    }

    // MARK: - Properties

    private var rawWS: RawWebSocket?

    private var pendingRequests: [String: AsyncStream<WebSocketMessage>.Continuation] = [:]

    private var isConnected = false

    private var connectionID = UUID().uuidString

    // MARK: - TTSService

    func synthesize(
        text: String,
        voiceID: String,
        emotion: Emotion,
        intensity: Double,
        speed: Double,
        pitch: Double
    ) async throws -> Data {

        let voice = resolveVoice(voiceID)

        let (adjustedSpeed, adjustedPitch) = emotionAdjustment(
            emotion: emotion,
            intensity: intensity,
            baseSpeed: speed,
            basePitch: pitch
        )

        try await ensureConnected()

        let requestID = UUID().uuidString

        let ssml = buildSSML(
            text: text,
            voice: voice,
            speed: adjustedSpeed,
            pitch: adjustedPitch
        )

        let audioData = try await sendRequest(
            requestID: requestID,
            ssml: ssml
        )

        return audioData
    }

    // MARK: - Voice Resolution

    private func resolveVoice(_ voiceID: String) -> String {

        switch voiceID {

        case "narrator":
            return Voice.yunyang

        case "default", "":
            return Voice.xiaoxiao

        default:
            return voiceID
        }
    }

    // MARK: - Emotion Adjustment

    private func emotionAdjustment(
        emotion: Emotion,
        intensity: Double,
        baseSpeed: Double,
        basePitch: Double
    ) -> (speed: Double, pitch: Double) {

        let factor = max(0, min(1, intensity))

        let speedDelta: Double
        let pitchDelta: Double

        switch emotion {

        case .neutral:
            speedDelta = 0
            pitchDelta = 0

        case .happy, .excited:
            speedDelta = 0.1 * factor
            pitchDelta = 0.03 * factor

        case .sad:
            speedDelta = -0.1 * factor
            pitchDelta = -0.02 * factor

        case .angry:
            speedDelta = 0.15 * factor
            pitchDelta = 0.05 * factor

        case .surprised:
            speedDelta = 0.08 * factor
            pitchDelta = 0.06 * factor

        case .fearful, .tense:
            speedDelta = 0.1 * factor
            pitchDelta = 0.02 * factor

        case .calm:
            speedDelta = -0.08 * factor
            pitchDelta = -0.01 * factor
        }

        return (
            max(0.5, min(1.5, baseSpeed + speedDelta)),
            max(-0.2, min(0.2, basePitch + pitchDelta))
        )
    }

    // MARK: - SSML

    private func buildSSML(
        text: String,
        voice: String,
        speed: Double,
        pitch: Double
    ) -> String {

        let ratePercent = Int(speed * 100)
        let pitchSemitones = Int(pitch * 100)

        let escapedText = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")

        return """
        <speak version='1.0' xml:lang='zh-CN'>
        <voice name='\(voice)'>
        <prosody rate='\(ratePercent)%' pitch='\(pitchSemitones > 0 ? "+" : "")\(pitchSemitones)Hz'>
        \(escapedText)
        </prosody>
        </voice>
        </speak>
        """
    }

    // MARK: - WebSocket Connection

    private func ensureConnected() async throws {

        guard !isConnected else { return }

        var lastError: Error?

        for attempt in 1...3 {
            do {
                print("EdgeTTS 连接尝试 \(attempt)/3...")
                try await connect()
                print("EdgeTTS 连接成功")
                return
            } catch {
                print("EdgeTTS 连接失败 (尝试 \(attempt)): \(error)")
                lastError = error
                rawWS?.close()
                rawWS = nil
                isConnected = false

                if attempt < 3 {
                    try await Task.sleep(for: .seconds(1))
                }
            }
        }

        throw lastError ?? EdgeTTSError.connectionFailed
    }

    private func connect() async throws {

        rawWS?.close()

        connectionID = UUID().uuidString

        let host = "speech.platform.bing.com"
        let port: UInt16 = 443
        let path = "/consumer/speech/synthesize/read/boundary/edge/v1?trustedclienttoken=6A5AA1D4EAFF4E9FB37E23D68491D6F4&ConnectionId=\(connectionID)"

        let headers: [String: String] = [
            "Origin": "chrome-extension://jdicdacmpkdpkpgbhggbgahhciolbepb",
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"
        ]

        let ws = RawWebSocket()

        ws.onConnect = { [weak self] in
            Task { [weak self] in
                await self?.setConnected(true)
            }
        }

        ws.onMessage = { [weak self] data in
            Task { [weak self] in
                await self?.handleRawMessage(data)
            }
        }

        ws.onError = { [weak self] error in
            Task { [weak self] in
                await self?.handleError(error)
            }
        }

        ws.onDisconnect = { [weak self] in
            Task { [weak self] in
                await self?.handleDisconnect()
            }
        }

        rawWS = ws
        ws.connect(host: host, port: port, path: path, headers: headers)

        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(100))
            if isConnected { break }
        }

        guard isConnected else {
            throw EdgeTTSError.connectionFailed
        }

        let config = """
        {"context":{"synthesis":{"audio":{"metadataoptions":{"sentenceBoundaryEnabled":"false","wordBoundaryEnabled":"false"},"outputFormat":"audio-24khz-48kbitrate-mono-mp3"}}}}
        """

        let configMessage = "Path: speech.config\r\nContent-Type: application/json\r\n\r\n\(config)"

        rawWS?.sendText(configMessage)
    }

    private func handleRawMessage(_ data: Data) {
        let text = String(data: data, encoding: .utf8)
        if let text {
            parseTextMessage(text)
        } else {
            parseBinaryMessage(data)
        }
    }

    private func setConnected(_ connected: Bool) {
        isConnected = connected
    }

    private func handleError(_ error: Error) {
        isConnected = false
        for (_, continuation) in pendingRequests {
            continuation.yield(.error(error))
            continuation.finish()
        }
        pendingRequests.removeAll()
    }

    // MARK: - Send Request

    private func sendRequest(
        requestID: String,
        ssml: String
    ) async throws -> Data {

        guard let ws = rawWS, isConnected else {
            throw EdgeTTSError.notConnected
        }

        let (stream, continuation) = AsyncStream.makeStream(
            of: WebSocketMessage.self
        )

        pendingRequests[requestID] = continuation

        let textMessage = "Path: ssml\r\nX-RequestId: \(requestID)\r\nContent-Type: application/ssml+xml\r\n\r\n\(ssml)"

        ws.sendText(textMessage)

        var audioData = Data()

        do {

            for try await message in stream {

                switch message {

                case .audio(let data):
                    audioData.append(data)

                case .turnEnd:
                    pendingRequests.removeValue(forKey: requestID)
                    continuation.finish()
                    return audioData

                case .error(let error):
                    pendingRequests.removeValue(forKey: requestID)
                    continuation.finish()
                    throw error
                }
            }

        } catch {

            pendingRequests.removeValue(forKey: requestID)
            throw error
        }

        pendingRequests.removeValue(forKey: requestID)
        return audioData
    }

    // MARK: - Parse Messages

    private func parseTextMessage(_ text: String) {

        guard let requestID = extractHeader(
            from: text,
            name: "X-RequestId"
        ) else {
            return
        }

        if text.contains("Path:turn.end") || text.contains("Path: TurnEnd") {

            pendingRequests[requestID]?.yield(.turnEnd)
        }
    }

    private func parseBinaryMessage(_ data: Data) {

        let separator = Data([0x0D, 0x0A, 0x0D, 0x0A])

        guard let separatorRange = data.range(of: separator) else {
            return
        }

        let headerData = data[data.startIndex..<separatorRange.lowerBound]
        let audioData = data[separatorRange.upperBound...]

        guard let headerString = String(data: headerData, encoding: .utf8) else {
            return
        }

        guard let requestID = extractHeader(
            from: headerString,
            name: "X-RequestId"
        ) else {
            return
        }

        if audioData.isEmpty {

            if headerString.contains("Path:turn.end") || headerString.contains("Path: TurnEnd") {

                pendingRequests[requestID]?.yield(.turnEnd)
            }

        } else {

            pendingRequests[requestID]?.yield(.audio(Data(audioData)))
        }
    }

    private func extractHeader(
        from text: String,
        name: String
    ) -> String? {

        let lines = text.components(separatedBy: "\r\n")

        for line in lines {

            if line.hasPrefix("\(name):") {

                return line
                    .dropFirst("\(name):".count)
                    .trimmingCharacters(in: .whitespaces)
            }
        }

        return nil
    }

    // MARK: - Disconnect

    private func handleDisconnect() {

        isConnected = false

        rawWS = nil

        for (_, continuation) in pendingRequests {

            continuation.yield(.error(EdgeTTSError.disconnected))
            continuation.finish()
        }

        pendingRequests.removeAll()
    }

    // MARK: - Cleanup

    func disconnect() {

        rawWS?.close()
        rawWS = nil
        isConnected = false

        for (_, continuation) in pendingRequests {
            continuation.finish()
        }

        pendingRequests.removeAll()
    }
}

// MARK: - Supporting Types

private enum WebSocketMessage {

    case audio(Data)
    case turnEnd
    case error(Error)
}
