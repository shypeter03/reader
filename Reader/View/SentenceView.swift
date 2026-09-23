//
//  SentenceView.swift
//  Reader
//
//  Created by 粟海洋 on 2026/8/26.
//

import SwiftUI

struct SentenceView: View {

    let sentence: Sentence

    let isActive: Bool

    var body: some View {

        Text(sentence.text)
            .font(
                isActive
                ? .title
                : .title3
            )
            .fontWeight(
                isActive
                ? .semibold
                : .regular
            )
            .foregroundStyle(
                isActive
                ? .primary
                : .secondary
            )
            .opacity(
                isActive
                ? 1
                : 0.55
            )
            .scaleEffect(
                isActive
                ? 1.05
                : 1
            )
            .blur(
                radius: isActive
                ? 0
                : 0.4
            )
            .multilineTextAlignment(.center)
            .frame(
                maxWidth: .infinity
            )
            .animation(
                .easeInOut(duration: 0.3),
                value: isActive
            )
    }
}
