import SwiftUI
import UIKit
import AVFoundation
#if os(iOS)
import UserNotifications
import Intents
import BackgroundTasks
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
        #if os(iOS)
        let dl = NexCore.shared.downloads
        dl.onFinished = { [weak self] row in
            self?.schedule(id: "dl-\(row.id)", at: Clock.now + 1000, title: "Download completato",
                           body: "\(row.title)\(row.sub.map { " · \($0)" } ?? "") è pronto da guardare, anche senza rete.", url: "nexstream://open/downloads")
            Task { @MainActor in AppModel.shared.say("Download completato: \(row.title)") }
        }
        dl.onActivity = { [weak self] on in Task { @MainActor in self?.downloadTime(on) } }
        #endif
    }

    #if os(iOS)
    // MARK: downloads in the background

    static let downloadsTask = "app.nexstream.one.downloads"
    private var bgTask: UIBackgroundTaskIdentifier = .invalid

    /// While something downloads, the app asks for the extra time iOS gives when it leaves the screen (about 30 s);
    /// files keep going in the system's transfer service anyway, HLS segments only while the app runs.
    private func downloadTime(_ on: Bool) {
        if on {
            if bgTask != .invalid { return }
            bgTask = UIApplication.shared.beginBackgroundTask(withName: "downloads") { [weak self] in
                NxLog.i("NxDownloads", "background time over")
                self?.scheduleBackgroundDownloads()
                self?.downloadTime(false)
            }
        } else if bgTask != .invalid {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }
    }

    /// Called at launch (before it ends): the job iOS runs when it sees fit (usually charging, at night) to finish downloads.
    func registerBackgroundDownloads() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: PlatformServices.downloadsTask, using: nil) { [weak self] task in
            guard let t = task as? BGProcessingTask else { task.setTaskCompleted(success: false); return }
            self?.runBackgroundDownloads(t)
        }
    }

    /// The app leaves the screen with downloads still to do: ask iOS for a background run.
    func scheduleBackgroundDownloads() {
        let left = NexCore.shared.db.downloads().contains { $0.state == "queued" || $0.state == "running" }
        guard left else { return }
        let r = BGProcessingTaskRequest(identifier: PlatformServices.downloadsTask)
        r.requiresNetworkConnectivity = true
        r.requiresExternalPower = false
        do { try BGTaskScheduler.shared.submit(r) } catch { NxLog.w("NxDownloads", "background run not scheduled: \(error)") }
    }

    private func runBackgroundDownloads(_ task: BGProcessingTask) {
        NxLog.i("NxDownloads", "background run")
        let once = Once()
        let work = Task {
            NexCore.shared.downloads.wake()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                let left = NexCore.shared.db.downloads().contains { $0.state == "queued" || $0.state == "running" }
                if !left { break }
            }
            if once.take() { task.setTaskCompleted(success: true) }
        }
        task.expirationHandler = { [weak self] in
            work.cancel()
            self?.scheduleBackgroundDownloads()
            if once.take() { task.setTaskCompleted(success: false) }
        }
    }
    #endif

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

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        PlatformServices.shared.registerBackgroundDownloads()
        return true
    }

    /// iOS woke the app because background file transfers finished: the queue takes them over.
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == FileLoader.sessionId else { completionHandler(); return }
        FileLoader.shared.backgroundCompletion = completionHandler
        NexCore.shared.downloads.wake()
    }

    /// Siri's "riproduci … su NexStream" is answered inside the app (no extension).
    func application(_ application: UIApplication, handlerFor intent: INIntent) -> Any? {
        intent is INPlayMediaIntent ? PlayMediaHandler() : nil
    }
}
#endif

/// True the first time only (thread-safe).
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func take() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}
