//
//  ReaderApp.swift
//  Reader
//
//  Created by 粟海洋 on 2026/8/26.
//

import SwiftUI

@main
struct ReaderApp: App {
    @StateObject
        private var player =
            PlayerManager.shared

        var body: some Scene {

            WindowGroup {

                TabView {

                    LibraryView()
                        .tabItem {
                            Label(
                                "书库",
                                systemImage:
                                    "books.vertical"
                            )
                        }

                    NavigationStack {

                        PlayerView(
                            player: player
                        )
                    }
                    .tabItem {
                        Label(
                            "播放",
                            systemImage:
                                "play.circle"
                        )
                    }

                    SettingsView()
                        .tabItem {
                            Label(
                                "设置",
                                systemImage:
                                    "gearshape"
                        )
                    }
                }
            }
        }
}

