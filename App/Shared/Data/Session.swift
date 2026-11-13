import Foundation
#if canImport(Security)
import Security
#endif

/// The signed-in line: resolved Xtream base + credentials.
struct LineSession: Codable, Equatable {
    var username: String
    var password: String
    var base: String
    var expiringAt: String? = nil
    var maxConnections: Int = 1
}

/// A few bytes that must survive everything (reinstalls aside): Keychain where there is one, UserDefaults otherwise.
enum SecureStore {
    private static let service = "app.nexstream.one"

    static func set(_ key: String, _ value: Data?) {
        #if canImport(Security)
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
        SecItemDelete(base as CFDictionary)
        if let v = value {
            var add = base
            add[kSecValueData as String] = v
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let rc = SecItemAdd(add as CFDictionary, nil)
            if rc != errSecSuccess { UserDefaults.standard.set(v, forKey: "sec." + key) } else { UserDefaults.standard.removeObject(forKey: "sec." + key) }
        } else {
            UserDefaults.standard.removeObject(forKey: "sec." + key)
        }
        #else
        if let v = value { UserDefaults.standard.set(v, forKey: "sec." + key) } else { UserDefaults.standard.removeObject(forKey: "sec." + key) }
        #endif
    }

    static func get(_ key: String) -> Data? {
        #if canImport(Security)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data { return d }
        #endif
        return UserDefaults.standard.data(forKey: "sec." + key)
    }
}

/// Storage for the current line.
final class Session {
    let current: Observable<LineSession?>

    init() {
        var loaded: LineSession? = nil
        if let d = SecureStore.get("line"), let s = try? JSONDecoder().decode(LineSession.self, from: d) { loaded = s }
        current = Observable(loaded)
    }

    func save(_ s: LineSession) {
        SecureStore.set("line", try? JSONEncoder().encode(s))
        current.value = s
    }

    /// Update just the base (dns_link) after a refresh, keeping credentials.
    func updateBase(_ base: String) {
        guard var s = current.value, s.base != base else { return }
        s.base = base
        save(s)
    }

    func clear() {
        SecureStore.set("line", nil)
        current.value = nil
    }
}

/// Playback settings (UserDefaults, observable). Quality, audio and subtitles are per profile (keys prefixed "p<id>.");
/// HEVC and the zapping pause describe the device, so they are global.
final class Prefs {
    struct Values: Equatable {
        var quality: String = "HD"          // AUTO (best) | FHD | HD | SD   (per profile)
        var hevc: Bool = true               // allow HEVC variants            (global)
        var zapDelayMs: Int = 700           // pause between stop and next prepare (global)
        var preferredAudio: String = "it"   // per profile
        var preferredText: String = ""      // "" = subtitles off              (per profile)
    }
    private let d = UserDefaults.standard
    private var pid: Int64 = 0
    let values: Observable<Values>

    init() { values = Observable(Values()); values.value = load() }

    private func k(_ name: String) -> String { pid > 0 ? "prefs.p\(pid).\(name)" : "prefs.\(name)" }
    private func load() -> Values {
        Values(quality: d.string(forKey: k("quality")) ?? "HD",
               hevc: d.object(forKey: "prefs.hevc") as? Bool ?? true,
               zapDelayMs: d.object(forKey: "prefs.zap") as? Int ?? 700,
               preferredAudio: d.string(forKey: k("audio")) ?? "it",
               preferredText: d.string(forKey: k("text")) ?? "")
    }
    /// Called when the viewer profile changes: per-profile values are re-read.
    func setProfile(_ id: Int64) { pid = id; values.value = load() }
    /// A deleted profile leaves nothing behind.
    static func forget(_ pid: Int64) {
        let d = UserDefaults.standard
        for k in d.dictionaryRepresentation().keys where k.hasPrefix("prefs.p\(pid).") { d.removeObject(forKey: k) }
    }
    func update(_ f: (inout Values) -> Void) {
        var v = values.value
        f(&v)
        d.set(v.quality, forKey: k("quality")); d.set(v.hevc, forKey: "prefs.hevc"); d.set(v.zapDelayMs, forKey: "prefs.zap")
        d.set(v.preferredAudio, forKey: k("audio")); d.set(v.preferredText, forKey: k("text"))
        values.value = v
    }

    static let qualities: [(String, String)] = [("AUTO", "Migliore disponibile"), ("FHD", "FHD"), ("HD", "HD"), ("SD", "SD")]
    private static func rank(_ q: String, _ hevc: Bool) -> Int {
        switch q { case "UHD": return 5; case "FHD": return 4; case "HD": return 3; case "HEVC": return hevc ? 2 : -1; default: return 1 }
    }
    /// All the variants of a channel as (streamId, quality), playable ones only.
    static func variants(_ variants: String, hevc: Bool) -> [(String, String)] {
        variants.split(separator: ",").compactMap { v -> (String, String)? in
            let p = v.split(separator: "|", omittingEmptySubsequences: false)
            return p.count == 2 ? (String(p[0]), String(p[1])) : nil
        }.filter { rank($0.1, hevc) >= 0 }
    }
    /// Pick the stream id to play among "id|Q,id|Q" variants for the wanted quality (closest available, HEVC only if allowed).
    static func pickVariant(_ variants: String, fallbackId: String, want: String, hevc: Bool) -> (String, String) {
        let vs = Prefs.variants(variants, hevc: hevc)
        if vs.isEmpty { return (fallbackId, "?") }
        if want == "AUTO" { return vs.max { rank($0.1, hevc) < rank($1.1, hevc) }! }
        let target = rank(want, hevc)
        // prefer exact, then the closest lower quality, then the closest higher
        if let exact = vs.first(where: { $0.1 == want }) { return exact }
        if let lower = vs.filter({ rank($0.1, hevc) < target }).max(by: { rank($0.1, hevc) < rank($1.1, hevc) }) { return lower }
        return vs.min { rank($0.1, hevc) < rank($1.1, hevc) }!
    }
}

/// Per-profile playback and UI preferences. `rev` bumps on every change so screens can refresh.
final class Settings {
    private let d = UserDefaults.standard
    let rev = Observable<Int>(0)
    private func bump() { rev.value += 1 }
    private func k(_ pid: Int64, _ n: String) -> String { "set.\(pid).\(n)" }
    /// A deleted profile leaves nothing behind.
    static func forget(_ pid: Int64) {
        let d = UserDefaults.standard
        for k in d.dictionaryRepresentation().keys where k.hasPrefix("set.\(pid).") { d.removeObject(forKey: k) }
    }

    func autoplay(_ pid: Int64) -> Bool { d.object(forKey: k(pid, "autoplay")) as? Bool ?? true }
    func setAutoplay(_ pid: Int64, _ v: Bool) { d.set(v, forKey: k(pid, "autoplay")); bump() }
    /// Preferred audio language: "it", "en", or "orig" (no preference, keeps the stream default).
    func audioLang(_ pid: Int64) -> String { d.string(forKey: k(pid, "audio")) ?? "it" }
    func setAudioLang(_ pid: Int64, _ v: String) { d.set(v, forKey: k(pid, "audio")); bump() }
    func speed(_ pid: Int64) -> Float { d.object(forKey: k(pid, "speed")) as? Float ?? 1 }
    func setSpeed(_ pid: Int64, _ v: Float) { d.set(v, forKey: k(pid, "speed")); bump() }
    func creditsPrompt(_ pid: Int64) -> Bool { d.object(forKey: k(pid, "credits")) as? Bool ?? true }
    func setCreditsPrompt(_ pid: Int64, _ v: Bool) { d.set(v, forKey: k(pid, "credits")); bump() }
    /// "Stai ancora guardando?": hours without input (0 = never) and episodes started by themselves.
    func stillWatchingHours(_ pid: Int64) -> Int { d.object(forKey: k(pid, "sw_hours")) as? Int ?? 2 }
    func setStillWatchingHours(_ pid: Int64, _ v: Int) { d.set(v, forKey: k(pid, "sw_hours")); bump() }
    func stillWatchingEpisodes(_ pid: Int64) -> Int { d.object(forKey: k(pid, "sw_eps")) as? Int ?? 3 }
    func setStillWatchingEpisodes(_ pid: Int64, _ v: Int) { d.set(v, forKey: k(pid, "sw_eps")); bump() }

    static let stillHoursOptions = [1, 2, 3, 4, 0]
    static let stillEpisodesOptions = [2, 3, 4, 5]
    static let audioOptions: [(String, String)] = [("it", "Italiano"), ("orig", "Lingua originale"), ("en", "Inglese")]
    static let speedOptions: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2]
    /// "Normale", "0,5×", "1,25×", "2×".
    static func speedLabel(_ v: Float) -> String {
        if v == 1 { return "Normale" }
        var t = String(format: "%.2f", Double(v))
        while t.hasSuffix("0") { t.removeLast() }
        if t.hasSuffix(".") { t.removeLast() }
        return t.replacingOccurrences(of: ".", with: ",") + "×"
    }
}

/// Who is watching. `current` is nil until a profile is picked (the picker is shown at every cold start, Netflix-style,
/// unless there is a single open profile).
final class Profiles {
    private let db: AppDB
    private let d = UserDefaults.standard
    let current = Observable<ProfileEntity?>(nil)
    /// Current profile id, 0 when none is selected.
    var id: Int64 { current.value?.id ?? 0 }
    var isKids: Bool { current.value?.kids == true }
    /// True after "Cambia profilo": the picker must be shown even if there is a single open profile.
    var pickRequested = false

    init(db: AppDB) { self.db = db }

    func all() -> [ProfileEntity] { db.profiles() }
    var lastId: Int64 { Int64(d.integer(forKey: "profiles.last")) }

    func select(_ p: ProfileEntity) {
        pickRequested = false
        d.set(Int(p.id), forKey: "profiles.last")
        current.value = p
    }
    /// "Cambia profilo": back to the picker.
    func deselect() { pickRequested = true; current.value = nil }
    /// Auto-enter when only one profile exists and it has no PIN; otherwise the picker is shown.
    @discardableResult
    func autoSelect() -> Bool {
        let all = db.profiles()
        guard all.count == 1, let only = all.first, only.pin == nil else { return false }
        select(only)
        return true
    }
    func add(name: String, color: Int, kids: Bool, icon: Int, maturity: Int, pin: String?) -> Int64 {
        db.insertProfile(ProfileEntity(name: name, avatarColor: color, kids: kids, pin: pin, avatarIcon: icon, maturity: maturity))
    }
    func update(_ p: ProfileEntity) {
        db.upsertProfile(p)
        if current.value?.id == p.id { current.value = p }
    }
    func delete(_ p: ProfileEntity) {
        db.deleteProfileCascade(p.id)
        Settings.forget(p.id); Prefs.forget(p.id)
        if current.value?.id == p.id { deselect() }
    }
    /// Re-read the current profile (after an edit from the manage screen).
    func refresh() { if id > 0, let p = db.profile(id) { current.value = p } }
}

/// Tracks viewer activity across episodes for the Netflix-style "Stai ancora guardando?" prompt.
final class WatchSession {
    var lastInputAt: Millis = Clock.now
    var autoplayed: Int = 0
    func touch() { lastInputAt = Clock.now; autoplayed = 0 }
    /// True when `episodes` episodes started by themselves and nothing was pressed for `hours` hours (0 disables the rule).
    func shouldAsk(hours: Int, episodes: Int) -> Bool {
        hours > 0 && episodes > 0 && autoplayed >= episodes && Clock.now - lastInputAt >= Millis(hours) * Clock.hour
    }
}
