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
    /// 应用在后台：这一步根本没提交推理。MLX 在后台跑 GPU 会抛出 Swift 抓不住的
    /// C++ `std::runtime_error`（进程直接 terminate），所以只能提前拦，见
    /// `AppBackgroundGate`。
    case backgroundHalted

    var errorDescription: String? {

        switch self {

        case .modelNotLoaded:
            return "AI 模型尚未加载"

        case .invalidResponse:
            return "AI 返回内容无效"

        case .invalidJSON:
            return "AI 返回的 JSON 无法解析"

        case .backgroundHalted:
            return "应用在后台，已停止本地模型推理"
        }
    }
}
