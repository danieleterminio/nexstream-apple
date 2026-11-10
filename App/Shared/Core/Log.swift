import Foundation

/// App log: console + a rolling file in Caches (`nx.log`) that the CI pulls out of the simulator after a run.
enum NxLog {
    private static let queue = DispatchQueue(label: "nx.log")
    private static let url: URL = Paths.caches.appendingPathComponent("nx.log")
    private static var handle: FileHandle? = {
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 2_000_000 { try? fm.removeItem(at: url) }
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        let h = try? FileHandle(forWritingTo: url)
        _ = try? h?.seekToEnd()
        return h
    }()
    private static let stamp: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()

    static func i(_ tag: String, _ msg: @autoclosure () -> String) { write("I", tag, msg()) }
    static func w(_ tag: String, _ msg: @autoclosure () -> String) { write("W", tag, msg()) }
    static func e(_ tag: String, _ msg: @autoclosure () -> String) { write("E", tag, msg()) }

    private static func write(_ level: String, _ tag: String, _ msg: String) {
        let now = Date()
        queue.async {
            let line = "\(stamp.string(from: now)) \(level)/\(tag): \(msg)\n"
            print(line, terminator: "")
            if let d = line.data(using: .utf8) { try? handle?.write(contentsOf: d) }
        }
    }
}

/// Where things live on disk.
///
/// tvOS gives an app no durable local storage: only `Caches` is writable and the system may empty it while the app is not
/// running. Everything that can be rebuilt (database, guide, addon, images) lives there; what must survive (line, profiles,
/// lists, progress) is also mirrored into the Keychain / UserDefaults by `Backup`.
enum Paths {
    static let caches: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    static let support: URL = {
        #if os(tvOS)
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("NexStream", isDirectory: true)
        #else
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NexStream", isDirectory: true)
        #endif
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()
    static let tmp: URL = FileManager.default.temporaryDirectory
}
