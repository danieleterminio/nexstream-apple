import SwiftUI
import UIKit
import AVFoundation
#if os(iOS)
import UserNotifications
#endif

/// The bits that talk to the system: audio session, screen orientation while a video plays, notifications.
final class PlatformServices: NSObject, AlertScheduler {
    static let shared = PlatformServices()
    #if os(iOS)
    /// What the app delegate answers when the system asks which orientations are allowed.
    static var orientations: UIInterfaceOrientationMask = .allButUpsideDown
    private var asked = false
    #endif

    private override init() {
        super.init()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        NexCore.shared.reminders.scheduler = self
        NexCore.shared.teams.scheduler = self
        #if os(iOS)
        UNUserNotificationCenter.current().delegate = self
        #endif
    }

    func appBecameActive() {}

    func playerOpened() {
        try? AVAudioSession.sharedInstance().setActive(true)
        #if os(iOS)
        setOrientation(.landscape)
        #endif
    }

    func playerClosed() {
        UIApplication.shared.isIdleTimerDisabled = false
        #if os(iOS)
        setOrientation(.allButUpsideDown)
        #endif
    }

    #if os(iOS)
    private func setOrientation(_ mask: UIInterfaceOrientationMask) {
        if UIDevice.current.userInterfaceIdiom == .pad { return }
        PlatformServices.orientations = mask
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }
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

/// Lets the players ask for landscape while the rest of the app follows the phone.
final class NxAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask { PlatformServices.orientations }
}
#endif
