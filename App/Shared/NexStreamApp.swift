import SwiftUI
import UIKit

@main
struct NexStreamApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(NxAppDelegate.self) private var appDelegate
    #endif
    @StateObject private var app = AppModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .environmentObject(app.store)
                .preferredColorScheme(.dark)
                #if os(iOS)
                .tint(NxColor.accent)
                #endif
                .onOpenURL { app.core.handle(url: $0) }
                .onChange(of: phase) { _, p in
                    if p == .active { Vpn.shared.refresh(); app.core.checkAlerts(); PlatformServices.shared.appBecameActive() }
                    #if os(tvOS)
                    if p == .active { RemoteHost.shared.start() } else if p == .background { RemoteHost.shared.stop() }
                    #else
                    if p == .active { app.core.downloads.wake() }
                    #endif
                }
        }
    }
}

/// The gates, in order: VPN → line → profile → app. Each one is a plain `if`, so when the VPN drops the whole app (player
/// included) leaves the screen at once, and when the profile changes every page starts over.
struct RootView: View {
    @EnvironmentObject var app: AppModel
    @State private var intro = true

    var body: some View {
        ZStack {
            NxColor.bg.ignoresSafeArea()
            content
            if let t = app.toast { ToastView(text: t) }
            #if os(tvOS)
            RemotePairBanner()
            #endif
            if intro { BrandIntro { withAnimation(.easeOut(duration: 0.35)) { intro = false } } }
        }
        .animation(.easeInOut(duration: 0.25), value: app.toast)
        .onAppear {
            #if os(tvOS)
            RemoteHost.shared.start()
            #else
            app.core.downloads.wake()
            #endif
        }
        .onReceive(NotificationCenter.default.publisher(for: .nxRemoteKey)) { n in if (n.object as? String) == "home" { app.goHome() } }
    }

    @ViewBuilder private var content: some View {
        if !app.vpn {
            #if os(iOS)
            if app.offlineDownloads { OfflineDownloadsGate() } else { VpnGateView() }
            #else
            VpnGateView()
            #endif
        } else if app.session == nil {
            LoginView()
        } else if let p = app.profile {
            MainView(profile: p)
                .id(p.id)
                .fullScreenCover(item: $app.playing) { playing in
                    PlayerHost(playing: playing).environmentObject(app).environmentObject(app.store)
                }
                .fullScreenCover(item: onboardingBinding) { o in
                    OnboardingView(profileId: o.id) { app.onboardingFor = nil }.environmentObject(app).environmentObject(app.store)
                }
                .overlay(alignment: .bottomTrailing) { if let r = app.reminder { ReminderBanner(reminder: r) } }
        } else if app.manageProfilesGate {
            ProfilesView(manage: true) { app.manageProfilesGate = false; app.core.profiles.refresh() }
        } else {
            ProfilesView()
        }
    }

    private struct OnboardingTarget: Identifiable { let id: Int64 }
    private var onboardingBinding: Binding<OnboardingTarget?> {
        Binding(get: { app.onboardingFor.map { OnboardingTarget(id: $0) } }, set: { if $0 == nil { app.onboardingFor = nil } })
    }
}

/// Opening animation: the mark breathes once on the page colour ("Respiro"), then the app shows.
struct BrandIntro: View {
    let onDone: () -> Void
    @State private var scale = 0.86
    @State private var glow = 0.0
    var body: some View {
        ZStack {
            NxColor.bg.ignoresSafeArea()
            Circle().fill(NxColor.accent.opacity(0.35)).frame(width: Metrics.u(220), height: Metrics.u(220)).blur(radius: Metrics.u(60)).opacity(glow)
            Image("BrandSymbol").resizable().scaledToFit().frame(width: Metrics.u(110), height: Metrics.u(110)).scaleEffect(scale)
        }
        .task {
            withAnimation(.easeInOut(duration: 0.7)) { scale = 1.04; glow = 1 }
            try? await Task.sleep(nanoseconds: 750_000_000)
            withAnimation(.easeInOut(duration: 0.4)) { scale = 1.0; glow = 0.5 }
            try? await Task.sleep(nanoseconds: 450_000_000)
            onDone()
        }
    }
}

struct ToastView: View {
    let text: String
    var body: some View {
        VStack {
            Spacer()
            Text(text).font(NxFont.meta).foregroundStyle(NxColor.text).multilineTextAlignment(.center)
                .padding(.horizontal, Metrics.u(18)).padding(.vertical, Metrics.u(12))
                .nxGlass(Capsule())
                .padding(.bottom, Metrics.u(Metrics.tv ? 40 : 96))
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
                NxButton("Ignora", kind: .quiet) { app.core.reminderAlert.value = nil }
            }
        }
        .padding(Metrics.u(18))
        .frame(maxWidth: Metrics.u(380), alignment: .leading)
        .nxGlassPanel()
        .padding(Metrics.u(18))
        .transition(.move(edge: .trailing).combined(with: .opacity))
    }
}
