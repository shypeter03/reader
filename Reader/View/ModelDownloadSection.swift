//
//  ModelDownloadSection.swift
//  Reader
//
//  设置页「模型下载」那一节：千问两套权重的下载入口、进度与删除。
//

import SwiftUI

struct ModelDownloadSection: View {

    @ObservedObject
    private var center = ModelDownloadCenter.shared

    /// 装成一套/删掉一套之后重读目录。`ModelStore` 的那些事实不在任何一个 `@Published` 里，
    /// 靠这条通知把它折算成一个整数，body 才会再算一次。
    @State
    private var storeStamp = 0

    /// 等确认的那一套。删错了只能重下 1.6GB，所以问一句。
    @State
    private var deleteTarget: ModelID?

    var body: some View {

        Section {

            ForEach(ModelID.allCases, id: \.self) { id in

                row(id)
            }

            Text(footerText)
                .font(.footnote)
                .foregroundStyle(.secondary)
        } header: {
            Text("模型下载")
        }
        .alert(
            "删除这套权重",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            )
        ) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                if let deleteTarget { center.delete(deleteTarget) }
                deleteTarget = nil
            }
        } message: {
            Text(deleteMessage)
        }
        .onReceive(
            NotificationCenter.default.publisher(for: ModelStore.didChangeNotification)
        ) { _ in
            storeStamp += 1
        }
    }
}

private extension ModelDownloadSection {

    @ViewBuilder
    func row(_ id: ModelID) -> some View {

        let spec = ModelManifest.spec(id)
        let downloading = center.isDownloading(id)
        let ready = ModelStore.isReady(id)

        HStack {

            Label(spec.displayName, systemImage: id == .qwen3TTS ? "waveform" : "text.badge.checkmark")

            Spacer()

            Text(statusText(id, downloading: downloading, ready: ready))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }

        Text(spec.blurb)
            .font(.footnote)
            .foregroundStyle(.secondary)

        if downloading, let progress = center.progress {

            ProgressView(value: progress.modelFraction)

            Text(phaseText(progress))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }

        HStack {

            if !downloading, !ready {
                Button(downloadTitle(id)) {
                    center.start(id)
                }
                .disabled(center.isBusy)
            }

            if downloading {
                Button("取消下载", role: .cancel) {
                    center.cancel()
                }
            }

            if !downloading, ModelStore.allocatedBytes(of: id) > 0 {
                Button("删除", role: .destructive) {
                    deleteTarget = id
                }
            }

            Spacer()
        }

        // 失败原因挂在行上，只说给它自己那一套：两套共用一个 center，
        // 在别的那一行底下报这一行的错会让人以为下载串了。
        if let failure = center.lastFailure, failure.id == id {
            Text(failure.message)
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }

    func statusText(_ id: ModelID, downloading: Bool, ready: Bool) -> String {
        let spec = ModelManifest.spec(id)

        if downloading {
            return "\(Int((center.progress?.modelFraction ?? 0) * 100))%"
        }
        if ready {
            return "已就绪 \(spec.installedBytes.formattedBytes)"
        }
        let installed = ModelStore.installedBytes(of: id)
        return installed > 0
            ? "差 \((spec.installedBytes - installed).formattedBytes)"
            : "未下载 \(spec.installedBytes.formattedBytes)"
    }

    func downloadTitle(_ id: ModelID) -> String {
        ModelStore.installedBytes(of: id) > 0
            ? "继续下载"
            : "下载 \(ModelManifest.spec(id).installedBytes.formattedBytes)"
    }

    /// 确认框那句话。`deleteTarget` 已经清空时给空串——面板正在收，没人看它。
    var deleteMessage: String {
        guard let target = deleteTarget else { return "" }
        let spec = ModelManifest.spec(target)
        return "「\(spec.displayName)」的 \(spec.installedBytes.formattedBytes) 当场放掉，"
            + "要用的话得重新下载一遍。"
    }

    func phaseText(_ progress: ModelDownloadProgress) -> String {

        let done = progress.modelBytesDone.formattedBytes
        let total = progress.modelBytesTotal.formattedBytes
        let phase = progress.phase == .receiving ? "下载" : "校验"

        return "\(phase) \(progress.fileName) \(progress.fileFraction.formattedPercent)"
            + "｜这套 \(done) / \(total)"
    }

    var footerText: String {
        "两套都不打进 App，现下到沙盒里（现在共 \(ModelStore.totalAllocatedBytes().formattedBytes)）。"
            + "下完就能用，不用重启：语音后端当场排进降级链，整书解析当场放开队列。"
            + "删掉的话朗读退回 Edge / Kokoro 那两档，句子标注退回正则那一档。"
    }
}

private extension Int64 {
    var formattedBytes: String { ReaderCache.format(self) }
}

private extension Double {
    var formattedPercent: String { "\(Int(self * 100))%" }
}
