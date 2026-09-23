//
//  SpeechAudioBridge.swift
//  Reader
//
//  Created by 粟海洋 on 2026/8/28.
//

//
//  SpeechAudioBridge.swift
//  Reader
//

import Foundation
import AVFoundation

@MainActor
final class SpeechAudioBridge {

    private var audioFile: AVAudioFile?
    private var outputURL: URL?

    private var continuation:
        CheckedContinuation<Data, Error>?

    private var finished = false

    private init(
        continuation:
            CheckedContinuation<Data, Error>
    ) {

        self.continuation = continuation
    }

    static func synthesize(
        synthesizer: AVSpeechSynthesizer,
        utterance: AVSpeechUtterance
    ) async throws -> Data {

        try await withCheckedThrowingContinuation {
            continuation in

            let bridge =
                SpeechAudioBridge(
                    continuation: continuation
                )

            bridge.start(
                synthesizer: synthesizer,
                utterance: utterance
            )
        }
    }

    private func start(
        synthesizer: AVSpeechSynthesizer,
        utterance: AVSpeechUtterance
    ) {

        synthesizer.write(
            utterance
        ) { [weak self] buffer in

            Task { @MainActor [weak self] in

                guard let self else {
                    return
                }

                self.handle(
                    buffer
                )
            }
        }
    }

    private func handle(
            _ buffer: AVAudioBuffer
        ) {
            guard !finished else {
                return
            }

            guard let pcmBuffer = buffer as? AVAudioPCMBuffer else {
                return
            }

            // 1. 如果是结束帧（frameLength == 0），立即完成
            if pcmBuffer.frameLength == 0 {
                finish()
                return
            }

            // 2. 如果数据大小为 0，这只是一个空控制帧，不能写入文件，但千万不能直接 return 导致后续无法收尾
            guard pcmBuffer.audioBufferList.pointee.mBuffers.mDataByteSize > 0 else {
                return // 仅跳过当前空 buffer，不影响整体流程
            }

            do {
                if audioFile == nil {
                    let url = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString)
                        .appendingPathExtension("caf")

                    outputURL = url

                    audioFile = try AVAudioFile(
                        forWriting: url,
                        settings: pcmBuffer.format.settings
                    )
                }

                try audioFile?.write(from: pcmBuffer)

            } catch {
                fail(error)
            }
        }

    private func finish() {

        guard !finished else {
            return
        }

        finished = true

        guard
            let outputURL
        else {

            continuation?.resume(
                returning: Data()
            )

            continuation = nil

            return
        }

        do {

            guard
                let data =
                    try? Data(
                        contentsOf: outputURL
                    ),
                !data.isEmpty
            else {

                cleanup()

                continuation?.resume(
                    throwing:
                        TTSError.emptyAudio
                )

                continuation = nil

                return
            }

            cleanup()

            continuation?.resume(
                returning: data
            )

            continuation = nil

        }
    }

    private func fail(
        _ error: Error
    ) {

        guard !finished else {
            return
        }

        finished = true

        cleanup()

        continuation?.resume(
            throwing: error
        )

        continuation = nil
    }

    private func cleanup() {

        audioFile = nil

        if let outputURL {

            try? FileManager.default
                .removeItem(
                    at: outputURL
                )
        }

        outputURL = nil
    }
}

private enum TTSError: Error {
    case emptyText
    case emptyAudio
    case invalidAudioBuffer
}
