//
//  SentenceSplitter.swift
//  Reader
//
//  Created by 粟海洋 on 2026/8/26.
//

import Foundation

enum SentenceSplitter {

    static func split(
        _ text: String,
        chapterIndex: Int = 0
    ) -> [Sentence] {

        let separators =
            CharacterSet(
                charactersIn:
                    "。！？!?；;：:\n"
            )

        var result: [Sentence] = []

        var buffer = ""

        // 引号内不切句：跨行对话（“…？\n…！”）保持为一句
        var quoteDepth = 0

        for character in text {

            if character == "“", quoteDepth > 0 {
                // 上一段引号未闭合，就此截断，避免吞掉后续文本
                append(
                    buffer,
                    to: &result,
                    chapterIndex: chapterIndex
                )
                buffer = ""
            }

            buffer.append(character)

            switch character {

            case "“":
                quoteDepth += 1

            case "”":
                quoteDepth = max(0, quoteDepth - 1)
                append(
                    buffer,
                    to: &result,
                    chapterIndex: chapterIndex
                )
                buffer = ""

            case "\"":
                if quoteDepth == 0 {
                    quoteDepth += 1
                } else {
                    quoteDepth = 0
                    append(
                        buffer,
                        to: &result,
                        chapterIndex: chapterIndex
                    )
                    buffer = ""
                }

            default:
                if quoteDepth == 0,
                    String(character)
                    .rangeOfCharacter(
                        from: separators
                    ) != nil {

                    append(
                        buffer,
                        to: &result,
                        chapterIndex: chapterIndex
                    )

                    buffer = ""
                }
            }
        }

        append(
            buffer,
            to: &result,
            chapterIndex: chapterIndex
        )

        // 独立成行的收尾符号（如 ” 』 ））属于上一句，合并回去而不是单独成句
        var merged: [Sentence] = []
        for sentence in result {
            let isPunctuationOnly =
                sentence.text.allSatisfy {
                    !$0.isLetter && !$0.isNumber
                }
            if isPunctuationOnly, var last = merged.popLast() {
                last.text += sentence.text
                merged.append(last)
            } else {
                merged.append(sentence)
            }
        }

        return merged
            .filter {
                !$0.text.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty
            }
            .enumerated()
            .map { index, sentence in
                Sentence(
                    index: index,
                    text: sentence.text,
                    chapterIndex: chapterIndex
                )
            }
    }

    private static func append(
        _ value: String,
        to result: inout [Sentence],
        chapterIndex: Int
    ) {

        let text =
            value.trimmingCharacters(
                in: .whitespacesAndNewlines
            )

        guard !text.isEmpty else {
            return
        }

        result.append(
            Sentence(
                index: result.count,
                text: text
            )
        )
    }
}
