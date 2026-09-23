//
//  RawWebSocket.swift
//  Reader
//

import CryptoKit
import Foundation
import Network

final class RawWebSocket: @unchecked Sendable {

    private var connection: NWConnection?

    private var isClosed = false

    var onConnect: (() -> Void)?

    var onMessage: ((Data) -> Void)?

    var onError: ((Error) -> Void)?

    var onDisconnect: (() -> Void)?

    // MARK: - Connect

    func connect(host: String, port: UInt16, path: String, headers: [String: String]) {

        let tls = NWProtocolTLS.Options()

        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.noDelay = true

        let params = NWParameters(tls: tls, tcp: tcp)

        let nwConnection = NWConnection(
            to: NWEndpoint.hostPort(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(integerLiteral: port)
            ),
            using: params
        )

        connection = nwConnection

        nwConnection.stateUpdateHandler = { [weak self] state in

            guard let self else { return }

            switch state {

            case .ready:
                print("RawWebSocket: TCP 连接就绪，开始握手")
                self.performHandshake(
                    host: host,
                    path: path,
                    headers: headers
                )

            case .failed(let error):
                print("RawWebSocket: 连接失败 - \(error)")
                self.isClosed = true
                self.onError?(error)

            case .cancelled:
                print("RawWebSocket: 连接已取消")
                self.isClosed = true
                self.onDisconnect?()

            case .preparing:
                print("RawWebSocket: 准备连接...")

            case .waiting(let error):
                print("RawWebSocket: 等待连接 - \(error)")

            default:
                print("RawWebSocket: 状态变化 - \(state)")
            }
        }

        nwConnection.start(queue: .global(qos: .userInitiated))
    }

    // MARK: - Handshake

    private func performHandshake(
        host: String,
        path: String,
        headers: [String: String]
    ) {

        let key = generateWebSocketKey()

        var request = "GET \(path) HTTP/1.1\r\n"
        request += "Host: \(host)\r\n"
        request += "Upgrade: websocket\r\n"
        request += "Connection: Upgrade\r\n"
        request += "Sec-WebSocket-Key: \(key)\r\n"
        request += "Sec-WebSocket-Version: 13\r\n"

        for (name, value) in headers {
            request += "\(name): \(value)\r\n"
        }

        request += "\r\n"

        guard let data = request.data(using: .utf8) else { return }

        sendRaw(data: data)

        receiveHandshakeResponse(expectedKey: key)
    }

    private func receiveHandshakeResponse(expectedKey: String) {

        receiveLine { [weak self] result in

            guard let self else { return }

            switch result {

            case .success(let response):
                print("RawWebSocket: 收到握手响应")

                if response.contains("101") {
                    print("RawWebSocket: 握手成功 (101)")
                    self.onConnect?()
                    self.startReceiveLoop()
                } else {
                    print("RawWebSocket: 握手失败 - \(response.prefix(200))")
                    self.onError?(EdgeTTSError.handshakeFailed(response))
                }

            case .failure(let error):
                print("RawWebSocket: 读取握手响应失败 - \(error)")
                self.onError?(error)
            }
        }
    }

    private func receiveLine(completion: @escaping (Result<String, Error>) -> Void) {

        var buffer = Data()

        func readMore() {

            guard let connection, !isClosed else {
                completion(.failure(EdgeTTSError.disconnected))
                return
            }

            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, error in

                if let data, !data.isEmpty {
                    buffer.append(data)
                }

                if isComplete {
                    completion(.failure(EdgeTTSError.disconnected))
                    return
                }

                if let error {
                    completion(.failure(error))
                    return
                }

                if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {

                    let headerData = buffer[buffer.startIndex..<range.lowerBound]

                    if let response = String(data: headerData, encoding: .utf8) {
                        completion(.success(response))
                    } else {
                        completion(.failure(EdgeTTSError.invalidResponse))
                    }

                    let remaining = Data(buffer[range.upperBound...])

                    if !remaining.isEmpty {
                        self.handleReceivedData(remaining)
                    }

                    return
                }

                readMore()
            }
        }

        readMore()
    }

    // MARK: - Receive Loop

    private func startReceiveLoop() {

        receiveFrame()
    }

    private func receiveFrame() {

        guard let connection, !isClosed else { return }

        connection.receive(minimumIncompleteLength: 2, maximumLength: 65536) { [weak self] data, _, isComplete, error in

            guard let self else { return }

            if let error {
                self.isClosed = true
                self.onError?(error)
                return
            }

            if isComplete {
                self.isClosed = true
                self.onDisconnect?()
                return
            }

            guard let data, data.count >= 2 else {
                self.receiveFrame()
                return
            }

            self.parseFrame(data: data)
        }
    }

    private func parseFrame(data: Data) {

        var offset = 0

        guard data.count >= 2 else {
            receiveFrame()
            return
        }

        let firstByte = data[offset]
        offset += 1

        let secondByte = data[offset]
        offset += 1

        let opcode = firstByte & 0x0F
        let isMasked = (secondByte & 0x80) != 0

        var payloadLength = UInt64(secondByte & 0x7F)

        if payloadLength == 126 {

            guard data.count >= offset + 2 else {
                receiveFrame()
                return
            }

            payloadLength = UInt64(data[offset]) << 8 | UInt64(data[offset + 1])
            offset += 2

        } else if payloadLength == 127 {

            guard data.count >= offset + 8 else {
                receiveFrame()
                return
            }

            payloadLength = 0

            for i in 0..<8 {
                payloadLength = (payloadLength << 8) | UInt64(data[offset + i])
            }

            offset += 8
        }

        var maskingKey: Data?

        if isMasked {

            guard data.count >= offset + 4 else {
                receiveFrame()
                return
            }

            maskingKey = Data(data[offset..<offset + 4])
            offset += 4
        }

        let length = Int(payloadLength)

        guard data.count >= offset + length else {
            receiveFrame()
            return
        }

        var payload = Data(data[offset..<offset + length])

        if let maskingKey {

            for i in 0..<payload.count {
                payload[i] ^= maskingKey[i % 4]
            }
        }

        handleFrame(opcode: opcode, payload: payload)

        receiveFrame()
    }

    private func handleFrame(opcode: UInt8, payload: Data) {

        switch opcode {

        case 0x01:
            onMessage?(payload)

        case 0x02:
            onMessage?(payload)

        case 0x08:
            isClosed = true
            connection?.cancel()
            onDisconnect?()

        case 0x09:
            sendPong(payload)

        default:
            break
        }
    }

    private func handleReceivedData(_ data: Data) {

        var offset = 0

        while offset < data.count {

            guard offset + 2 <= data.count else { break }

            let firstByte = data[offset]
            offset += 1

            let secondByte = data[offset]
            offset += 1

            let opcode = firstByte & 0x0F
            let isMasked = (secondByte & 0x80) != 0

            var payloadLength = UInt64(secondByte & 0x7F)

            if payloadLength == 126 {

                guard offset + 2 <= data.count else { break }

                payloadLength = UInt64(data[offset]) << 8 | UInt64(data[offset + 1])
                offset += 2

            } else if payloadLength == 127 {

                guard offset + 8 <= data.count else { break }

                payloadLength = 0

                for i in 0..<8 {
                    payloadLength = (payloadLength << 8) | UInt64(data[offset + i])
                }

                offset += 8
            }

            if isMasked {
                offset += 4
            }

            let length = Int(payloadLength)

            guard offset + length <= data.count else { break }

            let payload = Data(data[offset..<offset + length])
            offset += length

            handleFrame(opcode: opcode, payload: payload)
        }
    }

    // MARK: - Send

    func sendText(_ text: String) {

        guard let data = text.data(using: .utf8) else { return }

        sendFrame(opcode: 0x01, payload: data)
    }

    private func sendFrame(opcode: UInt8, payload: Data) {

        var frame = Data()

        frame.append(0x80 | opcode)

        let length = payload.count

        let maskingKey = generateMaskingKey()

        if length < 126 {

            frame.append(UInt8(length) | 0x80)

        } else if length < 65536 {

            frame.append(126 | 0x80)
            frame.append(UInt8((length >> 8) & 0xFF))
            frame.append(UInt8(length & 0xFF))

        } else {

            frame.append(127 | 0x80)

            for i in (0..<8).reversed() {
                frame.append(UInt8((length >> (i * 8)) & 0xFF))
            }
        }

        frame.append(maskingKey)

        var maskedPayload = payload

        for i in 0..<maskedPayload.count {
            maskedPayload[i] ^= maskingKey[i % 4]
        }

        frame.append(maskedPayload)

        sendRaw(data: frame)
    }

    private func sendPong(_ payload: Data) {

        sendFrame(opcode: 0x0A, payload: payload)
    }

    private func sendRaw(data: Data) {

        guard let connection, !isClosed else { return }

        connection.send(
            content: data,
            completion: .contentProcessed { error in
                if let error {
                    print("RawWebSocket send error: \(error)")
                }
            }
        )
    }

    // MARK: - Close

    func close() {

        guard !isClosed else { return }

        isClosed = true

        sendFrame(opcode: 0x08, payload: Data([0x03, 0xE8]))

        connection?.cancel()
        connection = nil
    }

    // MARK: - Helpers

    private func generateWebSocketKey() -> String {

        var bytes = [UInt8](repeating: 0, count: 16)

        for i in 0..<16 {
            bytes[i] = UInt8.random(in: 0...255)
        }

        return Data(bytes).base64EncodedString()
    }

    private func generateMaskingKey() -> Data {

        var bytes = [UInt8](repeating: 0, count: 4)

        for i in 0..<4 {
            bytes[i] = UInt8.random(in: 0...255)
        }

        return Data(bytes)
    }
}

// MARK: - EdgeTTS Error

enum EdgeTTSError: Error, LocalizedError {

    case handshakeFailed(String)
    case disconnected
    case invalidResponse
    case connectionFailed
    case noAudioData
    case notConnected

    var errorDescription: String? {

        switch self {

        case .handshakeFailed(let response):
            return "EdgeTTS 握手失败: \(response)"

        case .disconnected:
            return "EdgeTTS 连接断开"

        case .invalidResponse:
            return "EdgeTTS 无效响应"

        case .connectionFailed:
            return "EdgeTTS 连接失败，请检查网络连接"

        case .noAudioData:
            return "EdgeTTS 未返回音频数据"

        case .notConnected:
            return "EdgeTTS 未连接"
        }
    }
}
