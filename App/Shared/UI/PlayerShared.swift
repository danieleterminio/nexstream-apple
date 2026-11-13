import SwiftUI
#if os(iOS)
import MediaPlayer
import AVFoundation
#endif

/// Whether the player's controls are on screen: they show on a tap and leave by themselves.
@MainActor
final class ChromeState: ObservableObject {
    @Published var visible = true
    private var task: Task<Void, Never>? = nil

    func show(auto: Bool = true) {
        if !visible { withAnimation(.easeOut(duration: 0.18)) { visible = true } }
        task?.cancel()
        guard auto else { return }
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_500_000_000)
            if Task.isCancelled { return }
            withAnimation(.easeOut(duration: 0.25)) { self?.visible = false }
        }
    }
    func hide() { task?.cancel(); withAnimation(.easeOut(duration: 0.2)) { visible = false } }
    func toggle() { if visible { hide() } else { show() } }
}

/// What is playing, on top of everything. The video starts in the upper part of the screen with the phone upright;
/// turning the phone (or the full-screen button) fills the screen. On the TV it is always full screen.
struct PlayerScreen: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        GeometryReader { g in
            #if os(tvOS)
            let full = true
            #else
            let full = g.size.width > g.size.height
            #endif
            ZStack {
                Color.black.ignoresSafeArea()
                if app.cellularAsk { CellularGate() }
                else if let m = app.live { LivePlayerView(model: m, full: full, width: g.size.width) }
                else if let m = app.vod { VodPlayerView(model: m, full: full, width: g.size.width).id(m.request.id) }
            }
            #if os(iOS)
            .statusBarHidden(full)
            .persistentSystemOverlays(full ? .hidden : .automatic)
            .onChange(of: full) { _, f in app.playerFull = f }
            .onAppear { app.playerFull = full }
            #endif
        }
        #if os(tvOS)
        .ignoresSafeArea()
        #endif
        .overlay(alignment: .bottomTrailing) { if let r = app.reminder { ReminderBanner(reminder: r) } }
    }
}

/// A bare symbol over the video (no disc behind it): the transport keys and the corners of the player.
struct PlayerKey: View {
    let icon: String
    var label: String = ""
    var size: CGFloat = 30
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: size, weight: .semibold)).foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 4)
                .frame(width: size + 22, height: size + 22).contentShape(Rectangle())
        }
        .buttonStyle(NxPlainStyle(scale: 0.86))
        .accessibilityLabel(label)
    }
}

/// A symbol with its name, in the row under the progress bar (Episodi, Audio e sottotitoli, Velocità…).
struct PlayerOption: View {
    let icon: String
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 17, weight: .semibold))
                Text(title).font(NxFont.ui(13, .bold)).lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(.vertical, 8).padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(NxPlainStyle(scale: 0.94))
    }
}

#if os(iOS)
/// Our own progress bar: red for what was watched, a white knob to drag.
struct Scrubber: View {
    let position: Millis
    let duration: Millis
    let onScrub: (Millis) -> Void
    let onEnd: () -> Void
    @State private var dragging = false

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let f = duration > 0 ? CGFloat(max(0, min(1, Double(position) / Double(duration)))) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.3)).frame(height: dragging ? 5 : 3)
                Capsule().fill(NxColor.accent).frame(width: w * f, height: dragging ? 5 : 3)
                Circle().fill(NxColor.accent).frame(width: dragging ? 18 : 12, height: dragging ? 18 : 12).offset(x: w * f - (dragging ? 9 : 6))
                if dragging {
                    Text(playerClock(position)).font(NxFont.ui(13, .heavy)).foregroundStyle(.white).monospacedDigit()
                        .padding(.horizontal, 8).padding(.vertical, 4).background(Color.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 4))
                        .fixedSize().offset(x: max(0, min(w - 56, w * f - 28)), y: -30)
                }
            }
            .frame(height: 28)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                guard duration > 0 else { return }
                dragging = true
                onScrub(Millis(Double(duration) * Double(max(0, min(1, v.location.x / max(1, w))))))
            }.onEnded { _ in dragging = false; onEnd() })
            .animation(.easeOut(duration: 0.12), value: dragging)
        }
        .frame(height: 28)
    }
}
#endif

/// The dark bands that keep the controls readable over any picture.
struct PlayerScrim: View {
    var body: some View {
        LinearGradient(stops: [.init(color: .black.opacity(0.72), location: 0), .init(color: .black.opacity(0.18), location: 0.3), .init(color: .black.opacity(0.18), location: 0.62), .init(color: .black.opacity(0.78), location: 1)], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }
}

/// Shown in place of the picture while it is somewhere else (AirPlay, picture in picture).
struct ElsewhereNotice: View {
    let icon: String
    let text: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 34 * Metrics.unit, weight: .light)).foregroundStyle(NxColor.textMuted)
            Text(text).font(NxFont.meta).foregroundStyle(NxColor.textMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}

extension AppModel {
    /// "Audio e sottotitoli": our own panel with the tracks of what is playing. `onAudio` gets the name of an audio track
    /// the viewer picked (the on-demand player keeps it as the profile's language).
    func presentTracks(_ player: NxPlayer, onAudio: ((String) -> Void)? = nil) {
        present("Audio e sottotitoli") { TracksPanel(player: player, onAudio: onAudio) }
    }
}

/// The audio language a track name stands for, as the profile setting stores it: "it", "en" or "orig".
func audioLangOf(_ trackName: String) -> String {
    let n = " " + trackName.lowercased() + " "
    if ["ita", "italian", "[it]", " it "].contains(where: { n.contains($0) }) { return "it" }
    if ["eng", "english", "ingl", "[en]", " en "].contains(where: { n.contains($0) }) { return "en" }
    return "orig"
}

private struct TracksPanel: View {
    @ObservedObject var player: NxPlayer
    var onAudio: ((String) -> Void)? = nil
    @EnvironmentObject var app: AppModel
    var body: some View {
        let audio = player.audioTracks, subs = player.subtitleTracks
        VStack(spacing: 0) {
            OptionHeader(title: "Audio")
            if audio.isEmpty { Text("Una sola traccia audio").font(NxFont.meta).foregroundStyle(NxColor.textDim).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, Metrics.u(16)).padding(.vertical, Metrics.u(8)) }
            ForEach(audio) { t in OptionRow(title: t.name.isBlank ? "Traccia \(t.id + 1)" : t.name, selected: t.id == player.currentAudio) { player.currentAudio = t.id; onAudio?(t.name) } }
            OptionHeader(title: "Sottotitoli")
            if subs.count <= 1 { Text("Nessun sottotitolo disponibile").font(NxFont.meta).foregroundStyle(NxColor.textDim).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, Metrics.u(16)).padding(.vertical, Metrics.u(8)) }
            else { ForEach(subs) { t in OptionRow(title: t.id < 0 ? "Spenti" : t.name, selected: t.id == player.currentSubtitle) { player.currentSubtitle = t.id } } }
        }
        .id(player.tracksVersion)
    }
}

/// "Sei sulla rete mobile": before the first video of the run on mobile data (iPhone), in place of the player.
struct CellularGate: View {
    @EnvironmentObject var app: AppModel
    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "antenna.radiowaves.left.and.right").font(.system(size: 28, weight: .semibold)).foregroundStyle(NxColor.warning)
                .frame(width: 64, height: 64).background(NxColor.ink3, in: Circle())
            Text("Sei sulla rete mobile").font(NxFont.titleL).foregroundStyle(NxColor.text).multilineTextAlignment(.center).padding(.top, 16)
            Text("Un'ora di video in HD consuma circa 1,5–3 GB del tuo piano dati. Con il Wi-Fi non te lo chiedo.")
                .font(NxFont.body).foregroundStyle(NxColor.textMuted).multilineTextAlignment(.center).padding(.top, 8)
            HStack(spacing: 10) {
                NxButton("Guarda comunque", kind: .primary) { app.acceptCellular() }
                NxButton("Annulla", kind: .quiet) { app.closePlayer() }
            }
            .padding(.top, 20)
        }
        .padding(24)
        .frame(maxWidth: 460)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NxColor.bg.ignoresSafeArea())
    }
}

/// What a touch gesture on the player is changing, shown in the middle of the picture for a moment.
@MainActor
final class GestureFeedback: ObservableObject {
    enum Kind { case brightness, volume, back, forward }
    @Published private(set) var kind: Kind? = nil
    @Published private(set) var level: Double = 0
    private var hide: Task<Void, Never>? = nil
    /// Launch argument `-nxBubble`: the bubble stays on screen (build pipeline screenshots).
    private let pinned = Demo.args.contains("-nxBubble")
    init() { if pinned { kind = .volume; level = 0.6 } }

    func show(_ k: Kind, _ l: Double = 0) {
        kind = k; level = l
        hide?.cancel()
        if pinned { return }
        hide = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            if Task.isCancelled { return }
            withAnimation(.easeOut(duration: 0.2)) { self?.kind = nil }
        }
    }
}

/// The bubble of `GestureFeedback`: a symbol and a level bar (brightness / volume) or "10 s" (seek).
struct GestureBubble: View {
    @ObservedObject var feedback: GestureFeedback
    static func icon(_ k: GestureFeedback.Kind) -> String {
        switch k {
        case .brightness: return "sun.max.fill"
        case .volume: return "speaker.wave.2.fill"
        case .back: return "gobackward.10"
        case .forward: return "goforward.10"
        }
    }
    var body: some View {
        if let k = feedback.kind {
            HStack(spacing: 12) {
                Image(systemName: GestureBubble.icon(k))
                    .font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
                if k == .brightness || k == .volume {
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.3)).frame(width: 120, height: 4)
                        Capsule().fill(Color.white).frame(width: 120 * max(0, min(1, feedback.level)), height: 4)
                    }
                } else {
                    Text("10 s").font(NxFont.button).foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
            .background(Color.black.opacity(0.65), in: Capsule())
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }
}

#if os(iOS)
/// The screen brightness and the system volume, for the player's drag gestures.
@MainActor
enum SystemLevels {
    private static var screen: UIScreen? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }?.screen
    }
    static var brightness: Double {
        get { Double(screen?.brightness ?? 0.5) }
        set { screen?.brightness = CGFloat(max(0.02, min(1, newValue))) }
    }
    static var volume: Double {
        get { Double(AVAudioSession.sharedInstance().outputVolume) }
        set { VolumeHook.slider?.value = Float(max(0, min(1, newValue))) }
    }
}

/// An invisible system volume view: its slider is the only way an app may set the volume, and while it is on screen the
/// system's own volume bubble stays away.
struct VolumeHook: UIViewRepresentable {
    static weak var slider: UISlider? = nil
    func makeUIView(context: Context) -> MPVolumeView {
        let v = MPVolumeView(frame: CGRect(x: -200, y: -200, width: 10, height: 10))
        v.isUserInteractionEnabled = false
        VolumeHook.slider = v.subviews.compactMap { $0 as? UISlider }.first
        return v
    }
    func updateUIView(_ uiView: MPVolumeView, context: Context) {
        if VolumeHook.slider == nil { VolumeHook.slider = uiView.subviews.compactMap { $0 as? UISlider }.first }
    }
}
#endif
