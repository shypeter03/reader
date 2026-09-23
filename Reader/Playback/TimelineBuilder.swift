//
//  TimelineBuilder.swift
//  Reader
//
//  Created by 粟海洋 on 2026/8/26.
//

import Foundation

struct TimelineBuilder {

    static func build(
        from chapter: Chapter
    ) -> [AudioSegment] {

        var result: [AudioSegment] = []

        var currentTime: Double = 0

        for sentence in chapter.sentences {

            guard
                let url = sentence.audioURL,
                let duration = sentence.duration
            else {
                continue
            }

            let segment =
                AudioSegment(
                    id: UUID(),
                    sentenceID: sentence.id,
                    url: url,
                    duration: duration,
                    startTime: currentTime,
                    endTime: currentTime + duration
                )

            result.append(segment)

            currentTime += duration
        }

        return result
    }
}
