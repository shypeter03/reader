//
//  AIJSONDecoder.swift
//  Reader
//
//  Created by 粟海洋 on 2026/8/27.
//

import Foundation

enum AIJSONDecoder {

    static func decode(
        _ text: String
    ) throws -> AIAnalysisResult {

        var json = text.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        // 防止模型还是返回 ```json
        if json.hasPrefix("```") {

            json = json
                .replacingOccurrences(
                    of: "```json",
                    with: ""
                )
                .replacingOccurrences(
                    of: "```",
                    with: ""
                )
                .trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
        }

        guard let data =
                json.data(
                    using: .utf8
                )
        else {
            throw AIError.invalidJSON
        }

        do {

            return try JSONDecoder()
                .decode(
                    AIAnalysisResult.self,
                    from: data
                )

        } catch {

            print(
                "AI JSON 解析失败:",
                error
            )

            print(
                "原始内容:",
                json
            )

            throw AIError.invalidJSON
        }
    }
}
