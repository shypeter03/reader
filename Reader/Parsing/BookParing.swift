//
//  BookParing.swift
//  Reader
//
//  Created by 粟海洋 on 2026/8/26.
//

import Foundation

protocol BookParser {

    func parse(
        url: URL
    ) async throws -> Book
}
