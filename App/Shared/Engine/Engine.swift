import Foundation

struct SearchHit: Codable {
    var channel: String
    var title: String
    var year: Int?
    var type: String
    var action: String?
    var url: String?
    var thumb: String?
    var item: String
    var score: Double?
    var scoreValue: Double { score ?? 0 }
}

struct SearchResponse: Codable {
    var results: [SearchHit]?
    var errors: [String: String?]?
    var elapsed: Double?
    var hits: [SearchHit] { results ?? [] }
}

struct EpisodeHit: Codable {
    var season: Int
    var episode: Int
    var title: String
    var item: String
}

struct Playable: Codable, Hashable {
    var url: String
    var headers: [String: String]?
    var kind: String?
    var label: String?
    var kindValue: String { kind ?? "progressive" }
    var headerMap: [String: String] { headers ?? [:] }
}

struct PlayResponse: Codable {
    struct Tried: Codable { var server: String; var ok: Bool; var error: String? }
    var url: String?
    var headers: [String: String]?
    var kind: String?
    var label: String?
    var server: String?
    var tried: [Tried]?
    var all: [Playable]?
}

struct EngineChannelInfo: Codable {
    var id: String
    var name: String?
    var active: Bool
    var categories: [String]?
    var language: [String]?
}

struct EngineError: Error, CustomStringConvertible {
    let description: String
}

/// Swift facade over `nxbridge.py`: Stream4Me (the Kodi addon) running headless inside the embedded CPython, exactly as the
/// Android app runs it through Chaquopy. The addon ships inside the app bundle and is copied to a writable folder on first
/// run, so it can be updated from GitHub independently of the app.
final class Engine {
    static let shared = Engine()
    private let queue = DispatchQueue(label: "nx.engine", qos: .userInitiated, attributes: .concurrent)
    private let initLock = NSLock()
    private var ready = false
    private(set) var initInfo: String = ""

    var addonDir: URL { Paths.support.appendingPathComponent("s4me", isDirectory: true) }
    var dataDir: URL { Paths.support.appendingPathComponent("kodi", isDirectory: true) }

    /// Blocking; call off the main thread (the async wrappers below do).
    func ensureReadySync() throws {
        initLock.lock(); defer { initLock.unlock() }
        if ready { return }
        let t0 = Date()
        guard let res = Bundle.main.resourcePath else { throw EngineError(description: "no bundle") }
        if !NXPython.isStarted {
            if let err = NXPython.start(withHome: res + "/python", paths: [res + "/PythonApp"]) { throw EngineError(description: "python: \(err)") }
        }
        try extractAddonIfNeeded(bundlePath: res)
        var err: NSString?
        guard let r = NXPython.call("nxbridge", function: "init", args: [addonDir.path, dataDir.path], error: &err) else {
            throw EngineError(description: (err as String?) ?? "init failed")
        }
        initInfo = r
        ready = true
        NxLog.i("NxEngine", "bridge init in \(String(format: "%.2f", Date().timeIntervalSince(t0))) s: \(r)")
    }

    func ensureReady() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            queue.async { do { try self.ensureReadySync(); c.resume() } catch { c.resume(throwing: error) } }
        }
    }

    private func bundledVersion(_ bundlePath: String) -> String {
        guard let xml = try? String(contentsOfFile: bundlePath + "/s4me/addon.xml", encoding: .utf8) else { return "0" }
        return xml.firstMatch(#"<addon[^>]*version="([^"]+)""#)?[1] ?? "0"
    }

    private func extractAddonIfNeeded(bundlePath: String) throws {
        let fm = FileManager.default
        let stamp = addonDir.appendingPathComponent(".version")
        let version = bundledVersion(bundlePath)
        if let have = try? String(contentsOf: stamp, encoding: .utf8), have == version, fm.fileExists(atPath: addonDir.appendingPathComponent("addon.xml").path) { return }
        NxLog.i("NxEngine", "extracting Stream4Me \(version) to \(addonDir.path)")
        try? fm.removeItem(at: addonDir)
        try fm.createDirectory(at: addonDir.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(atPath: bundlePath + "/s4me", toPath: addonDir.path)
        let settings = dataDir.appendingPathComponent("userdata/addon_data/plugin.video.s4me/settings.xml")
        if !fm.fileExists(atPath: settings.path) {
            try fm.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.copyItem(atPath: bundlePath + "/s4me_data/settings.xml", toPath: settings.path)
        }
        try version.write(to: stamp, atomically: true, encoding: .utf8)
    }

    private func call(_ name: String, _ args: [Any] = []) async throws -> String {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<String, Error>) in
            queue.async {
                do {
                    try self.ensureReadySync()
                    var err: NSString?
                    if let r = NXPython.call("nxbridge", function: name, args: args, error: &err) { c.resume(returning: r) }
                    else { c.resume(throwing: EngineError(description: (err as String?) ?? "\(name) failed")) }
                } catch { c.resume(throwing: error) }
            }
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ s: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(s.utf8))
    }

    func channels() async throws -> [EngineChannelInfo] { try decode([EngineChannelInfo].self, try await call("channels")) }

    func search(_ query: String, type: String, year: Int = 0, channels: [String] = [], timeoutSec: Int = 12) async throws -> SearchResponse {
        try decode(SearchResponse.self, try await call("search", [query, type, year, channels.joined(separator: ","), timeoutSec]))
    }

    func episodes(_ item: String) async throws -> [EpisodeHit] { try decode([EpisodeHit].self, try await call("episodes", [item])) }

    func play(_ item: String) async throws -> PlayResponse { try decode(PlayResponse.self, try await call("play", [item])) }

    /// Re-reads the addon tree after an update. Returns the number of channels found (0 = the new tree does not load).
    func reload() async throws -> Int {
        let r = try await call("reload")
        NxLog.i("NxEngine", "reload: \(r)")
        guard let o = try? JSONSerialization.jsonObject(with: Data(r.utf8)) as? [String: Any] else { return 0 }
        return (o["channels"] as? Int) ?? 0
    }

    func version() async -> String { (try? await call("version")) ?? "?" }

    /// Runs a helper of `nxtools.py` (zip download / extraction for the addon updater).
    func tool(_ name: String, _ args: [Any]) async throws -> String {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<String, Error>) in
            queue.async {
                do {
                    try self.ensureReadySync()
                    var err: NSString?
                    if let r = NXPython.call("nxtools", function: name, args: args, error: &err) { c.resume(returning: r) }
                    else { c.resume(throwing: EngineError(description: (err as String?) ?? "\(name) failed")) }
                } catch { c.resume(throwing: error) }
            }
        }
    }
}
