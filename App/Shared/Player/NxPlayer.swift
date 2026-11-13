import SwiftUI
import UIKit
import AVFoundation
import AVKit
#if os(tvOS)
import TVVLCKit
#else
import MobileVLCKit
#endif

enum PlayerState: Equatable { case idle, opening, buffering, playing, paused, ended, error }
enum PlayerEngine: Equatable { case system, vlc }

struct PlayerTrack: Identifiable, Hashable { let id: Int32; let name: String }

/// The view the video is drawn on: the system player's layer and VLC's surface, one shown at a time.
final class PlayerSurfaceView: UIView {
    final class LayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
    let systemView = LayerView()
    let vlcView = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isUserInteractionEnabled = false
        systemView.backgroundColor = .black
        vlcView.backgroundColor = .black
        vlcView.isHidden = true
        addSubview(systemView)
        addSubview(vlcView)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        systemView.frame = bounds
        vlcView.frame = bounds
    }
    func show(_ e: PlayerEngine) {
        systemView.isHidden = e != .system
        vlcView.isHidden = e != .vlc
    }
}

/// The video player. It uses the system player whenever it can, because that is what the rest of the system knows:
/// Control Centre and lock screen, AirPlay, picture in picture, CarPlay. Live channels reach it through `LiveProxy`.
/// What the system player cannot decode (MPEG-2 channels, MKV files, odd sources) goes to VLC by itself, and the
/// choice is remembered for that channel.
final class NxPlayer: NSObject, ObservableObject, VLCMediaPlayerDelegate {
    @Published private(set) var state: PlayerState = .idle
    @Published private(set) var positionMs: Millis = 0
    @Published private(set) var durationMs: Millis = 0
    @Published private(set) var engine: PlayerEngine = .system
    @Published private(set) var pipActive = false
    @Published private(set) var pipPossible = false
    /// The video is on an AirPlay screen.
    @Published private(set) var external = false
    /// Why the last stream failed, in words for the viewer (HTTP status, network, decoder), when it is known.
    @Published private(set) var failureReason: String? = nil
    /// Bumped when the audio / subtitle tracks of the stream become known.
    @Published private(set) var tracksVersion = 0
    /// Zoom to fill the screen (crops the sides on a phone) instead of showing the whole picture.
    @Published var fill = false { didSet { surface.systemView.playerLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect } }

    /// Called (on the main thread) when the stream ends or fails.
    var onEnded: (() -> Void)?
    var onError: (() -> Void)?
    /// Picture in picture asks for the player screen back.
    var onRestoreUI: (() -> Void)?

    let surface = PlayerSurfaceView()

    private let av = AVPlayer()
    private var vlcPlayer: VLCMediaPlayer? = nil
    private var proxy: LiveProxy? = nil
    private var loaded = false
    private var gen = 0
    private var wantedRate: Float = 1
    private var userPaused = false
    private var everPlayed = false
    private var request: Request? = nil
    private var itemObs = [NSKeyValueObservation]()
    private var playerObs = [NSKeyValueObservation]()
    private var noteObs = [NSObjectProtocol]()
    private var timeObs: Any? = nil
    private var audioGroup: AVMediaSelectionGroup? = nil
    private var subGroup: AVMediaSelectionGroup? = nil
    private var subOptions = [AVMediaSelectionOption]()
    private var savedVideoTrack: Int32? = nil
    private var playingSince: Date? = nil
    /// Live: new pictures are counted here, so a frozen picture can be told from a stream that plays.
    private var videoOutput: AVPlayerItemVideoOutput? = nil
    private var frameCount = 0
    private static let stopQueue = DispatchQueue(label: "nx.player.stop")
    #if os(iOS)
    private var pip: AVPictureInPictureController? = nil
    private var pipObs: NSKeyValueObservation? = nil
    #endif

    private struct Request {
        var url: String
        var headers: [String: String]
        var startMs: Millis
        var live: Bool
        var key: String?
        var file: URL?
    }

    override init() {
        super.init()
        surface.systemView.playerLayer.player = av
        surface.systemView.playerLayer.videoGravity = .resizeAspect
        av.allowsExternalPlayback = true
        av.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        playerObs.append(av.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in DispatchQueue.main.async { self?.systemStatusChanged() } })
        playerObs.append(av.observe(\.isExternalPlaybackActive, options: [.new]) { [weak self] p, _ in DispatchQueue.main.async { self?.external = p.isExternalPlaybackActive } })
        timeObs = av.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 2), queue: .main) { [weak self] t in self?.systemTime(t) }
        let nc = NotificationCenter.default
        noteObs.append(nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in self?.background() })
        noteObs.append(nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in self?.foreground() })
        #if os(iOS)
        if AVPictureInPictureController.isPictureInPictureSupported() {
            let p = AVPictureInPictureController(playerLayer: surface.systemView.playerLayer)
            p?.delegate = self
            p?.canStartPictureInPictureAutomaticallyFromInline = true
            pip = p
            pipObs = p?.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] c, _ in DispatchQueue.main.async { self?.pipPossible = c.isPictureInPicturePossible } }
        }
        #endif
    }

    deinit {
        if let t = timeObs { av.removeTimeObserver(t) }
        noteObs.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: remembered engine choice

    private static let vlcKey = "nx.vlcOnly"
    /// Channels the system player could not decode, with the day it happened (tried again after a week).
    private static var vlcOnly: [String: Double] = (UserDefaults.standard.dictionary(forKey: vlcKey) as? [String: Double]) ?? [:]
    private static func needsVlc(_ key: String?) -> Bool {
        guard let k = key, let at = vlcOnly[k] else { return false }
        return Date().timeIntervalSince1970 - at < 7 * 86_400
    }
    private static func markVlc(_ key: String?) {
        guard let k = key else { return }
        vlcOnly[k] = Date().timeIntervalSince1970
        if vlcOnly.count > 600 { vlcOnly = vlcOnly.filter { Date().timeIntervalSince1970 - $0.value < 7 * 86_400 } }
        UserDefaults.standard.set(vlcOnly, forKey: vlcKey)
    }
    /// "Player compatibile" in the settings: always VLC.
    static var forceVlc: Bool {
        get { UserDefaults.standard.bool(forKey: "nx.forceVlc") }
        set { UserDefaults.standard.set(newValue, forKey: "nx.forceVlc") }
    }

    // MARK: loading

    /// Opens a stream and plays. `live`: a channel of the line (MPEG-TS). `key` names the stream so that the engine
    /// that works for it is remembered.
    func load(url: String, headers: [String: String] = [:], startMs: Millis = 0, live: Bool, key: String? = nil) {
        reset()
        let req = Request(url: url, headers: headers, startMs: startMs, live: live, key: key, file: nil)
        request = req
        loaded = true
        positionMs = startMs; durationMs = 0
        state = .opening
        UIApplication.shared.isIdleTimerDisabled = true
        guard let u = NxPlayer.url(url) else { fail(); return }
        let ext = u.pathExtension.lowercased()
        let vlcFormat = !live && ["mkv", "avi", "flv", "wmv", "webm", "ts", "mpg", "mpeg", "rmvb", "ogv"].contains(ext)
        if NxPlayer.forceVlc || vlcFormat || NxPlayer.needsVlc(key) { startVlc(req) }
        else if live { startProxy(req, u) }
        else { startSystem(u, headers: req.headers, startMs: startMs, live: false) }
    }

    /// Plays a file saved on the device.
    func loadFile(_ file: URL, startMs: Millis = 0) {
        reset()
        let req = Request(url: file.absoluteString, headers: [:], startMs: startMs, live: false, key: nil, file: file)
        request = req
        loaded = true
        positionMs = startMs; durationMs = 0
        state = .opening
        UIApplication.shared.isIdleTimerDisabled = true
        let ext = file.pathExtension.lowercased()
        if NxPlayer.forceVlc || !["mp4", "m4v", "mov"].contains(ext) { startVlc(req) }
        else { startSystem(file, headers: [:], startMs: startMs, live: false) }
    }

    private static func url(_ s: String) -> URL? {
        URL(string: s) ?? URL(string: s.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? "")
    }

    private func reset() {
        gen += 1
        userPaused = false
        everPlayed = false
        playingSince = nil
        savedVideoTrack = nil
        failureReason = nil
        videoOutput = nil
        frameCount = 0
        stopEngines()
    }

    private func stopEngines() {
        itemObs = []
        audioGroup = nil; subGroup = nil; subOptions = []
        av.pause()
        av.replaceCurrentItem(with: nil)
        proxy?.stop(); proxy = nil
        if let v = vlcPlayer {
            v.delegate = nil
            vlcPlayer = nil
            NxPlayer.stopQueue.async { v.stop() }
        }
    }

    private func fail() {
        NxLog.w("NxPlayer", "\(engine == .vlc ? "VLC" : "system player") gave up on \(request?.url.prefix(90) ?? "-")")
        state = .error
        onError?()
    }

    // MARK: system player

    private func startProxy(_ req: Request, _ u: URL) {
        let g = gen
        engine = .system
        surface.show(.system)
        let p = LiveProxy()
        proxy = p
        p.onReady = { [weak self] local in
            guard let self = self, self.gen == g else { return }
            self.startSystem(local, headers: [:], startMs: 0, live: true)
        }
        p.onUnsupported = { [weak self] what in
            guard let self = self, self.gen == g else { return }
            NxLog.i("NxPlayer", "system player cannot decode \(what): VLC")
            self.fallbackToVlc(remember: true)
        }
        p.onEnded = { [weak self, weak p] early in
            guard let self = self, self.gen == g else { return }
            if early { self.failureReason = NxPlayer.describe(proxyFailure: p?.failure); self.fail(); return }
            // the line closed the stream: the playlist is now closed too, so what is buffered plays out and the
            // system player reports the end by itself; the caller then connects again
        }
        p.start(url: u, headers: req.headers)
    }

    private func startSystem(_ u: URL, headers: [String: String], startMs: Millis, live: Bool) {
        NxLog.i("NxPlayer", "system player: \(u.absoluteString.prefix(90)) headers \(headers.keys.sorted())")
        engine = .system
        surface.show(.system)
        var opts = [String: Any]()
        if !headers.isEmpty { opts["AVURLAssetHTTPHeaderFieldsKey"] = headers }
        let asset = AVURLAsset(url: u, options: opts)
        let item = AVPlayerItem(asset: asset)
        if live {
            item.preferredForwardBufferDuration = 6
            let o = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
            item.add(o)
            videoOutput = o
        }
        let g = gen
        itemObs = [
            item.observe(\.status, options: [.new]) { [weak self] it, _ in DispatchQueue.main.async { self?.itemStatus(it, g) } },
        ]
        let nc = NotificationCenter.default
        noteObs.append(nc.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            guard let self = self, self.gen == g, self.loaded else { return }
            self.state = .ended
            self.onEnded?()
        })
        noteObs.append(nc.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] n in
            guard let self = self, self.gen == g, self.loaded else { return }
            self.failureReason = NxPlayer.describe(n.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error, item)
            self.systemFailed()
        })
        av.replaceCurrentItem(with: item)
        av.defaultRate = wantedRate
        if startMs > 1000 { av.seek(to: CMTime(value: CMTimeValue(startMs), timescale: 1000), toleranceBefore: .zero, toleranceAfter: CMTime(value: 2, timescale: 1)) }
        av.play()
    }

    private func itemStatus(_ item: AVPlayerItem, _ g: Int) {
        guard gen == g, loaded else { return }
        switch item.status {
        case .failed:
            NxLog.w("NxPlayer", "system player: \(item.error?.localizedDescription ?? "failed")")
            failureReason = NxPlayer.describe(item.error, item)
            systemFailed()
        case .readyToPlay:
            let d = item.duration
            if d.isNumeric && d.seconds > 0 { durationMs = Millis(d.seconds * 1000) }
            loadTracks(item, g)
        default: break
        }
    }

    /// The system player gave up. If it never showed a picture the stream is probably one it cannot decode: VLC takes
    /// over without the viewer seeing an error. If it had been playing, it is the network: the caller decides.
    private func systemFailed() {
        if !everPlayed && request?.file == nil { fallbackToVlc(remember: request?.live == true) }
        else { fail() }
    }

    private func fallbackToVlc(remember: Bool) {
        guard let req = request, loaded else { return }
        if remember { NxPlayer.markVlc(req.key) }
        let g = gen
        itemObs = []
        av.pause()
        av.replaceCurrentItem(with: nil)
        proxy?.stop(); proxy = nil
        state = .opening
        // the line allows one connection: the proxy's download must be closed before VLC opens its own
        DispatchQueue.main.asyncAfter(deadline: .now() + (req.live ? 0.45 : 0.05)) { [weak self] in
            guard let self = self, self.gen == g, self.loaded else { return }
            var r = req
            if !r.live && self.positionMs > r.startMs { r.startMs = self.positionMs }
            self.startVlc(r)
        }
    }

    private func loadTracks(_ item: AVPlayerItem, _ g: Int) {
        let asset = item.asset
        Task { @MainActor [weak self] in
            let a = try? await asset.loadMediaSelectionGroup(for: .audible)
            let s = try? await asset.loadMediaSelectionGroup(for: .legible)
            guard let self = self, self.gen == g else { return }
            self.audioGroup = a
            self.subGroup = s
            self.subOptions = s.map { AVMediaSelectionGroup.mediaSelectionOptions(from: $0.options, withoutMediaCharacteristics: [.containsOnlyForcedSubtitles]) } ?? []
            self.tracksVersion += 1
        }
    }

    private func systemStatusChanged() {
        guard loaded, engine == .system, av.currentItem != nil else { return }
        switch av.timeControlStatus {
        case .playing:
            everPlayed = true
            if playingSince == nil { playingSince = Date() }
            state = .playing
        case .paused:
            if userPaused { state = .paused }
        case .waitingToPlayAtSpecifiedRate:
            state = everPlayed ? .buffering : .opening
        @unknown default: break
        }
    }

    private func systemTime(_ t: CMTime) {
        guard loaded, engine == .system, let item = av.currentItem else { return }
        if t.isNumeric {
            let ms = Millis(t.seconds * 1000)
            if ms > 0 { positionMs = ms }
        }
        let d = item.duration
        if d.isNumeric && d.seconds > 0 { durationMs = Millis(d.seconds * 1000) }
        // sound but no picture after a few seconds on a channel that has video: the system player cannot draw it
        if request?.live == true, let since = playingSince, Date().timeIntervalSince(since) > 6, !external,
           (proxy?.info?.video ?? 0) != 0, item.presentationSize == .zero {
            NxLog.i("NxPlayer", "no picture from the system player: VLC")
            playingSince = nil
            fallbackToVlc(remember: true)
        }
    }

    // MARK: what went wrong

    /// The LiveProxy's reason ("http:403", "network") in words.
    static func describe(proxyFailure f: String?) -> String? {
        guard let f = f else { return nil }
        if f == "network" { return "Nessuna connessione al server del canale. Controlla la rete e la VPN." }
        if f.hasPrefix("http:"), let code = Int(f.dropFirst(5)) { return describe(http: code) }
        return nil
    }
    static func describe(http code: Int) -> String {
        switch code {
        case 403: return "Il server rifiuta la connessione (HTTP 403). Di solito succede quando la linea è già in uso su un altro dispositivo."
        case 404: return "Questo canale non è disponibile al momento sulla linea (HTTP 404)."
        default: return "Il server del canale non risponde (HTTP \(code))."
        }
    }
    /// An error of the system player in words: the HTTP status in the item's error log, the network, the decoder.
    static func describe(_ error: Error?, _ item: AVPlayerItem?) -> String? {
        if let code = item?.errorLog()?.events.last?.errorStatusCode, code >= 400 { return describe(http: code) }
        guard let e = error as NSError? else { return nil }
        let inner = e.userInfo[NSUnderlyingErrorKey] as? NSError
        for x in [e, inner].compactMap({ $0 }) where x.domain == NSURLErrorDomain {
            switch x.code {
            case NSURLErrorNotConnectedToInternet, NSURLErrorTimedOut, NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost, NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
                return "Nessuna connessione al server del canale. Controlla la rete e la VPN."
            default: break
            }
        }
        if e.domain == AVFoundationErrorDomain, let c = AVError.Code(rawValue: e.code) {
            switch c {
            case .decoderNotFound, .decodeFailed, .decoderTemporarilyUnavailable, .fileFormatNotRecognized, .failedToParse:
                return "Questo dispositivo non riesce a decodificare il flusso del canale."
            default: break
            }
        }
        return nil
    }

    /// Pictures shown so far on a live channel (system player; nil when unknown or the stream has no video). The live
    /// watchdog uses it to notice a picture that froze while the sound goes on.
    func framesShown() -> Int? {
        guard loaded, engine == .system, let out = videoOutput, (proxy?.info?.video ?? 1) != 0 else { return nil }
        let t = out.itemTime(forHostTime: CACurrentMediaTime())
        if out.hasNewPixelBuffer(forItemTime: t) {
            _ = out.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil)
            frameCount += 1
        }
        return frameCount
    }

    // MARK: VLC

    private func startVlc(_ req: Request) {
        NxLog.i("NxPlayer", "VLC: \(req.url.prefix(90))")
        engine = .vlc
        surface.show(.vlc)
        let v = VLCMediaPlayer()
        v.delegate = self
        v.drawable = surface.vlcView
        vlcPlayer = v
        let media: VLCMedia
        if let f = req.file { media = VLCMedia(url: f) }
        else {
            guard let u = NxPlayer.url(req.url) else { fail(); return }
            media = VLCMedia(url: u)
            media.addOption(":network-caching=\(req.live ? 1500 : 3000)")
            media.addOption(":http-reconnect")
            var ua = Http.userAgent
            var hasUa = false
            for (k, val) in req.headers {
                switch k.lowercased() {
                case "user-agent": ua = val; hasUa = true
                case "referer": media.addOption(":http-referrer=\(val)")
                default: break
                }
            }
            if !req.live && !hasUa { ua = "Mozilla/5.0 (Linux; Android 11; SHIELD Android TV) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36" }
            media.addOption(":http-user-agent=\(ua)")
        }
        if req.startMs > 1000 { media.addOption(":start-time=\(req.startMs / 1000)") }
        v.media = media
        v.play()
        if wantedRate != 1 { v.rate = wantedRate }
    }

    func mediaPlayerStateChanged(_ aNotification: Notification) {
        guard loaded, engine == .vlc, let v = vlcPlayer else { return }
        switch v.state {
        case .opening: state = .opening
        case .buffering: if !v.isPlaying { state = .buffering }
        case .playing: state = .playing; everPlayed = true
        case .paused: state = .paused
        case .ended: state = .ended; onEnded?()
        case .error: fail()
        case .stopped: if state == .playing || state == .buffering || state == .opening { state = .ended; onEnded?() }
        default: break
        }
    }

    func mediaPlayerTimeChanged(_ aNotification: Notification) {
        guard loaded, engine == .vlc, let v = vlcPlayer else { return }
        let t = Millis(v.time.intValue)
        if t > 0 { positionMs = t }
        if let len = v.media?.length.intValue, len > 0 { durationMs = Millis(len) }
        if state != .playing && v.isPlaying { state = .playing; everPlayed = true; tracksVersion += 1 }
    }

    /// VLC loses its picture when the app leaves the screen: the video track is switched off while in the background
    /// (the sound goes on) and back on at the return, which also redraws the surface.
    private func background() {
        guard loaded, engine == .vlc, let v = vlcPlayer else { return }
        savedVideoTrack = v.currentVideoTrackIndex
        v.currentVideoTrackIndex = -1
    }
    private func foreground() {
        guard loaded, engine == .vlc, let v = vlcPlayer else { return }
        v.drawable = surface.vlcView
        if let t = savedVideoTrack { v.currentVideoTrackIndex = t; savedVideoTrack = nil }
    }

    // MARK: transport

    var hasMedia: Bool { loaded }
    /// True while the player means to play (also while it buffers).
    var isPlaying: Bool {
        guard loaded else { return false }
        if engine == .vlc { return vlcPlayer?.isPlaying ?? false }
        return av.timeControlStatus != .paused
    }

    func play() {
        guard loaded else { return }
        userPaused = false
        if engine == .vlc { vlcPlayer?.play() } else { av.play() }
    }

    func pause() {
        guard loaded else { return }
        userPaused = true
        if engine == .vlc { if vlcPlayer?.canPause == true { vlcPlayer?.pause() } }
        else { av.pause(); state = .paused }
    }

    func toggle() { if isPlaying { pause() } else { play() } }

    /// Stops and frees the connection (the line allows one at a time: this must happen before the next channel opens).
    func stop() {
        loaded = false
        request = nil
        reset()
        state = .idle
    }

    func shutdown() {
        stop()
        #if os(iOS)
        if pip?.isPictureInPictureActive == true { pip?.stopPictureInPicture() }
        #endif
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func seek(to ms: Millis) {
        guard loaded else { return }
        let target = max(0, durationMs > 0 ? min(ms, durationMs - 2000) : ms)
        if engine == .vlc { vlcPlayer?.time = VLCTime(int: Int32(truncatingIfNeeded: target)) }
        else { av.seek(to: CMTime(value: CMTimeValue(target), timescale: 1000), toleranceBefore: CMTime(value: 1, timescale: 2), toleranceAfter: CMTime(value: 1, timescale: 2)) }
        positionMs = target
    }

    var rate: Float {
        get { wantedRate }
        set {
            wantedRate = newValue
            if engine == .vlc { vlcPlayer?.rate = newValue }
            else {
                av.defaultRate = newValue
                if av.timeControlStatus != .paused { av.rate = newValue }
            }
        }
    }

    /// Milliseconds played so far, straight from the engine (the watchdogs read this).
    var engineTimeMs: Millis {
        if engine == .vlc { return Millis(vlcPlayer?.time.intValue ?? 0) }
        let t = av.currentTime()
        return t.isNumeric ? Millis(t.seconds * 1000) : 0
    }

    // MARK: tracks

    private func vlcTracks(_ ids: [Any]?, _ names: [Any]?) -> [PlayerTrack] {
        let i = (ids ?? []).compactMap { ($0 as? NSNumber)?.int32Value }
        let n = (names ?? []).map { ($0 as? String) ?? "" }
        var out = [PlayerTrack]()
        for (k, id) in i.enumerated() { out.append(PlayerTrack(id: id, name: k < n.count ? n[k] : "Traccia \(k + 1)")) }
        return out
    }

    var audioTracks: [PlayerTrack] {
        if engine == .vlc { return vlcTracks(vlcPlayer?.audioTrackIndexes, vlcPlayer?.audioTrackNames).filter { $0.id >= 0 } }
        guard let g = audioGroup else { return [] }
        var out = [PlayerTrack]()
        for (i, o) in g.options.enumerated() { out.append(PlayerTrack(id: Int32(i), name: o.displayName)) }
        return out
    }
    var currentAudio: Int32 {
        get {
            if engine == .vlc { return vlcPlayer?.currentAudioTrackIndex ?? -1 }
            guard let g = audioGroup, let item = av.currentItem, let sel = item.currentMediaSelection.selectedMediaOption(in: g), let i = g.options.firstIndex(of: sel) else { return 0 }
            return Int32(i)
        }
        set {
            if engine == .vlc { vlcPlayer?.currentAudioTrackIndex = newValue }
            else if let g = audioGroup, let item = av.currentItem, Int(newValue) >= 0, Int(newValue) < g.options.count { item.select(g.options[Int(newValue)], in: g) }
            tracksVersion += 1
        }
    }
    /// Subtitle tracks; id -1 = off.
    var subtitleTracks: [PlayerTrack] {
        if engine == .vlc { return vlcTracks(vlcPlayer?.videoSubTitlesIndexes, vlcPlayer?.videoSubTitlesNames) }
        if subOptions.isEmpty { return [] }
        var out = [PlayerTrack(id: -1, name: "Spenti")]
        for (i, o) in subOptions.enumerated() { out.append(PlayerTrack(id: Int32(i), name: o.displayName)) }
        return out
    }
    var currentSubtitle: Int32 {
        get {
            if engine == .vlc { return vlcPlayer?.currentVideoSubTitleIndex ?? -1 }
            guard let g = subGroup, let item = av.currentItem, let sel = item.currentMediaSelection.selectedMediaOption(in: g), let i = subOptions.firstIndex(of: sel) else { return -1 }
            return Int32(i)
        }
        set {
            if engine == .vlc { vlcPlayer?.currentVideoSubTitleIndex = newValue }
            else if let g = subGroup, let item = av.currentItem {
                let i = Int(newValue)
                item.select(i >= 0 && i < subOptions.count ? subOptions[i] : nil, in: g)
            }
            tracksVersion += 1
        }
    }

    /// Picks the audio track in the preferred language, when the stream names one.
    func preferAudio(_ lang: String) {
        let wanted: [String]
        switch lang {
        case "it": wanted = ["ita", "ital", "[it]", "it "]
        case "en": wanted = ["eng", "engl", "[en]", "en ", "ingl"]
        default: return
        }
        if let t = audioTracks.first(where: { t in let n = t.name.lowercased() + " "; return wanted.contains { n.contains($0) } }), t.id != currentAudio { currentAudio = t.id }
    }
    func preferSubtitle(_ lang: String) {
        if lang.isEmpty { if currentSubtitle != -1 { currentSubtitle = -1 }; return }
        let wanted = lang == "it" ? ["ita", "ital"] : [lang]
        if let t = subtitleTracks.first(where: { t in let n = t.name.lowercased(); return t.id >= 0 && wanted.contains { n.contains($0) } }) { currentSubtitle = t.id }
    }

    // MARK: picture in picture

    func togglePip() {
        #if os(iOS)
        guard let p = pip else { return }
        if p.isPictureInPictureActive { p.stopPictureInPicture() } else if p.isPictureInPicturePossible { p.startPictureInPicture() }
        #endif
    }
}

#if os(iOS)
extension NxPlayer: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerDidStartPictureInPicture(_ c: AVPictureInPictureController) { pipActive = true }
    func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) { pipActive = false }
    func pictureInPictureController(_ c: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        onRestoreUI?()
        completionHandler(true)
    }
}
#endif

/// The surface of a player inside SwiftUI.
struct PlayerSurface: UIViewRepresentable {
    let player: NxPlayer
    func makeUIView(context: Context) -> UIView {
        let host = UIView()
        host.backgroundColor = .black
        host.isUserInteractionEnabled = false
        attach(host)
        return host
    }
    func updateUIView(_ uiView: UIView, context: Context) { if player.surface.superview !== uiView { attach(uiView) } }
    private func attach(_ host: UIView) {
        let s = player.surface
        s.removeFromSuperview()
        s.frame = host.bounds
        s.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.addSubview(s)
    }
}

#if os(iOS)
/// The system's AirPlay button, tinted like our own controls.
struct AirPlayButton: UIViewRepresentable {
    var size: CGFloat = 44
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = .white
        v.activeTintColor = UIColor(red: 0.90, green: 0.09, blue: 0.25, alpha: 1)
        v.prioritizesVideoDevices = true
        v.backgroundColor = .clear
        return v
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
#endif

func playerClock(_ ms: Millis) -> String {
    let s = max(0, ms / 1000)
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}
