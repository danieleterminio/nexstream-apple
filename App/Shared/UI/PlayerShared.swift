import SwiftUI

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
                if let m = app.live { LivePlayerView(model: m, full: full, width: g.size.width) }
                else if let m = app.vod { VodPlayerView(model: m, full: full, width: g.size.width).id(m.request.id) }
            }
            #if os(iOS)
            .statusBarHidden(full)
            .persistentSystemOverlays(full ? .hidden : .automatic)
            .onChange(of: full) { _, f in app.playerFull = f }
            .onAppear { app.playerFull = full }
            #endif
        }
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
    /// "Audio e sottotitoli": our own panel with the tracks of what is playing.
    func presentTracks(_ player: NxPlayer) {
        present("Audio e sottotitoli") { TracksPanel(player: player) }
    }
}

private struct TracksPanel: View {
    @ObservedObject var player: NxPlayer
    @EnvironmentObject var app: AppModel
    var body: some View {
        let audio = player.audioTracks, subs = player.subtitleTracks
        VStack(spacing: 0) {
            OptionHeader(title: "Audio")
            if audio.isEmpty { Text("Una sola traccia audio").font(NxFont.meta).foregroundStyle(NxColor.textDim).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, Metrics.u(16)).padding(.vertical, Metrics.u(8)) }
            ForEach(audio) { t in OptionRow(title: t.name.isBlank ? "Traccia \(t.id + 1)" : t.name, selected: t.id == player.currentAudio) { player.currentAudio = t.id } }
            OptionHeader(title: "Sottotitoli")
            if subs.count <= 1 { Text("Nessun sottotitolo disponibile").font(NxFont.meta).foregroundStyle(NxColor.textDim).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, Metrics.u(16)).padding(.vertical, Metrics.u(8)) }
            else { ForEach(subs) { t in OptionRow(title: t.id < 0 ? "Spenti" : t.name, selected: t.id == player.currentSubtitle) { player.currentSubtitle = t.id } } }
        }
        .id(player.tracksVersion)
    }
}
