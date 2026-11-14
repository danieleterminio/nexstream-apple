#if os(tvOS)
import SwiftUI
import Combine

// The Apple TV live player (docs/tv-experience.md §4), in the same style as the on-demand one: nothing on the picture
// while watching; up / down zap with a small banner, select brings the info bar with its options, left the channel list,
// right the guide of the channel. Every panel is drawn inside the player with its own focus, and BACK always closes just
// the top layer, so it never reaches the system (which would leave the app).

/// The panels of the live player.
enum TvLivePanel: String, Equatable {
    case channels, guide, tracks, info, versions
}

/// What has the remote's focus in the live player.
enum TvLiveFocus: Hashable {
    case surface
    case option(String)
    case error(Int)
}

/// The time, for the corner of the player and its panels.
struct TvClock: View {
    var size: CGFloat = 16
    var body: some View {
        TimelineView(.periodic(from: .now, by: 10)) { _ in
            Text(TimeText.time(Clock.now)).font(NxFont.ui(size, .bold)).foregroundStyle(.white).monospacedDigit()
        }
    }
}

/// A thin programme progress line.
struct TvProgressLine: View {
    let value: Double
    var height: CGFloat = 6
    var track: Color = Color.white.opacity(0.25)
    var fill: Color = NxColor.accent
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule().fill(fill).frame(width: g.size.width * CGFloat(max(0, min(1, value))))
            }
        }
        .frame(height: height)
    }
}

// MARK: - live layer

struct TvLiveLayer: View {
    @ObservedObject var model: LivePlayerModel
    @ObservedObject var player: NxPlayer
    @ObservedObject var chrome: ChromeState
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var store: LiveStore
    @State private var panel: TvLivePanel? = nil
    /// Where the focus goes back when the panel closes.
    @State private var returnTo: TvLiveFocus = .surface
    /// The programme "Info programma" shows (nil = what is on now); `infoBack` = the panel BACK returns to.
    @State private var infoShowing: Showing? = nil
    @State private var infoBack: TvLivePanel? = nil
    @State private var keys = PassthroughSubject<String, Never>()
    @State private var lastOption = "channels"
    // zap banner
    @State private var zapCursor: String? = nil
    @State private var bannerShown = false
    @State private var bannerTask: Task<Void, Never>? = nil
    @State private var tuneTask: Task<Void, Never>? = nil
    @State private var lastZap = Date.distantPast
    @FocusState private var focus: TvLiveFocus?

    init(model: LivePlayerModel, player: NxPlayer, chrome: ChromeState) {
        self.model = model
        self.player = player
        self.chrome = chrome
    }

    private struct Option: Identifiable {
        let id: String
        let icon: String
        let title: String
        var active = false
        let action: () -> Void
    }

    private var optionFocused: Bool {
        if case .option = focus { return true }
        return false
    }
    private var infoShown: Bool { panel == nil && model.error == nil && (chrome.visible || optionFocused) }
    private var errorShown: Bool { model.error != nil && panel == nil }
    private var bannerVisible: Bool { bannerShown && !infoShown && panel == nil && model.error == nil }

    var body: some View {
        ZStack {
            surface
            if infoShown { infoLayer.transition(.opacity) }
            if bannerVisible { zapBanner.transition(.opacity.combined(with: .move(edge: .bottom))) }
            if errorShown { errorLayer.transition(.opacity) }
            if let p = panel { panelView(p).zIndex(5) }
        }
        .animation(.easeOut(duration: 0.2), value: panel)
        .animation(.easeOut(duration: 0.2), value: infoShown)
        .animation(.easeOut(duration: 0.18), value: bannerVisible)
        .onPlayPauseCommand { playPause() }
        .onReceive(NotificationCenter.default.publisher(for: .nxRemoteKey)) { n in remoteKey(n.object as? String ?? "") }
        .onAppear {
            focus = model.error != nil ? .error(0) : .surface
            chrome.show()
        }
        .onChange(of: focus) { _, f in
            if case .option(let id) = f { lastOption = id; chrome.show(auto: false) }
            if f == nil && panel == nil { DispatchQueue.main.async { if focus == nil && panel == nil { focus = restFocus } } }
        }
        .onChange(of: model.error != nil) { _, failed in
            guard panel == nil else { return }
            DispatchQueue.main.async { focus = failed ? .error(0) : .surface }
        }
        .onChange(of: model.currentId) { _, _ in if !bannerShown && panel == nil { showBanner() } }
        .task { await demo() }
    }

    /// Where the focus rests when nothing else has it.
    private var restFocus: TvLiveFocus { model.error != nil ? .error(0) : .surface }

    // MARK: surface

    /// An invisible button over the whole picture: it has the focus while watching, so select reaches it as a press and
    /// the arrows as move commands (nothing else is beside it, so the focus engine never moves away from it).
    private var surface: some View {
        Button { select() } label: {
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
        }
        .buttonStyle(NxPlainStyle(scale: 1))
        .focused($focus, equals: .surface)
        .disabled(panel != nil || model.error != nil)
        .onMoveCommand { dir in move(dir) }
        .onExitCommand { back() }
        .ignoresSafeArea()
    }

    private func move(_ dir: MoveCommandDirection) {
        switch dir {
        case .up: zap(1)
        case .down: if infoShown { focusOptions() } else { zap(-1) }
        case .left: open(.channels)
        case .right: open(.guide)
        default: break
        }
    }

    /// Select: confirms a zap still waiting, else the info bar with the focus on its options.
    private func select() {
        if tuneTask != nil { commitZap(); return }
        focusOptions()
    }

    private func focusOptions() {
        dropBanner()
        chrome.show(auto: false)
        let opts = options
        let id = opts.contains(where: { $0.id == lastOption }) ? lastOption : (opts.first?.id ?? "channels")
        DispatchQueue.main.async { focus = .option(id) }
    }

    /// Play / pause: shows the info bar; when it is already up, pauses or resumes the channel.
    private func playPause() {
        guard panel == nil, model.error == nil else { return }
        if infoShown {
            model.togglePause()
            chrome.show(auto: !model.paused && !optionFocused)
        } else {
            chrome.show(auto: !model.paused)
        }
    }

    /// BACK on the picture: the zap banner, then the info bar, then out of the player.
    private func back() {
        if bannerShown || tuneTask != nil { dropBanner(); return }
        if chrome.visible { chrome.hide(); return }
        app.closePlayer()
    }

    // MARK: zap

    /// Up / down: the first press tunes at once; presses that keep coming within 600 ms only move the banner's cursor,
    /// and the channel under it is tuned 600 ms after the last one.
    private func zap(_ d: Int) {
        let ids = model.zapList
        guard !ids.isEmpty else { return }
        chrome.hide()
        let base = zapCursor ?? model.currentId
        let i = ids.firstIndex(of: base) ?? 0
        let n = ids.count
        let target = ids[((i + d) % n + n) % n]
        let fast = Date().timeIntervalSince(lastZap) < 0.6
        lastZap = Date()
        zapCursor = target
        showBanner()
        tuneTask?.cancel()
        tuneTask = nil
        if !fast {
            model.tune(target)
            return
        }
        tuneTask = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            if Task.isCancelled { return }
            commitZap()
        }
    }

    private func commitZap() {
        tuneTask?.cancel()
        tuneTask = nil
        if let t = zapCursor, t != model.currentId { model.tune(t) }
        showBanner()
    }

    private func showBanner() {
        bannerShown = true
        bannerTask?.cancel()
        bannerTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if Task.isCancelled { return }
            if tuneTask != nil { return }
            bannerShown = false
            zapCursor = nil
        }
    }

    /// Hides the banner; a zap still waiting is dropped (the channel playing stays).
    private func dropBanner() {
        bannerTask?.cancel()
        tuneTask?.cancel()
        tuneTask = nil
        bannerShown = false
        zapCursor = nil
    }

    private var zapBanner: some View {
        let id = zapCursor ?? model.currentId
        return VStack {
            Spacer()
            HStack {
                if let c = app.core.channels.get(id) {
                    TvZapBanner(channel: c, showing: store.showing(c), pending: id != model.currentId)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.leading, 90).padding(.bottom, 70)
        .allowsHitTesting(false)
    }

    // MARK: info bar

    private var title: String {
        guard let c = model.channel else { return "" }
        return (model.now != nil || c.event != nil) ? (model.showing?.cardTitle ?? c.name) : c.name
    }

    private var infoLayer: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 18) {
                TvClock(size: 18)
                Spacer()
            }
            Spacer(minLength: 0)
            infoBar
            optionRow.padding(.top, 34)
        }
        .padding(.horizontal, 90).padding(.top, 60).padding(.bottom, 56)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(TvLiveScrim().allowsHitTesting(false))
        .ignoresSafeArea()
    }

    @ViewBuilder private var infoBar: some View {
        if let c = model.channel {
            VStack(alignment: .leading, spacing: 14) {
                channelLine(c)
                Text(title).font(NxFont.display(26, .bold)).foregroundStyle(.white).lineLimit(1)
                timeLine
                if let n = model.next {
                    Text("Dopo: \(TimeText.time(n.start))  \(n.title)").font(NxFont.ui(13, .semibold)).foregroundStyle(NxColor.textMuted).lineLimit(1)
                }
            }
            .frame(maxWidth: 1500, alignment: .leading)
        }
    }

    private func channelLine(_ c: ChannelEntity) -> some View {
        HStack(spacing: 18) {
            TvChannelMark(channel: c, width: 130, height: 64)
            if c.num > 0 { Text("\(c.num)").font(NxFont.ui(16, .heavy)).foregroundStyle(.white).monospacedDigit() }
            Text(c.name).font(NxFont.ui(16, .bold)).foregroundStyle(.white).lineLimit(1)
            QualityBadge(quality: model.playing.1)
            TvLiveBadge()
            if model.paused { NxTag(text: "In pausa", color: Color.white.opacity(0.22)) }
        }
    }

    @ViewBuilder private var timeLine: some View {
        if let s = model.showing, s.start != nil {
            HStack(spacing: 20) {
                if let t = s.timeLabel() { Text(t).font(NxFont.ui(13, .bold)).foregroundStyle(.white).monospacedDigit() }
                if let p = s.progress() { TvProgressLine(value: p, height: 6).frame(width: 460) }
                if let w = s.whenLabel() { Text(w).font(NxFont.ui(12, .semibold)).foregroundStyle(NxColor.textMuted) }
                if let l = s.cardLine, l != title { Text("· " + l).font(NxFont.ui(12, .semibold)).foregroundStyle(NxColor.textMuted).lineLimit(1) }
            }
        } else {
            Text("Nessuna informazione sul programma").font(NxFont.ui(13, .semibold)).foregroundStyle(NxColor.textMuted)
        }
    }

    private var options: [Option] {
        var a = [Option]()
        a.append(Option(id: "channels", icon: "list.bullet", title: "Canali") { open(.channels) })
        a.append(Option(id: "guide", icon: "calendar", title: "Guida") { open(.guide) })
        a.append(Option(id: "tracks", icon: "captions.bubble", title: "Audio e sottotitoli") { open(.tracks) })
        a.append(Option(id: "info", icon: "info.circle", title: "Info programma") { open(.info) })
        let fav = model.channel.map { store.favorites.contains($0.streamId) } ?? false
        a.append(Option(id: "fav", icon: fav ? "star.fill" : "star", title: "Preferito", active: fav) {
            if let c = model.channel { app.toggleFavorite(c) }
        })
        if model.variants().count > 1 {
            let q = model.playing.1 == "UHD" ? "4K" : model.playing.1
            a.append(Option(id: "versions", icon: "sparkles.tv", title: q.isEmpty ? "Versione" : "Versione · " + q) { open(.versions) })
        }
        return a
    }

    private var optionRow: some View {
        HStack(spacing: 22) {
            ForEach(options) { o in
                TvOptionButton(icon: o.icon, title: o.title, active: o.active, action: o.action)
                    .focused($focus, equals: .option(o.id))
            }
            Spacer(minLength: 0)
        }
        .focusSection()
        .onExitCommand { focus = .surface; chrome.show() }
    }

    // MARK: panels

    private func open(_ p: TvLivePanel) {
        dropBanner()
        if panel == nil { returnTo = focus ?? .surface }
        if p == .info { infoBack = panel == .guide ? .guide : nil }
        if p != .info { infoShowing = nil }
        chrome.hide()
        panel = p
    }

    private func closePanel() {
        if panel == .info, let b = infoBack {
            infoBack = nil
            infoShowing = nil
            panel = b
            return
        }
        panel = nil
        infoShowing = nil
        let to: TvLiveFocus = model.error != nil ? .error(0) : returnTo
        if case .option = to { chrome.show(auto: false) }
        DispatchQueue.main.async { focus = to }
    }

    @ViewBuilder private func panelView(_ p: TvLivePanel) -> some View {
        switch p {
        case .channels:
            TvChannelsPanel(model: model, keys: keys, onTune: tuneFromList, onClose: closePanel)
                .transition(.move(edge: .leading).combined(with: .opacity))
        case .guide:
            TvGuidePanel(model: model, keys: keys, onInfo: { s in infoShowing = s; open(.info) }, onClose: closePanel)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        case .tracks:
            TvTracksOverlay(player: model.player, keys: keys, onClose: closePanel).transition(.opacity)
        case .info:
            if let s = infoShowing ?? model.showing {
                TvProgrammeInfo(showing: s, keys: keys, onClose: closePanel).transition(.opacity)
            }
        case .versions:
            TvListOverlay(title: "Versione", subtitle: model.channel?.name, items: versionItems, keys: keys, onClose: closePanel).transition(.opacity)
        }
    }

    private func tuneFromList(_ c: ChannelEntity, _ ids: [String]) {
        returnTo = .surface
        closePanel()
        if c.streamId != model.currentId { model.switchTo(c.streamId, listIds: ids) }
    }

    private var versionItems: [TvListItem] {
        model.variants().map { v in
            let d = LivePlayerView.describe(v.1)
            return TvListItem(id: v.0, title: d.0, sub: d.1, selected: v.0 == model.playing.0, badge: v.1.isEmpty ? nil : (v.1 == "UHD" ? "4K" : v.1)) {
                closePanel()
                if v.0 != model.playing.0 { model.tune(model.currentId, variant: v) }
            }
        }
    }

    // MARK: error

    private var hasVersions: Bool { model.variants().count > 1 }

    /// The buttons of the error screen that exist now, in order.
    private var errorButtons: [Int] { hasVersions ? [0, 1, 2] : [0, 2] }

    private func errorAction(_ i: Int) {
        switch i {
        case 0: model.reconnectNow()
        case 1: otherVersion()
        default: zap(1)
        }
    }

    /// "Altra versione": the next quality of the channel.
    private func otherVersion() {
        let vs = model.variants()
        guard vs.count > 1 else { model.reconnectNow(); return }
        let i = vs.firstIndex { $0.0 == model.playing.0 } ?? 0
        model.tune(model.currentId, variant: vs[(i + 1) % vs.count])
    }

    private var errorLayer: some View {
        VStack(spacing: 22) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash").font(.system(size: 76, weight: .light)).foregroundStyle(NxColor.textMuted)
            Text("Il canale non risponde").font(NxFont.display(26, .bold)).foregroundStyle(.white)
            if let c = model.channel {
                Text((c.num > 0 ? "\(c.num)  " : "") + c.name).font(NxFont.ui(15, .bold)).foregroundStyle(NxColor.textMuted)
            }
            Text(model.error ?? "").font(NxFont.ui(13)).foregroundStyle(NxColor.textMuted).multilineTextAlignment(.center).lineLimit(3).frame(maxWidth: 1100)
            HStack(spacing: 14) {
                NxSpinner(size: 13)
                Text("Continuo a riprovare…").font(NxFont.ui(12, .semibold)).foregroundStyle(NxColor.textDim)
            }
            errorButtonRow.padding(.top, 16)
        }
        .padding(60)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.82).ignoresSafeArea())
        .onExitCommand { app.closePlayer() }
    }

    private var errorButtonRow: some View {
        HStack(spacing: 26) {
            NxButton("Riprova", icon: "arrow.clockwise", kind: .primary) { errorAction(0) }
                .focused($focus, equals: .error(0))
            if hasVersions {
                NxButton("Altra versione", icon: "sparkles.tv") { errorAction(1) }
                    .focused($focus, equals: .error(1))
            }
            NxButton("Canale successivo", icon: "forward.end.fill") { errorAction(2) }
                .focused($focus, equals: .error(2))
        }
        .focusSection()
    }

    // MARK: phone remote

    private func remoteKey(_ k: String) {
        if panel != nil {
            if k == "back" { closePanel() } else { keys.send(k) }
            return
        }
        if model.error != nil {
            errorKey(k)
            return
        }
        if case .option(let id) = focus {
            optionKey(k, id)
            return
        }
        switch k {
        case "up", "chup": zap(1)
        case "down": if infoShown { focusOptions() } else { zap(-1) }
        case "chdown": zap(-1)
        case "left": open(.channels)
        case "right": open(.guide)
        case "ok": select()
        case "menu": focusOptions()
        case "playpause": playPause()
        case "back": back()
        default: break
        }
    }

    private func errorKey(_ k: String) {
        let b = errorButtons
        var cur = 0
        if case .error(let i) = focus { cur = i }
        let at = b.firstIndex(of: cur) ?? 0
        switch k {
        case "left": if at > 0 { focus = .error(b[at - 1]) }
        case "right": if at + 1 < b.count { focus = .error(b[at + 1]) }
        case "ok": errorAction(cur)
        case "up", "chup": zap(1)
        case "down", "chdown": zap(-1)
        case "back": app.closePlayer()
        default: break
        }
    }

    private func optionKey(_ k: String, _ id: String) {
        let opts = options
        let i = opts.firstIndex(where: { $0.id == id }) ?? 0
        switch k {
        case "left": if i > 0 { focus = .option(opts[i - 1].id) }
        case "right": if i + 1 < opts.count { focus = .option(opts[i + 1].id) }
        case "ok": if i < opts.count { opts[i].action() }
        case "up", "back": focus = .surface; chrome.show()
        case "playpause": playPause()
        default: break
        }
    }

    // MARK: build pipeline

    /// Launch argument `-nxPlayerPanel info|options|zap|channels|guide|tracks|programme|versions|paused`: once the channel
    /// plays, put the player in that state so the build pipeline can take its picture (an unreachable test stream shows
    /// the error screen by itself).
    private func demo() async {
        guard let what = Demo.value("-nxPlayerPanel") else { return }
        for _ in 0..<60 {
            if player.state == .playing { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        NxLog.i("NxDebug", "live panel \(what)")
        switch what {
        case "info": chrome.show(auto: false)
        case "options": focusOptions()
        case "paused": model.togglePause(); chrome.show(auto: false)
        case "zap":
            zap(1)
            try? await Task.sleep(nanoseconds: 200_000_000)
            zap(1)
            try? await Task.sleep(nanoseconds: 200_000_000)
            zap(1)
            // keep the banner (and the cursor) on screen for the picture
            tuneTask?.cancel()
            tuneTask = nil
            bannerTask?.cancel()
        case "channels": open(.channels)
        case "guide": open(.guide)
        case "tracks": open(.tracks)
        case "programme": open(.info)
        case "versions": open(.versions)
        default: break
        }
    }
}

// MARK: - pieces

/// The darkening behind the info bar: a band at the top for the clock, a deep one at the bottom.
struct TvLiveScrim: View {
    var body: some View {
        LinearGradient(stops: [.init(color: .black.opacity(0.7), location: 0), .init(color: .clear, location: 0.2), .init(color: .clear, location: 0.38), .init(color: .black.opacity(0.94), location: 1)], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
    }
}

/// The red "IN DIRETTA" badge.
struct TvLiveBadge: View {
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Color.white).frame(width: 10, height: 10)
            Text("IN DIRETTA").font(NxFont.ui(10, .heavy)).tracking(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(NxColor.accent, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// A channel's logo on a dark tile, readable on any background (the broadcasters' logos are white).
struct TvChannelMark: View {
    let channel: ChannelEntity
    var width: CGFloat = 120
    var height: CGFloat = 60
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(NxColor.ink2)
            if channel.logo != nil || channel.icon != nil {
                ChannelLogo(channel: channel, height: height / 2 - 6)
            } else {
                Text(channel.name).font(NxFont.ui(11, .heavy)).foregroundStyle(.white).lineLimit(2).multilineTextAlignment(.center).padding(.horizontal, 8)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// The compact banner of a zap: number, logo, name and what is on.
struct TvZapBanner: View {
    let channel: ChannelEntity
    let showing: Showing
    let pending: Bool

    var body: some View {
        HStack(spacing: 26) {
            VStack(spacing: 4) {
                Image(systemName: "chevron.up").font(.system(size: 18, weight: .bold)).opacity(0.6)
                Text(channel.num > 0 ? "\(channel.num)" : "–").font(NxFont.display(24, .bold)).monospacedDigit()
                Image(systemName: "chevron.down").font(.system(size: 18, weight: .bold)).opacity(0.6)
            }
            .foregroundStyle(.white)
            .frame(minWidth: 90)
            TvChannelMark(channel: channel, width: 150, height: 84)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 14) {
                    Text(channel.name).font(NxFont.ui(15, .bold)).foregroundStyle(.white).lineLimit(1)
                    if pending { Text("OK per guardarlo").font(NxFont.ui(10, .bold)).foregroundStyle(NxColor.textMuted) }
                }
                Text(programmeTitle).font(NxFont.ui(14, .semibold)).foregroundStyle(NxColor.textMuted).lineLimit(1)
                if let p = showing.progress() {
                    HStack(spacing: 14) {
                        TvProgressLine(value: p, height: 5).frame(width: 300)
                        if let t = showing.timeLabel() { Text(t).font(NxFont.ui(11, .semibold)).foregroundStyle(NxColor.textDim).monospacedDigit() }
                    }
                }
            }
            .frame(width: 560, alignment: .leading)
        }
        .padding(.horizontal, 30).padding(.vertical, 22)
        .background(Color.black.opacity(0.84), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 1))
    }

    private var programmeTitle: String {
        (showing.programme != nil || channel.event != nil) ? showing.cardTitle : "Nessuna informazione sul programma"
    }
}

// MARK: - Canali

/// "Canali": a column on the left over the picture (which keeps playing). Category chips on top (Preferiti, Tutti, the
/// groups), the channels under them; the focus starts on the channel playing.
struct TvChannelsPanel: View {
    @ObservedObject var model: LivePlayerModel
    var keys: PassthroughSubject<String, Never>
    let onTune: (ChannelEntity, [String]) -> Void
    let onClose: () -> Void
    @EnvironmentObject var store: LiveStore
    @State private var group = "all"
    @State private var list: [ChannelEntity] = []
    @FocusState private var focus: String?

    private var groups: [(String, String)] {
        var a: [(String, String)] = [("fav", "Preferiti"), ("all", "Tutti")]
        a += store.categories.map { ($0.id, $0.label) }
        return a
    }

    private func channels(_ g: String) -> [ChannelEntity] {
        if g == "all" { return store.channels.filter { $0.shiftMin == 0 } }
        return store.channels(in: g)
    }

    var body: some View {
        HStack(spacing: 0) {
            column
            Spacer(minLength: 0)
        }
        .background(
            LinearGradient(stops: [.init(color: .black.opacity(0.95), location: 0), .init(color: .black.opacity(0.9), location: 0.4), .init(color: .clear, location: 0.62)], startPoint: .leading, endPoint: .trailing)
                .ignoresSafeArea()
        )
        .ignoresSafeArea()
        .onExitCommand(perform: onClose)
        .onAppear { list = channels(group) }
        .onChange(of: focus) { _, f in
            guard let f = f, f.hasPrefix("g:") else { return }
            let g = String(f.dropFirst(2))
            if g != group { group = g; list = channels(g) }
        }
        .onReceive(keys) { k in key(k) }
    }

    private var column: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Canali").font(NxFont.display(24, .bold)).foregroundStyle(.white)
                Spacer()
                TvClock(size: 14)
            }
            .padding(.trailing, 20)
            chips.padding(.top, 22)
            rows.padding(.top, 12)
        }
        .padding(.leading, 90).padding(.trailing, 30).padding(.top, 64)
        .frame(width: 860, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(groups, id: \.0) { g in
                    TvChip(title: g.1, icon: g.0 == "fav" ? "star.fill" : nil, selected: g.0 == group) { focusList() }
                        .focused($focus, equals: "g:" + g.0)
                }
            }
            .padding(.vertical, 10).padding(.horizontal, 4)
        }
        .focusSection()
    }

    private var rows: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if list.isEmpty {
                        Text(group == "fav" ? "Nessun preferito: aggiungili con «Preferito» dalle opzioni del canale." : "Nessun canale in questo gruppo.")
                            .font(NxFont.ui(13)).foregroundStyle(NxColor.textMuted).padding(.vertical, 20)
                    }
                    ForEach(list) { c in
                        TvChannelRow(showing: store.showing(c), playing: c.streamId == model.currentId, favorite: store.favorites.contains(c.streamId)) {
                            onTune(c, list.map { $0.streamId })
                        }
                        .focused($focus, equals: "c:" + c.streamId)
                        .id("c:" + c.streamId)
                    }
                }
                .padding(.vertical, 16).padding(.horizontal, 4)
            }
            .focusSection()
            .onAppear {
                if list.isEmpty { list = channels(group) }
                let start = startRow()
                if let s = start { proxy.scrollTo(s, anchor: .center) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { focus = start ?? "g:" + group }
            }
            .onChange(of: focus) { _, f in
                if let f = f, f.hasPrefix("c:") { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(f, anchor: .center) } }
            }
        }
    }

    private func startRow() -> String? {
        if list.contains(where: { $0.streamId == model.currentId }) { return "c:" + model.currentId }
        return list.first.map { "c:" + $0.streamId }
    }

    private func focusList() {
        if let s = startRow() { focus = s }
    }

    private func key(_ k: String) {
        let f = focus ?? ""
        if f.hasPrefix("g:") {
            let gs = groups.map { $0.0 }
            let i = gs.firstIndex(of: String(f.dropFirst(2))) ?? 0
            switch k {
            case "left": if i > 0 { focus = "g:" + gs[i - 1] }
            case "right": if i + 1 < gs.count { focus = "g:" + gs[i + 1] }
            case "down", "ok": focusList()
            case "back": onClose()
            default: break
            }
            return
        }
        let i = list.firstIndex(where: { "c:" + $0.streamId == f }) ?? 0
        switch k {
        case "up": if i > 0 { focus = "c:" + list[i - 1].streamId } else { focus = "g:" + group }
        case "down": if i + 1 < list.count { focus = "c:" + list[i + 1].streamId }
        case "ok": if i < list.count { onTune(list[i], list.map { $0.streamId }) }
        case "back", "left": onClose()
        default: break
        }
    }
}

/// A category chip of the channel list.
struct TvChip: View {
    let title: String
    var icon: String? = nil
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Focusable { f in
                HStack(spacing: 8) {
                    if let i = icon { Image(systemName: i).font(.system(size: 18, weight: .bold)) }
                    Text(title).font(NxFont.ui(12, .bold)).lineLimit(1)
                }
                .foregroundStyle(f ? Color.black : .white)
                .padding(.horizontal, 22).frame(height: 52)
                .background(f ? Color.white : (selected ? Color.white.opacity(0.26) : Color.white.opacity(0.08)), in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(selected && !f ? 0.6 : 0), lineWidth: 2))
                .animation(.easeOut(duration: 0.12), value: f)
            }
        }
        .buttonStyle(NxPlainStyle(scale: 0.96))
    }
}

/// One channel of the list: number, logo, name, what is on and how far it is.
struct TvChannelRow: View {
    let showing: Showing
    let playing: Bool
    let favorite: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Focusable { f in
                HStack(spacing: 20) {
                    Text(showing.channel.num > 0 ? "\(showing.channel.num)" : "").font(NxFont.ui(14, .heavy)).monospacedDigit()
                        .frame(width: 70, alignment: .trailing)
                    TvChannelMark(channel: showing.channel, width: 112, height: 62)
                    text(f)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(f ? Color.black : .white)
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(f ? Color.white : (playing ? Color.white.opacity(0.12) : Color.clear), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .animation(.easeOut(duration: 0.12), value: f)
            }
        }
        .buttonStyle(NxPlainStyle(scale: 0.98))
    }

    private func text(_ f: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(showing.channel.name).font(NxFont.ui(15, .bold)).lineLimit(1)
                if favorite { Image(systemName: "star.fill").font(.system(size: 18, weight: .bold)).foregroundStyle(f ? Color.black : NxColor.gold) }
                if playing { Image(systemName: "waveform").font(.system(size: 20, weight: .bold)).foregroundStyle(f ? NxColor.accentDeep : NxColor.accentBright) }
            }
            if showing.programme != nil || showing.channel.event != nil {
                Text(showing.cardTitle).font(NxFont.ui(12, .medium)).opacity(0.75).lineLimit(1)
            }
            if let p = showing.progress() {
                TvProgressLine(value: p, height: 4, track: f ? Color.black.opacity(0.15) : Color.white.opacity(0.2)).frame(width: 260)
            }
        }
    }
}

// MARK: - Guida

/// "Guida": a sheet at the bottom with what is on now and next on this channel. Select on the current programme opens
/// its info; on a future one sets or removes the reminder.
struct TvGuidePanel: View {
    @ObservedObject var model: LivePlayerModel
    var keys: PassthroughSubject<String, Never>
    let onInfo: (Showing) -> Void
    let onClose: () -> Void
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var store: LiveStore
    @State private var items: [ProgrammeEntity] = []
    @State private var loaded = false
    @FocusState private var focus: Int?

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            sheet
        }
        .ignoresSafeArea()
        .onExitCommand(perform: onClose)
        .onAppear(perform: load)
        .onReceive(keys) { k in key(k) }
    }

    private func load() {
        if let e = model.channel?.epgId { items = app.core.db.upcoming(e, now: Clock.now, limit: 12) }
        loaded = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { focus = 0 }
    }

    private var sheet: some View {
        VStack(alignment: .leading, spacing: 24) {
            header
            if items.isEmpty {
                empty
            } else {
                cards
            }
        }
        .padding(.horizontal, 90).padding(.top, 70).padding(.bottom, 64)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: 560, alignment: .top)
        .background(
            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black.opacity(0.88), location: 0.16), .init(color: .black.opacity(0.96), location: 1)], startPoint: .top, endPoint: .bottom)
        )
    }

    private var header: some View {
        HStack(spacing: 20) {
            if let c = model.channel { TvChannelMark(channel: c, width: 110, height: 56) }
            Text("Guida").font(NxFont.display(22, .bold)).foregroundStyle(.white)
            if let c = model.channel { Text(c.name).font(NxFont.ui(14, .semibold)).foregroundStyle(NxColor.textMuted) }
            Spacer()
            TvClock(size: 14)
        }
    }

    private var empty: some View {
        HStack(spacing: 30) {
            Text(loaded ? "La guida di questo canale non è disponibile." : "Carico la guida…").font(NxFont.ui(14)).foregroundStyle(NxColor.textMuted)
            NxButton("Chiudi", kind: .secondary, action: onClose).focused($focus, equals: 0)
        }
    }

    private var cards: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 24) {
                    ForEach(Array(items.enumerated()), id: \.offset) { i, p in
                        TvProgrammeCard(showing: showingOf(p), reminder: reminderOn(p)) { pick(p) }
                            .focused($focus, equals: i)
                            .id(i)
                    }
                }
                .padding(.vertical, 14).padding(.horizontal, 4)
            }
            .focusSection()
            .onChange(of: focus) { _, f in
                if let f = f { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(f, anchor: f < 2 ? .leading : .center) } }
            }
        }
    }

    private func showingOf(_ p: ProgrammeEntity) -> Showing {
        guard let c = model.channel else { return Showing(channel: ChannelEntity(streamId: ""), programme: p) }
        return store.showing(c, p)
    }

    private func reminderOn(_ p: ProgrammeEntity) -> Bool {
        guard let c = model.channel, store.reminders.contains(c.streamId) else { return false }
        return app.core.db.reminder(app.pid, c.streamId)?.at == p.start
    }

    private func pick(_ p: ProgrammeEntity) {
        let s = showingOf(p)
        if p.start > Clock.now { app.toggleReminder(s) } else { onInfo(s) }
    }

    private func key(_ k: String) {
        let i = focus ?? 0
        switch k {
        case "left": if i > 0 { focus = i - 1 }
        case "right": if i + 1 < items.count { focus = i + 1 }
        case "ok": if items.isEmpty { onClose() } else if i < items.count { pick(items[i]) }
        case "back", "up": onClose()
        default: break
        }
    }
}

/// A programme of the guide sheet.
struct TvProgrammeCard: View {
    let showing: Showing
    let reminder: Bool
    let action: () -> Void

    private var live: Bool { showing.isLive() }

    var body: some View {
        Button(action: action) {
            Focusable { f in
                content(f)
                    .padding(24)
                    .frame(width: 520, height: 300, alignment: .topLeading)
                    .background(f ? Color.white : Color.white.opacity(live ? 0.14 : 0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .animation(.easeOut(duration: 0.12), value: f)
            }
        }
        .buttonStyle(NxPlainStyle(scale: 0.97))
    }

    private func content(_ f: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                if live { TvLiveBadge() }
                Text(showing.timeLabel() ?? "").font(NxFont.ui(13, .heavy)).monospacedDigit()
                Spacer(minLength: 0)
                if reminder { Image(systemName: "bell.fill").font(.system(size: 22, weight: .bold)).foregroundStyle(f ? NxColor.accentDeep : NxColor.gold) }
            }
            Text(showing.cardTitle).font(NxFont.ui(16, .heavy)).lineLimit(2).multilineTextAlignment(.leading)
            if let l = showing.cardLine { Text(l).font(NxFont.ui(11, .semibold)).opacity(0.65).lineLimit(1) }
            if let o = showing.overview { Text(o).font(NxFont.ui(11)).opacity(0.8).lineLimit(3).multilineTextAlignment(.leading) }
            Spacer(minLength: 0)
            footer(f)
        }
        .foregroundStyle(f ? Color.black : .white)
    }

    @ViewBuilder private func footer(_ f: Bool) -> some View {
        if live {
            if let p = showing.progress() { TvProgressLine(value: p, height: 5, track: f ? Color.black.opacity(0.15) : Color.white.opacity(0.2)) }
        } else {
            HStack(spacing: 8) {
                Image(systemName: reminder ? "bell.fill" : "bell").font(.system(size: 18, weight: .bold))
                Text(reminder ? "Promemoria attivo" : "Avvisami quando inizia").font(NxFont.ui(11, .bold))
            }
            .opacity(f ? 1 : 0.6)
        }
    }
}

// MARK: - Info programma

/// "Info programma": the programme in full (title, time, plot, genre, year, picture) over the darkened channel.
struct TvProgrammeInfo: View {
    let showing: Showing
    var keys: PassthroughSubject<String, Never>
    let onClose: () -> Void
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var store: LiveStore
    @FocusState private var focus: Int?

    private var future: Bool { (showing.start ?? 0) > Clock.now }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.9).ignoresSafeArea()
            HStack(alignment: .top, spacing: 70) {
                text
                picture
            }
            .padding(.leading, 120).padding(.trailing, 100).padding(.top, 110)
        }
        .onExitCommand(perform: onClose)
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focus = 0 } }
        .onReceive(keys) { k in key(k) }
    }

    private var meta: String {
        var a = [String]()
        if let t = showing.timeLabel() { a.append(t) }
        if let k = showing.kindLabel { a.append(k) }
        if let s = showing.sub, s != showing.kindLabel { a.append(s) }
        if let y = showing.programme?.year, y > 0 { a.append(String(y)) }
        return a.joined(separator: "  ·  ")
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 18) {
                TvChannelMark(channel: showing.channel, width: 120, height: 60)
                Text(showing.channel.name).font(NxFont.ui(15, .bold)).foregroundStyle(NxColor.textMuted)
                if showing.isLive() { TvLiveBadge() }
            }
            Text(showing.cardTitle).font(NxFont.display(30, .bold)).foregroundStyle(.white).lineLimit(2)
            if let e = showing.episodeLine { Text(e).font(NxFont.ui(14, .semibold)).foregroundStyle(.white).lineLimit(1) }
            Text(meta).font(NxFont.ui(13, .semibold)).foregroundStyle(NxColor.textMuted).lineLimit(1)
            if showing.isLive(), let p = showing.progress() {
                HStack(spacing: 18) {
                    TvProgressLine(value: p, height: 6).frame(width: 460)
                    if let w = showing.whenLabel() { Text(w).font(NxFont.ui(12, .semibold)).foregroundStyle(NxColor.textMuted) }
                }
            }
            Text(showing.overview ?? "Nessuna descrizione per questo programma.")
                .font(NxFont.ui(14)).foregroundStyle(Color.white.opacity(0.88)).lineLimit(8).multilineTextAlignment(.leading)
                .padding(.top, 6)
            buttons.padding(.top, 20)
        }
        .frame(maxWidth: 960, alignment: .leading)
    }

    private var buttons: some View {
        HStack(spacing: 24) {
            NxButton(future ? "Torna al canale" : "Guarda", icon: "play.fill", kind: .primary, action: onClose)
                .focused($focus, equals: 0)
            if future {
                let on = store.reminders.contains(showing.channel.streamId)
                NxButton(on ? "Promemoria attivo" : "Avvisami", icon: on ? "bell.fill" : "bell") { app.toggleReminder(showing) }
                    .focused($focus, equals: 1)
            }
        }
        .focusSection()
    }

    @ViewBuilder private var picture: some View {
        if let u = Img.card(showing.image) ?? showing.poster.flatMap({ Img.card($0) }) {
            NxImage(url: u, maxPixel: 1000) { NxColor.ink3 }
                .frame(width: 640, height: 360)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func key(_ k: String) {
        switch k {
        case "left": focus = 0
        case "right": if future { focus = 1 }
        case "ok": if (focus ?? 0) == 1 { app.toggleReminder(showing) } else { onClose() }
        case "back": onClose()
        default: break
        }
    }
}
#endif
