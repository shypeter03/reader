//
//  NowPlayingController.swift
//  Reader
//
//  锁屏 / 控制中心 / 耳机上那张「正在播放」卡片：`MPNowPlayingInfoCenter` 写内容，
//  `MPRemoteCommandCenter` 接按钮。播放本身还是 ``PlayerManager`` 的事，这里只做翻译——
//  卡片上按一下就等于在阅读页按了一下，不能自己另起一套播放状态机。
//
//  **一章当一首曲目**，不当一句：一首歌就是一个 track，而这里一句一段音频、一章几百句。
//  拿句子当曲目，锁屏那条进度就只有几秒钟长、每跳一句重置一次，拖拽也没意义；
//  按章当曲目才对得上「听到第几章」这个心智，章节名也正好是卡片上要写的那一行。
//  于是卡片上：粗体那行 = 书名，灰那行 = 章节名，第三行 = 作者，进度条 = 本章。
//
//  为什么进度要自己算：AVPlayer 手上永远只有**当前这一句**的音频，它压根不知道一章多长。
//  本章总时长由 ``PlayerManager`` 按句累加（还没合成出来的句子按字数外推），
//  位置 = 前面那些句子的长度之和 + 这一句已经放的秒数。
//

import Foundation
import MediaPlayer
import UIKit

/// 卡片上那一屏内容：换章才变的东西。
struct NowPlayingTrack {

    let bookTitle: String

    let author: String?

    let chapterTitle: String

    /// 封面文件的绝对路径。读不到就不画封面（书库里那本的路径可能已经随部署没了）。
    let coverURL: URL?

    /// 本章总时长（秒），由句长累加/外推而来。
    let duration: Double
}

/// 锁屏控制的落点。谁按了哪一颗，PlayerManager 决定怎么改播放。
///
/// 闭包全部标 `@MainActor`：系统的命令回调不保证跑在主队列，而播放状态全在主线程上，
/// 这一层唯一的动作就是把它挪回主线程再交给播放器。
struct NowPlayingCommands {

    let play: @MainActor () -> Void

    let pause: @MainActor () -> Void

    let toggle: @MainActor () -> Void

    /// ±1：跳到相邻一章。书到头就什么都不做（卡片会停在最后一章）。
    let jumpChapter: @MainActor (_ delta: Int) -> Void

    /// 相对挪动（秒）：耳机线控那两颗「+15s / −15s」。
    let skip: @MainActor (_ seconds: TimeInterval) -> Void

    /// 绝对定位（本章内的秒数）：拖动进度条。
    let seek: @MainActor (_ seconds: TimeInterval) -> Void
}

@MainActor
final class NowPlayingController {

    /// 进度条一次挪这么多秒；线控和锁屏上的 ±15 按钮都用它。
    static let skipInterval: TimeInterval = 15

    private var commands: NowPlayingCommands?

    /// 命令只装一次：`MPRemoteCommandCenter` 是进程级的，重复装会把目标闭包叠上去，
    /// 一颗按键放两次逻辑。
    private var installed = false

    /// 当前卡片的内容（不含进度）。只有它变了才整份重推，否则一个 tick 只改两个键。
    private var track: NowPlayingTrack?

    private var artworkCoverURL: URL?

    private var artwork: MPMediaItemArtwork?

    /// 封面在读盘，别为同一个 URL 再开一遍。
    private var loadingArtwork = false

    // MARK: - 安装

    func install(_ commands: NowPlayingCommands) {
        guard !installed else {
            self.commands = commands
            return
        }
        installed = true
        self.commands = commands

        let center = MPRemoteCommandCenter.shared()

        // 命令回调不保证跑在主队列，而播放状态全在 @MainActor 上：闭包只回 `.success`
        // （卡片据此把按钮点亮），真正的动作丢回主线程做。
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.commands?.play() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.commands?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.commands?.toggle() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.commands?.jumpChapter(1) }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.commands?.jumpChapter(-1) }
            return .success
        }

        // 线控双击/三击是「下一曲/上一曲」，不是快进；这里只把 ±15 那两颗接成挪时间，
        // 并把标称间隔写成实际行为，免得卡片画一个 30s 的箭头、按下只挪 15s。
        let interval = NSNumber(value: Self.skipInterval)
        center.skipForwardCommand.preferredIntervals = [interval]
        center.skipBackwardCommand.preferredIntervals = [interval]
        center.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.commands?.skip(Self.skipInterval) }
            return .success
        }
        center.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.commands?.skip(-Self.skipInterval) }
            return .success
        }

        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            // 位置先在当下取出来：event 是外部对象，不该被带进另一个线程。
            let seconds = event.positionTime
            Task { @MainActor in self?.commands?.seek(seconds) }
            return .success
        }

        print("[NowPlaying] 锁屏卡片已接管：曲目=章，进度=本章，跳过=±\(Int(Self.skipInterval))s")
    }

    // MARK: - 卡片内容

    /// 换章 / 起播这类「内容变了」的时机整份重推。
    func show(
        _ track: NowPlayingTrack,
        position: Double,
        rate: Double
    ) {
        self.track = track
        loadArtwork(for: track.coverURL)
        push(position: position, rate: rate, force: true)
    }

    /// 播放中的心跳：只改「到哪儿了」和快慢，别把整份信息重编码一遍。
    func updatePosition(
        _ position: Double,
        rate: Double
    ) {
        push(position: position, rate: rate, force: false)
    }

    /// 暂停 / 中断：把速率写成 0，卡片才会停着走（不改内容）。
    func setRate(_ rate: Double) {
        let center = MPNowPlayingInfoCenter.default()
        var info = center.nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyPlaybackRate] = rate
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position(in: info)
        center.nowPlayingInfo = info
        center.playbackState = rate > 0 ? .playing : .paused
    }

    /// 真的没有在放这本书了（关掉语音播报）：卡片撤掉，别留一张按下去没反应的假卡。
    func clear() {
        track = nil
        artwork = nil
        artworkCoverURL = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    private func position(in info: [String: Any]) -> Double {
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double ?? 0
    }

    private func push(
        position: Double,
        rate: Double,
        force: Bool
    ) {
        guard let track else { return }
        let center = MPNowPlayingInfoCenter.default()

        guard force || center.nowPlayingInfo == nil else {
            var info = center.nowPlayingInfo ?? [:]
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position
            info[MPNowPlayingInfoPropertyPlaybackRate] = rate
            center.nowPlayingInfo = info
            center.playbackState = rate > 0 ? .playing : .paused
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.bookTitle,
            MPMediaItemPropertyArtist: track.chapterTitle,
            MPMediaItemPropertyPlaybackDuration: track.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: rate,
            MPMediaItemPropertyMediaType: MPMediaType.anyAudio.rawValue,
        ]
        if let author = track.author, !author.isEmpty {
            info[MPMediaItemPropertyAlbumTitle] = author
        }
        if let artwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        center.nowPlayingInfo = info
        center.playbackState = rate > 0 ? .playing : .paused
    }

    // MARK: - 封面

    /// 封面读盘 + 解码不放在推送之路上：卡片每句都要更新，而一张几百 KB 的封面
    /// 解码一次就是几十毫秒。只在换书/换章时问一次，缩略图小图，够用。
    private func loadArtwork(for url: URL?) {
        guard url != artworkCoverURL else { return }
        artworkCoverURL = url
        artwork = nil
        guard !loadingArtwork else { return }
        guard let url else {
            // 卡片上有字没图时先看这条：书单里记的封面路径是空的（导入时就没封面）
            print("[NowPlaying] 这本书没有记封面路径，卡片只有文字")
            return
        }

        loadingArtwork = true
        let path = url.path
        Task.detached(priority: .utility) {
            let image = Self.thumbnail(atPath: path)
            if image == nil {
                print("[NowPlaying] 封面解不出图：\(path)")
            }
            await MainActor.run {
                self.loadingArtwork = false
                // 读盘这段时间可能已经换章了：只认现在这一本的封面。
                guard self.artworkCoverURL?.path == path, let image else { return }
                self.artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                self.push(
                    position: self.position(in: MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]),
                    rate: (MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double) ?? 0,
                    force: true
                )
            }
        }
    }

    /// nonisolated：这是要在后台线程跑的那一段（读盘 + 解码），挂到 MainActor 上就等于
    /// 把几十毫秒的解码放回卡片刷新的路上。
    nonisolated private static func thumbnail(atPath path: String) -> UIImage? {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            // 锁屏卡片上的封面最多这么大；整张原图（动辄 1MB+）解出来只是白占内存。
            kCGImageSourceThumbnailMaxPixelSize: 320,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cg)
    }
}
