import SwiftUI

/// One platform entry of the update manifest (NexStreamSync/UPDATES.md).
struct AppleRelease: Decodable, Equatable {
    var versionName: String = ""
    var build: Int = 0
    /// Builds below this one are told the update is needed (still only a notice: a sideloaded app cannot install itself).
    var minVersion: Int? = nil
    var notes: [String] = []
    var url: String? = nil
    var sha256: String? = nil
    var size: Int64? = nil
}

private struct UpdateManifest: Decodable {
    var ios: AppleRelease?
    var tvos: AppleRelease?
}

/// App updates on Apple devices: a NON-blocking notice. The manifest is read at launch and when the app comes back after
/// a few hours; a newer build is offered once per version as a panel ("Nuova versione disponibile x.y") and stays as a
/// line in Settings → Informazioni. Android installs by itself and blocks instead (AppUpdate.kt).
@MainActor
final class AppUpdates: ObservableObject {
    static let shared = AppUpdates()

    static let base = "https://nexstream-update.nexxst.workers.dev"
    static let recheck: TimeInterval = 4 * 3600

    /// A release newer than this build (nil = up to date or unknown).
    @Published private(set) var available: AppleRelease? = nil
    private var lastCheck: Date? = nil
    private var checking = false

    static var installedBuild: Int { Int((Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0").split(separator: ".").first ?? "0") ?? 0 }
    static var installedName: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "" }

    #if os(tvOS)
    static let platform = "tvos"
    #else
    static let platform = "ios"
    #endif

    /// `-nxUpdateChannel test` reads the test manifest (simulator checks); the release builds read "stable".
    private var channel: String {
        let ch = (Demo.value("-nxUpdateChannel") ?? "stable").lowercased()
        return ch.range(of: "^[a-z0-9-]{1,24}$", options: .regularExpression) != nil ? ch : "stable"
    }

    var enabled: Bool { !Secrets.updateKey.isEmpty }

    /// Was this release's panel already shown?
    func seen(_ r: AppleRelease) -> Bool { UserDefaults.standard.integer(forKey: "nx.update.seenBuild") >= r.build }
    func markSeen(_ r: AppleRelease) { UserDefaults.standard.set(r.build, forKey: "nx.update.seenBuild") }

    func required(_ r: AppleRelease) -> Bool { Self.installedBuild < (r.minVersion ?? 0) }

    /// Cheap to call often: at most one read per `recheck` unless `force`.
    func checkIfDue(force: Bool = false) async {
        guard enabled, !checking else { return }
        if !force, let l = lastCheck, Date().timeIntervalSince(l) < Self.recheck { return }
        checking = true
        defer { checking = false }
        do {
            let url = "\(Self.base)/v1/manifest?ch=\(channel)"
            let r = try await Http.request(url, headers: ["X-Update-Key": Secrets.updateKey, "Cache-Control": "no-cache", "Accept": "application/json"])
            lastCheck = Date()
            if r.status == 404 { available = nil; return }
            guard r.ok else { throw HttpError(status: r.status, url: "update manifest") }
            let m = try JSONDecoder().decode(UpdateManifest.self, from: r.data)
            #if os(tvOS)
            let rel = m.tvos
            #else
            let rel = m.ios
            #endif
            NxLog.i("update", "manifest[\(channel)] \(Self.platform): \(rel?.versionName ?? "-") (\(rel?.build ?? 0)), installed \(Self.installedBuild)")
            if let rel, rel.build > Self.installedBuild { available = rel } else { available = nil }
        } catch {
            NxLog.i("update", "check failed: \(error)")
        }
    }
}
