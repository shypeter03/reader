//
//  AIError.swift
//  Reader
//
//  Created by 粟海洋 on 2026/8/27.
//

import Foundation

enum AIError: LocalizedError {

    case modelNotLoaded
    case invalidResponse
    case invalidJSON

    var errorDescription: String? {

        switch self {

        case .modelNotLoaded:
            return "AI 模型尚未加载"

        case .invalidResponse:
            return "AI 返回内容无效"

        case .invalidJSON:
            return "AI 返回的 JSON 无法解析"
        }
    }
}
