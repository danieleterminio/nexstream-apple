import SwiftUI
import UIKit
import AVFoundation
#if os(iOS)
import UserNotifications
import Intents
#endif

/// The bits that talk to the system: audio session, screen orientation while a video plays, notifications.
final class PlatformServices: NSObject, AlertScheduler {
    static let shared = PlatformServices()
    #if os(iOS)
    /// What the app delegate answers when the system asks which orientations are allowed: the phone app is upright,
    /// only the player may turn.
    static var orientations: UIInterfaceOrientationMask = UIDevice.current.userInterfaceIdiom == .pad ? .all : .portrait
    private var asked = false
    #endif

    private override init() {
        super.init()
        #if os(iOS)
        // "long-form video": the session the system expects from a video app (AirPlay routes, CarPlay, Control Centre)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, policy: .longFormVideo)
        UNUserNotificationCenter.current().delegate = self
        #else
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        #endif
        NexCore.shared.reminders.scheduler = self
        NexCore.shared.teams.scheduler = self
    }

    func appBecameActive() {}

    func playerOpened() {
        try? AVAudioSession.sharedInstance().setActive(true)
        #if os(iOS)
        setMask(.allButUpsideDown)
        #endif
    }

    func playerClosed() {
        UIApplication.shared.isIdleTimerDisabled = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom != .pad {
            setMask(.portrait)
            request(.portrait)
        }
        #endif
    }

    #if os(iOS)
    private var scene: UIWindowScene? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.session.role == .windowApplication }
    }

    private func setMask(_ mask: UIInterfaceOrientationMask) {
        if UIDevice.current.userInterfaceIdiom == .pad { return }
        PlatformServices.orientations = mask
        scene?.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }

    private func request(_ mask: UIInterfaceOrientationMask) {
        scene?.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { e in NxLog.w("NxPlatform", "rotation refused: \(e.localizedDescription)") }
    }

    /// The full-screen button of the player: turns the picture without turning the phone.
    func rotate(landscape: Bool) {
        if UIDevice.current.userInterfaceIdiom == .pad { return }
        request(landscape ? .landscapeRight : .portrait)
    }
    #else
    func rotate(landscape: Bool) {}
    #endif

    // MARK: AlertScheduler

    func requestPermission() {
        #if os(iOS)
        if asked { return }
        asked = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        #endif
    }

    func schedule(id: String, at: Millis, title: String, body: String, url: String) {
        #if os(iOS)
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["url": url]
        let secs = max(1, Double(at - Clock.now) / 1000)
        let req = UNNotificationRequest(identifier: id, content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: secs, repeats: false))
        UNUserNotificationCenter.current().add(req) { e in if let e = e { NxLog.w("NxNotify", "\(e)") } }
        #endif
    }

    func cancel(id: String) {
        #if os(iOS)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
        #endif
    }
}

#if os(iOS)
extension PlatformServices: UNUserNotificationCenterDelegate {
    /// With the app open the in-app "Sta per iniziare" does the job: no banner on top of it.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([])
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        if let s = response.notification.request.content.userInfo["url"] as? String, let u = URL(string: s) { NexCore.shared.handle(url: u) }
        completionHandler()
    }
}

/// Lets the player turn the screen while the rest of the phone app stays upright.
final class NxAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask { PlatformServices.orientations }

    /// Siri's "riproduci … su NexStream" is answered inside the app (no extension).
    func application(_ application: UIApplication, handlerFor intent: INIntent) -> Any? {
        intent is INPlayMediaIntent ? PlayMediaHandler() : nil
    }
}
#endif
