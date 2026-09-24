//
//  SettingsView.swift
//  Reader
//
//  Created by 粟海洋 on 2026/8/26.
//

import SwiftUI
import SherpaKokoroKit

struct SettingsView: View {

    @AppStorage(
        "speechRate"
    )
    private var speechRate: Double = 1.0

    @AppStorage(
        "fontSize"
    )
    private var fontSize: Double = 1.0

    @AppStorage(
        "autoNextChapter"
    )
    private var autoNextChapter = true

    @AppStorage(
        "emotionEnhancement"
    )
    private var emotionEnhancement = true

    @AppStorage(
        "autoScroll"
    )
    private var autoScroll = true

    /// 键必须与 `TTSEngineType.storageKey` 一致（@AppStorage 只接受字面量）。
    @AppStorage(
        "ttsEngineType"
    )
    private var ttsEngineRaw: String = TTSEngineType.edge.rawValue

    var body: some View {

        NavigationStack {

            Form {

                speechSection

                readingSection

                dataSection

                aboutSection
            }
            .navigationTitle("设置")
        }
    }
}

private extension SettingsView {

    var speechSection: some View {

        Section("朗读") {

            HStack {

                Label(
                    "朗读速度",
                    systemImage:
                        "speedometer"
                )

                Spacer()

                Text(
                    String(
                        format: "%.1fx",
                        speechRate
                    )
                )
                .foregroundStyle(.secondary)
            }

            Slider(
                value: $speechRate,
                in: 0.5...2.0,
                step: 0.1
            )

            Toggle(
                "自动播放下一章",
                isOn:
                    $autoNextChapter
            )

            Toggle(
                "增强情绪表现",
                isOn:
                    $emotionEnhancement
            )

            Picker(
                "语音合成后端",
                selection: $ttsEngineRaw
            ) {
                ForEach(
                    TTSEngineType.allCases,
                    id: \.rawValue
                ) { engine in
                    Text(
                        engine.displayName
                    )
                    .tag(engine.rawValue)
                }
            }

            Text(
                backendStatusText
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    /// 只在选了 Kokoro 时才提示模型是否就位；默认后端不打扰。
    private var backendStatusText: String {
        guard ttsEngineRaw == TTSEngineType.sherpaKokoro.rawValue else {
            if ttsEngineRaw == TTSEngineType.edge.rawValue {
                return "切换后端需重启 App 生效。Edge TTS 需要联网；连续失败 4 句会自动改用 Kokoro 本地合成。"
            }
            return "切换后端需重启 App 生效。"
        }
        if let dir = SherpaKokoroTTSService.modelDirectoryIfAvailable() {
            return "切换后端需重启 App 生效。已找到 Kokoro 模型：\(dir)"
        }
        return "切换后端需重启 App 生效。未找到 Kokoro 模型：权重应由 folder reference 在 build 时拷进 App，"
            + "或把 \(KokoroModelLocator.preferredDirectoryName) 放到 \(KokoroModelLocator.externalDirectoryNameHint) 后重启。"
    }
}

private extension SettingsView {

    var readingSection: some View {

        Section("阅读") {

            HStack {

                Label(
                    "字体大小",
                    systemImage:
                        "textformat.size"
                )

                Spacer()

                Text(
                    "\(Int(fontSize * 100))%"
                )
                .foregroundStyle(.secondary)
            }

            Slider(
                value: $fontSize,
                in: 0.8...1.5,
                step: 0.05
            )

            Toggle(
                "自动跟随朗读",
                isOn:
                    $autoScroll
            )
        }
    }
}

private extension SettingsView {

    var dataSection: some View {

        Section("数据") {

            HStack {

                Label(
                    "音频缓存",
                    systemImage:
                        "internaldrive"
                )

                Spacer()

                Text("0 MB")
                    .foregroundStyle(
                        .secondary
                    )
            }

            Button(
                role: .destructive
            ) {

                clearCache()

            } label: {

                Label(
                    "清除音频缓存",
                    systemImage:
                        "trash"
                )
            }
        }
    }

    func clearCache() {

        // 后面接 AudioStore
    }
}

private extension SettingsView {

    var aboutSection: some View {

        Section("关于") {

            HStack {

                Text("AI Reader")

                Spacer()

                Text("1.0.0")
                    .foregroundStyle(
                        .secondary
                    )
            }

            HStack {

                Text("AI 朗读引擎")

                Spacer()

                Text("未配置")
                    .foregroundStyle(
                        .secondary
                    )
            }
        }
    }
}
