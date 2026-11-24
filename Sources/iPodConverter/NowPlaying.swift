#if os(macOS)
import AppKit
import MediaPlayer

/// «Исполняется» в macOS: что играет (название, артист, обложка, позиция) и системные команды —
/// клавиши ⏮ ⏯ ⏭, «Пункт управления», наушники и системные панели управления воспроизведением.
@MainActor
enum NowPlaying {
    private static var commandsInstalled = false
    /// Обложка, для которой уже собран MPMediaItemArtwork (чтобы не пересоздавать каждый раз).
    private static var artworkImage: NSImage?
    private static var artwork: MPMediaItemArtwork?

    static func installCommands(_ c: PlayerController) {
        guard !commandsInstalled else { return }
        commandsInstalled = true
        let rc = MPRemoteCommandCenter.shared()
        rc.playCommand.addTarget { _ in
            MainActor.assumeIsolated { if !c.isPlaying { c.togglePlay() } }
            return .success
        }
        rc.pauseCommand.addTarget { _ in
            MainActor.assumeIsolated { if c.isPlaying { c.togglePlay() } }
            return .success
        }
        rc.togglePlayPauseCommand.addTarget { _ in
            MainActor.assumeIsolated { c.togglePlay() }
            return .success
        }
        rc.nextTrackCommand.addTarget { _ in
            MainActor.assumeIsolated { c.next() }
            return .success
        }
        rc.previousTrackCommand.addTarget { _ in
            MainActor.assumeIsolated { c.previous() }
            return .success
        }
        rc.changePlaybackPositionCommand.addTarget { event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            MainActor.assumeIsolated { c.seek(to: e.positionTime) }
            return .success
        }
    }

    /// Обновить карточку «Исполняется» (вызывается при смене трека, паузе, перемотке).
    static func update(_ c: PlayerController) {
        installCommands(c)
        let center = MPNowPlayingInfoCenter.default()
        guard let e = c.current else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        // Подзаголовок у трека — «Артист · Оригинал»; системе отдаём только артиста.
        let artist = e.subtitle.components(separatedBy: " · ").first ?? e.subtitle
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: e.title,
            MPMediaItemPropertyArtist: artist,
            MPMediaItemPropertyMediaType: NSNumber(value: (e.isVideo ? MPMediaType.anyVideo : MPMediaType.music).rawValue),
            MPNowPlayingInfoPropertyElapsedPlaybackTime: c.currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: c.isPlaying ? 1.0 : 0.0,
        ]
        if c.duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = c.duration }
        if let img = c.artwork {
            if img !== artworkImage {
                artworkImage = img
                artwork = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
            }
            info[MPMediaItemPropertyArtwork] = artwork
        }
        center.nowPlayingInfo = info
        center.playbackState = c.isPlaying ? .playing : .paused
        let rc = MPRemoteCommandCenter.shared()
        rc.nextTrackCommand.isEnabled = c.hasNext
        rc.previousTrackCommand.isEnabled = true
    }
}
#endif
