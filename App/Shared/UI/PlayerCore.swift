import SwiftUI
import UIKit
import AVFoundation
#if os(tvOS)
import TVVLCKit
#else
import MobileVLCKit
#endif

enum PlayerState: Equatable { case idle, opening, buffering, playing, paused, ended, error }

struct PlayerTrack: Identifiable, Hashable { let id: Int32; let name: String }

/// The video engine: VLCKit. The line serves live channels as MPEG-TS over plain HTTP, and Stream4Me sources come in every
/// container; VLC plays them all, with hardware decoding. One instance per player screen.
final class NxPlayer: NSObject, ObservableObject, VLCMediaPlayerDelegate {
    private let vlc = VLCMediaPlayer()
    @Published private(set) var state: PlayerState = .idle
    @Published private(set) var positionMs: Millis = 0
    @Published private(set) var durationMs: Millis = 0
    /// Called (on the main thread) when the stream ends or fails.
    var onEnded: (() -> Void)?
    var onError: (() -> Void)?
    private var loaded = false
    private static let stopQueue = DispatchQueue(label: "nx.player.stop")

    override init() {
        super.init()
        vlc.delegate = self
    }

    func attach(_ view: UIView) { vlc.drawable = view }

    /// Opens a stream and plays. `live` trims the buffer for quick zapping; `startMs` resumes a film.
    func load(url: String, headers: [String: String] = [:], startMs: Millis = 0, live: Bool) {
        guard let u = URL(string: url) ?? URL(string: url.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? "") else { state = .error; onError?(); return }
        let media = VLCMedia(url: u)
        media.addOption(":network-caching=\(live ? 1500 : 3000)")
        media.addOption(":http-reconnect")
        var ua = Http.userAgent
        for (k, v) in headers {
            switch k.lowercased() {
            case "user-agent": ua = v
            case "referer": media.addOption(":http-referrer=\(v)")
            default: break
            }
        }
        if !live && headers["User-Agent"] == nil && headers["user-agent"] == nil { ua = "Mozilla/5.0 (Linux; Android 11; SHIELD Android TV) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36" }
        media.addOption(":http-user-agent=\(ua)")
        if startMs > 1000 { media.addOption(":start-time=\(startMs / 1000)") }
        positionMs = startMs; durationMs = 0
        state = .opening
        loaded = true
        vlc.media = media
        vlc.play()
        UIApplication.shared.isIdleTimerDisabled = true
    }

    /// Plays a file saved on the device.
    func loadFile(_ file: URL, startMs: Millis = 0) {
        let media = VLCMedia(url: file)
        if startMs > 1000 { media.addOption(":start-time=\(startMs / 1000)") }
        positionMs = startMs; durationMs = 0; state = .opening; loaded = true
        vlc.media = media
        vlc.play()
        UIApplication.shared.isIdleTimerDisabled = true
    }

    var isPlaying: Bool { vlc.isPlaying }
    var hasMedia: Bool { loaded }
    func play() { if loaded { vlc.play() } }
    func pause() { if vlc.canPause { vlc.pause() } }
    func toggle() { if vlc.isPlaying { pause() } else { play() } }

    /// Stops and frees the connection (the line allows one at a time: this must happen before the next channel opens).
    func stop() {
        loaded = false
        state = .idle
        let p = vlc
        NxPlayer.stopQueue.async { p.stop() }
    }

    func seek(to ms: Millis) {
        guard loaded else { return }
        let target = max(0, durationMs > 0 ? min(ms, durationMs - 2000) : ms)
        vlc.time = VLCTime(int: Int32(truncatingIfNeeded: target))
        positionMs = target
    }

    var rate: Float {
        get { vlc.rate }
        set { vlc.rate = newValue }
    }
    /// Milliseconds played so far, straight from the engine (the watchdog reads this).
    var engineTimeMs: Millis { Millis(vlc.time.intValue) }
    var videoSize: CGSize { vlc.videoSize }

    private func tracks(_ ids: [Any]?, _ names: [Any]?) -> [PlayerTrack] {
        let i = (ids ?? []).compactMap { ($0 as? NSNumber)?.int32Value }
        let n = (names ?? []).map { ($0 as? String) ?? "" }
        var out = [PlayerTrack]()
        for (k, id) in i.enumerated() { out.append(PlayerTrack(id: id, name: k < n.count ? n[k] : "Traccia \(k + 1)")) }
        return out
    }
    var audioTracks: [PlayerTrack] { tracks(vlc.audioTrackIndexes, vlc.audioTrackNames).filter { $0.id >= 0 } }
    var currentAudio: Int32 {
        get { vlc.currentAudioTrackIndex }
        set { vlc.currentAudioTrackIndex = newValue }
    }
    /// Subtitle tracks; id -1 = off.
    var subtitleTracks: [PlayerTrack] { tracks(vlc.videoSubTitlesIndexes, vlc.videoSubTitlesNames) }
    var currentSubtitle: Int32 {
        get { vlc.currentVideoSubTitleIndex }
        set { vlc.currentVideoSubTitleIndex = newValue }
    }
    /// Picks the audio track in the preferred language, when the stream names one.
    func preferAudio(_ lang: String) {
        let wanted: [String]
        switch lang { case "it": wanted = ["ita", "ital", "[it]", "it "]; case "en": wanted = ["eng", "engl", "[en]", "en "]; default: return }
        if let t = audioTracks.first(where: { t in let n = t.name.lowercased(); return wanted.contains { n.contains($0) } }), t.id != currentAudio { currentAudio = t.id }
    }
    func preferSubtitle(_ lang: String) {
        if lang.isEmpty { if currentSubtitle != -1 { currentSubtitle = -1 }; return }
        let wanted = lang == "it" ? ["ita", "ital"] : [lang]
        if let t = subtitleTracks.first(where: { t in let n = t.name.lowercased(); return t.id >= 0 && wanted.contains { n.contains($0) } }) { currentSubtitle = t.id }
    }

    // MARK: VLCMediaPlayerDelegate (called on the main thread)

    func mediaPlayerStateChanged(_ aNotification: Notification) {
        guard loaded else { return }
        switch vlc.state {
        case .opening: state = .opening
        case .buffering: if !vlc.isPlaying { state = .buffering }
        case .playing: state = .playing
        case .paused: state = .paused
        case .ended: state = .ended; onEnded?()
        case .error: state = .error; onError?()
        case .stopped: if state == .playing || state == .buffering || state == .opening { state = .ended; onEnded?() }
        default: break
        }
    }

    func mediaPlayerTimeChanged(_ aNotification: Notification) {
        guard loaded else { return }
        let t = Millis(vlc.time.intValue)
        if t > 0 { positionMs = t }
        if let len = vlc.media?.length.intValue, len > 0 { durationMs = Millis(len) }
        if state != .playing && vlc.isPlaying { state = .playing }
    }

    func shutdown() {
        vlc.delegate = nil
        loaded = false
        let p = vlc
        NxPlayer.stopQueue.async { p.stop() }
        UIApplication.shared.isIdleTimerDisabled = false
    }
}

/// The surface VLC draws on.
struct PlayerSurface: UIViewRepresentable {
    let player: NxPlayer
    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .black
        v.isUserInteractionEnabled = false
        player.attach(v)
        return v
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

/// What the cover shows: the live player or the on-demand one.
struct PlayerHost: View {
    let playing: Playing
    @EnvironmentObject var app: AppModel

    var body: some View {
        Group {
            switch playing {
            case .live(let id, let ids): LivePlayerView(channelId: id, listIds: ids)
            case .vod(let req): VodPlayerView(request: req).id(req.id)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .onAppear { PlatformServices.shared.playerOpened() }
        .onDisappear { PlatformServices.shared.playerClosed() }
        .overlay(alignment: .bottomTrailing) { if let r = app.reminder { ReminderBanner(reminder: r) } }
        .persistentSystemOverlays(.hidden)
    }
}

func playerClock(_ ms: Millis) -> String {
    let s = max(0, ms / 1000)
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}

/// A sheet of choices inside the players (quality, audio, subtitles, speed, episodes).
struct OptionSheet<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List { content() }
                .scrollContentBackground(.hidden)
                .navigationTitle(title)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fine") { dismiss() } } }
                #endif
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(.ultraThinMaterial)
    }
}

/// One line of an option sheet, with a tick on the current choice.
struct OptionRow: View {
    let title: String
    var sub: String? = nil
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(NxFont.bodyStrong).foregroundStyle(NxColor.text)
                    if let s = sub { Text(s).font(NxFont.caption).foregroundStyle(NxColor.textDim) }
                }
                Spacer()
                if selected { Image(systemName: "checkmark").font(.system(size: 15 * Metrics.unit, weight: .bold)).foregroundStyle(NxColor.accent) }
            }
        }
    }
}
