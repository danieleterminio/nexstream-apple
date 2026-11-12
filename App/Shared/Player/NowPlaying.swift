import Foundation
import UIKit
import MediaPlayer

/// What the system shows about the video outside the app (Control Centre, lock screen, CarPlay "In riproduzione", the
/// Apple TV remote on an iPhone) and what its buttons do. The player in view fills this in.
final class NowPlaying {
    static let shared = NowPlaying()

    struct Handlers {
        var play: () -> Void = {}
        var pause: () -> Void = {}
        var toggle: () -> Void = {}
        /// Next / previous: channel while live, episode on demand. nil = not available.
        var next: (() -> Void)? = nil
        var previous: (() -> Void)? = nil
        /// Jump by seconds, and to a position in seconds (on demand only).
        var skip: ((Double) -> Void)? = nil
        var seek: ((Double) -> Void)? = nil
    }

    private var handlers = Handlers()
    private var info = [String: Any]()
    private var artworkUrl: String? = nil
    private var wired = false

    private init() {}

    private func wire() {
        if wired { return }
        wired = true
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in self?.handlers.play(); return .success }
        c.pauseCommand.addTarget { [weak self] _ in self?.handlers.pause(); return .success }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in self?.handlers.toggle(); return .success }
        c.nextTrackCommand.addTarget { [weak self] _ in
            guard let n = self?.handlers.next else { return .commandFailed }
            n(); return .success
        }
        c.previousTrackCommand.addTarget { [weak self] _ in
            guard let p = self?.handlers.previous else { return .commandFailed }
            p(); return .success
        }
        c.skipForwardCommand.preferredIntervals = [10]
        c.skipBackwardCommand.preferredIntervals = [10]
        c.skipForwardCommand.addTarget { [weak self] e in
            guard let s = self?.handlers.skip else { return .commandFailed }
            s((e as? MPSkipIntervalCommandEvent)?.interval ?? 10); return .success
        }
        c.skipBackwardCommand.addTarget { [weak self] e in
            guard let s = self?.handlers.skip else { return .commandFailed }
            s(-((e as? MPSkipIntervalCommandEvent)?.interval ?? 10)); return .success
        }
        c.changePlaybackPositionCommand.addTarget { [weak self] e in
            guard let s = self?.handlers.seek, let ev = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            s(ev.positionTime); return .success
        }
    }

    /// Describes what is playing. `live` hides the position bar and shows the live badge.
    func set(title: String, subtitle: String?, artwork: String?, live: Bool, handlers h: Handlers) {
        wire()
        handlers = h
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.isEnabled = true
        c.pauseCommand.isEnabled = true
        c.togglePlayPauseCommand.isEnabled = true
        c.nextTrackCommand.isEnabled = h.next != nil
        c.previousTrackCommand.isEnabled = h.previous != nil
        c.skipForwardCommand.isEnabled = h.skip != nil
        c.skipBackwardCommand.isEnabled = h.skip != nil
        c.changePlaybackPositionCommand.isEnabled = h.seek != nil
        var i = [String: Any]()
        i[MPMediaItemPropertyTitle] = title
        if let s = subtitle { i[MPMediaItemPropertyArtist] = s }
        i[MPNowPlayingInfoPropertyIsLiveStream] = live
        i[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.video.rawValue
        i[MPNowPlayingInfoPropertyPlaybackRate] = 1.0
        if let art = info[MPMediaItemPropertyArtwork], artworkUrl == artwork { i[MPMediaItemPropertyArtwork] = art }
        info = i
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        if artworkUrl != artwork || info[MPMediaItemPropertyArtwork] == nil {
            artworkUrl = artwork
            guard let u = artwork else { return }
            Task { @MainActor in
                guard let img = await ImageLoader.shared.load(u, maxPixel: 800), self.artworkUrl == u else { return }
                self.info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
                MPNowPlayingInfoCenter.default().nowPlayingInfo = self.info
            }
        }
    }

    /// Position, length and speed: call when one of them jumps (play, pause, seek), the system counts on by itself.
    func progress(positionMs: Millis, durationMs: Millis, playing: Bool, rate: Float = 1) {
        if info.isEmpty { return }
        if durationMs > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = Double(durationMs) / 1000
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = Double(positionMs) / 1000
        }
        info[MPNowPlayingInfoPropertyPlaybackRate] = playing ? Double(rate) : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    func clear() {
        handlers = Handlers()
        info = [:]
        artworkUrl = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        if wired {
            let c = MPRemoteCommandCenter.shared()
            for cmd in [c.nextTrackCommand, c.previousTrackCommand, c.skipForwardCommand, c.skipBackwardCommand, c.changePlaybackPositionCommand] { cmd.isEnabled = false }
        }
    }
}
