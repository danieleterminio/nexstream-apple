import SwiftUI
import UIKit

@main
struct NexStreamApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(NxAppDelegate.self) private var appDelegate
    #endif
    @StateObject private var app = AppModel.shared
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .environmentObject(app.store)
                .preferredColorScheme(.dark)
                .tint(.white)
                .onOpenURL { app.core.handle(url: $0) }
                .onChange(of: phase) { _, p in
                    if p == .active { Vpn.shared.refresh(); app.checkForUpdate(); app.core.checkAlerts(); PlatformServices.shared.appBecameActive(); app.core.sync.kick(after: 0.5) }
                    if p == .background { app.core.sync.kick(after: 0) }
                    #if os(tvOS)
                    if p == .active { RemoteHost.shared.start() } else if p == .background { RemoteHost.shared.stop() }
                    #else
                    if p == .active { app.core.downloads.wake(); app.playerHidden = false }
                    if p == .background { PlatformServices.shared.scheduleBackgroundDownloads() }
                    #endif
                }
        }
    }
}

/// The gates, in order: VPN → line → profile → app. Each one is a plain `if`, so when the VPN drops the whole app leaves
/// the screen at once (the app model stops the stream), and when the profile changes every page starts over. On top of
/// the gates: the player, our panels, the short messages.
struct RootView: View {
    @EnvironmentObject var app: AppModel
    @State private var intro = true

    private var playerShown: Bool {
        guard let p = app.playing, !app.playerHidden else { return false }
        return app.vpn || p.isOffline
    }

    var body: some View {
        ZStack {
            NxColor.bg.ignoresSafeArea()
            content
                // nothing under the opening takes the focus or a tap while it plays (it is not skippable)
                .disabled(playerShown || !app.sheets.isEmpty || intro)
                #if os(tvOS)
                // a gate (VPN, line, "Chi guarda?") has nothing behind it: BACK asks before leaving the app
                .onExitCommand(perform: app.profile == nil || app.session == nil || !app.vpn || app.onboardingFor != nil ? { app.askExit() } : nil)
                #endif
            if playerShown {
                PlayerScreen()
                    .accessibilityElement(children: .contain).accessibilityIdentifier("player.screen")
                    .disabled(!app.sheets.isEmpty)
                    .transition(.move(edge: .bottom))
                    .zIndex(1)
            }
            SheetHost().zIndex(2)
            if let t = app.toast { ToastView(text: t).zIndex(3) }
            #if os(tvOS)
            RemotePairBanner().zIndex(3)
            #endif
            // the opening, at every cold start (this view is built once per launch); it fades itself out at the end
            if intro { BrandIntro { intro = false }.zIndex(4) }
        }
        .animation(.easeInOut(duration: 0.25), value: app.toast)
        .animation(.easeOut(duration: 0.28), value: playerShown)
        .onAppear {
            #if os(tvOS)
            RemoteHost.shared.start()
            TopShelfHook.start()
            BackGuard.install()
            #else
            app.core.downloads.wake()
            #endif
        }
        // app updates (notice only): at launch and every time the VPN comes up; AppUpdates spaces the reads out
        .onChange(of: app.vpn) { _, on in if on { app.checkForUpdate() } }
        .task { app.checkForUpdate() }
        .onReceive(NotificationCenter.default.publisher(for: .nxRemoteKey)) { n in if (n.object as? String) == "home" { app.goHome() } }
    }

    @ViewBuilder private var content: some View {
        if !app.vpn {
            #if os(iOS)
            if app.offlineDownloads { DownloadsView(offline: true) }
            else if app.gateRemote { RemoteView(onClose: { app.gateRemote = false }) }
            else { VpnGateView() }
            #else
            VpnGateView()
            #endif
        } else if app.session == nil {
            LoginView()
        } else if let p = app.profile {
            if app.onboardingFor != nil {
                OnboardingView(profileId: app.onboardingFor ?? p.id) { app.onboardingFor = nil }
            } else {
                MainView(profile: p)
                    .id(p.id)
                    .overlay(alignment: .bottomTrailing) { if let r = app.reminder, !playerShown { ReminderBanner(reminder: r) } }
            }
        } else {
            ProfilesView()
        }
    }
}

struct ToastView: View {
    let text: String
    var body: some View {
        VStack {
            Spacer()
            Text(text).font(NxFont.ui(13, .bold)).foregroundStyle(.black).multilineTextAlignment(.center)
                .padding(.horizontal, Metrics.u(16)).padding(.vertical, Metrics.u(11))
                .background(Color.white, in: RoundedRectangle(cornerRadius: Metrics.u(5), style: .continuous))
                .padding(.horizontal, Metrics.u(20))
                .padding(.bottom, Metrics.u(Metrics.tv ? 40 : 84))
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .allowsHitTesting(false)
    }
}

/// "Sta per iniziare": shown on top of whatever is on screen when a reminder (or a followed team's match) is due.
struct ReminderBanner: View {
    let reminder: ReminderEntity
    @EnvironmentObject var app: AppModel

    var body: some View {
        let mins = max(0, (reminder.at - Clock.now + 30_000) / Clock.minute)
        VStack(alignment: .leading, spacing: Metrics.u(8)) {
            HStack(spacing: Metrics.u(8)) {
                NxTag(text: mins == 0 ? "Inizia ora" : (mins == 1 ? "Tra 1 minuto" : "Tra \(mins) minuti"), color: NxColor.accent)
                Text(reminder.createdAt == 0 ? "La tua squadra" : "Promemoria").font(NxFont.label).foregroundStyle(NxColor.textDim)
            }
            Text(reminder.title).font(NxFont.titleM).foregroundStyle(NxColor.text).lineLimit(2)
            if let s = reminder.sub { Text(s).font(NxFont.meta).foregroundStyle(NxColor.textMuted).lineLimit(1) }
            HStack(spacing: Metrics.u(10)) {
                NxButton("Guarda", icon: "play.fill", kind: .primary) {
                    app.core.reminderAlert.value = nil
                    if let c = app.core.channels.get(reminder.streamId) { app.play(c) }
                }
                NxButton("Ignora", kind: .secondary) { app.core.reminderAlert.value = nil }
            }
            #if os(tvOS)
            .focusSection()
            #endif
        }
        .padding(Metrics.u(16))
        .frame(maxWidth: Metrics.u(360), alignment: .leading)
        .nxPanel(fill: NxColor.ink3)
        .padding(Metrics.u(16))
        .padding(.bottom, Metrics.u(Metrics.tv ? 0 : 60))
        .transition(.move(edge: .trailing).combined(with: .opacity))
    }
}
