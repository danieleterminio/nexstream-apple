import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CommonCrypto)
import CommonCrypto
#endif

struct DownloadError: Error, CustomStringConvertible { let description: String }
/// Thrown when a download has to stop where it is (paused, VPN off, Wi-Fi gone, removed): what is saved stays.
struct DownloadStop: Error {}

/// Where a download stands, saved next to it: after a restart it goes on from the last finished segment (HLS) or from
/// the last byte saved (plain files, HTTP Range) instead of starting from zero.
struct DownloadInfo: Codable, Equatable {
    var quality: String = ""
    /// The media playlist / file being saved.
    var url: String? = nil
    var segDone: Int = 0
    var segTotal: Int = 0
    var bytes: Int64 = 0
    var ext: String? = nil
    /// The Stream4Me source it comes from.
    var channel: String? = nil
}

/// One download as the downloader sees it: what to save, how to report, when to stop.
final class DownloadJob {
    let id: String
    /// 0 Risparmio (480p) · 1 Standard (720p) · 2 Alta (1080p).
    let quality: Int
    /// Mobile data allowed.
    let cellular: Bool
    var info: DownloadInfo
    /// Throws `DownloadStop` when the download must stop.
    let check: () throws -> Void
    let save: (DownloadInfo) -> Void
    /// 0…1 and the bytes saved so far.
    let progress: (Double, Int64) -> Void
    init(id: String, quality: Int, cellular: Bool, info: DownloadInfo, check: @escaping () throws -> Void, save: @escaping (DownloadInfo) -> Void, progress: @escaping (Double, Int64) -> Void) {
        self.id = id; self.quality = quality; self.cellular = cellular; self.info = info; self.check = check; self.save = save; self.progress = progress
    }
}

/// Saves a stream to one local file. HLS (most Stream4Me sources) is fetched segment by segment and the segments are
/// written one after the other — MPEG-TS and fragmented MP4 both play that way; AES-128 segments are decrypted on the fly.
/// The variant is the one the "Qualità" setting asks for. Plain files go through `FileStreamer` (in this process too).
enum StreamDownloader {
    private static let attr = Rx(#"([A-Z0-9-]+)=("[^"]*"|[^,]*)"#)

    private static func attributes(_ line: String) -> [String: String] {
        var out = [String: String]()
        for m in attr.findAll(line.substringAfter(":")) { out[m[1]] = m[2].trimming("\"") }
        return out
    }
    private static func resolve(_ ref: String, _ base: String) -> String {
        if ref.hasPrefix("http://") || ref.hasPrefix("https://") { return ref }
        guard let b = URL(string: base), let u = URL(string: ref, relativeTo: b) else { return ref }
        return u.absoluteString
    }

    static let browserUA = "Mozilla/5.0 (Linux; Android 11; SHIELD Android TV) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    /// Returns the file extension used ("ts" / "mp4" / the file's own).
    static func download(url: String, headers: [String: String], kind: String, to dest: URL, job: DownloadJob) async throws -> String {
        var h = headers
        if h["User-Agent"] == nil && h["user-agent"] == nil { h["User-Agent"] = browserUA }
        if kind == "hls" || url.contains(".m3u8") { return try await hls(url, h, dest, job) }
        if kind == "dash" { throw DownloadError(description: "Questa fonte non si può scaricare.") }
        return try await file(url, h, dest, job)
    }

    /// The variant for a quality: the best one at or under the height limit, else the smallest; with no RESOLUTION in the
    /// playlist, by bandwidth (~1.4 / 3.2 Mbit/s).
    static func pickVariant(_ variants: [(bandwidth: Int, height: Int, uri: String)], quality: Int) -> String? {
        if variants.isEmpty { return nil }
        let maxH = [480, 720, 1080][max(0, min(2, quality))]
        let sized = variants.filter { $0.height > 0 }
        if !sized.isEmpty {
            let fit = sized.filter { $0.height <= maxH }
            if let b = fit.max(by: { ($0.height, $0.bandwidth) < ($1.height, $1.bandwidth) }) { return b.uri }
            return sized.min(by: { ($0.height, $0.bandwidth) < ($1.height, $1.bandwidth) })?.uri
        }
        let cap = maxH <= 480 ? 1_400_000 : (maxH <= 720 ? 3_200_000 : Int.max)
        let fit = variants.filter { $0.bandwidth <= cap }
        return (fit.max { $0.bandwidth < $1.bandwidth } ?? variants.min { $0.bandwidth < $1.bandwidth })?.uri
    }

    private static func hls(_ url: String, _ headers: [String: String], _ dest: URL, _ job: DownloadJob) async throws -> String {
        var playlistUrl = url
        var text = try await Http.text(playlistUrl, headers: headers)
        // master playlist: the variant of the chosen quality
        if text.contains("#EXT-X-STREAM-INF") {
            var variants = [(bandwidth: Int, height: Int, uri: String)]()
            let lines = text.components(separatedBy: .newlines).map { $0.trimmed }
            for (i, l) in lines.enumerated() where l.hasPrefix("#EXT-X-STREAM-INF") {
                let a = attributes(l)
                let bw = Int(a["BANDWIDTH"] ?? "") ?? 0
                let h = Int((a["RESOLUTION"] ?? "").substringAfter("x")) ?? 0
                if let next = lines[(i + 1)...].first(where: { !$0.isEmpty && !$0.hasPrefix("#") }) { variants.append((bw, h, next)) }
            }
            guard let pick = pickVariant(variants, quality: job.quality) else { throw DownloadError(description: "Playlist non valida.") }
            playlistUrl = resolve(pick, playlistUrl)
            text = try await Http.text(playlistUrl, headers: headers)
        }
        var segments = [(String, Data?, Data?)]()      // url, key, iv
        var initSegment: String? = nil
        var key: Data? = nil, iv: Data? = nil
        var sequence = 0
        for raw in text.components(separatedBy: .newlines) {
            let l = raw.trimmed
            if l.isEmpty { continue }
            if l.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") { sequence = Int(l.substringAfter(":")) ?? 0 }
            else if l.hasPrefix("#EXT-X-MAP:") { initSegment = attributes(l)["URI"].map { resolve($0, playlistUrl) } }
            else if l.hasPrefix("#EXT-X-KEY:") {
                let a = attributes(l)
                let method = a["METHOD"] ?? "NONE"
                if method == "NONE" { key = nil; iv = nil }
                else if method == "AES-128", let uri = a["URI"] {
                    key = try await Http.data(resolve(uri, playlistUrl), headers: headers)
                    iv = a["IV"].flatMap { hexData($0) }
                } else { throw DownloadError(description: "Questa fonte è protetta e non si può scaricare.") }
            } else if !l.hasPrefix("#") {
                var segIv = iv
                if key != nil && segIv == nil {
                    // no IV given: the media sequence number, big-endian, in 16 bytes
                    var bytes = [UInt8](repeating: 0, count: 16)
                    var n = sequence + segments.count
                    for i in stride(from: 15, through: 12, by: -1) { bytes[i] = UInt8(n & 0xFF); n >>= 8 }
                    segIv = Data(bytes)
                }
                segments.append((resolve(l, playlistUrl), key, segIv))
            }
        }
        if segments.isEmpty { throw DownloadError(description: "Nessun segmento da scaricare.") }
        if !text.contains("#EXT-X-ENDLIST") { throw DownloadError(description: "È una diretta: non si può scaricare.") }
        let ext = initSegment != nil ? "mp4" : "ts"
        let fm = FileManager.default
        // the same playlist as before (same number of segments) and the part file is all there: go on from where it was
        let have = ((try? fm.attributesOfItem(atPath: dest.path))?[.size] as? NSNumber)?.int64Value ?? -1
        var first = 0
        var written: Int64 = 0
        if job.info.segDone > 0 && job.info.segDone < segments.count && job.info.segTotal == segments.count && job.info.ext == ext && job.info.bytes > 0 && have >= job.info.bytes {
            first = job.info.segDone
            written = job.info.bytes
            NxLog.i("NxDownloads", "\(job.id): resuming at segment \(first) of \(segments.count)")
        } else {
            fm.createFile(atPath: dest.path, contents: nil)
            job.info.segDone = 0
            job.info.bytes = 0
        }
        guard let out = try? FileHandle(forWritingTo: dest) else { throw DownloadError(description: "Non riesco a scrivere il file.") }
        defer { try? out.close() }
        if first > 0 { try out.truncate(atOffset: UInt64(written)); _ = try out.seekToEnd() }
        job.info.url = playlistUrl
        job.info.segTotal = segments.count
        job.info.ext = ext
        if first == 0, let i = initSegment {
            let d = try await Http.data(i, headers: headers)
            out.write(d); written += Int64(d.count)
            job.info.bytes = written
        }
        job.save(job.info)
        for n in first..<segments.count {
            try job.check()
            let s = segments[n]
            var data: Data? = nil; var lastError: Error? = nil
            for attempt in 0..<4 {
                try job.check()
                do { data = try await Http.data(s.0, headers: headers, timeout: 40); break }
                catch {
                    if error is VpnRequiredError { throw error }
                    lastError = error
                    try? await Task.sleep(nanoseconds: UInt64(600 * (attempt + 1)) * 1_000_000)
                }
            }
            guard var d = data else { throw lastError ?? DownloadError(description: "Segmento non scaricato.") }
            if let k = s.1, let v = s.2 { d = try decrypt(d, key: k, iv: v) }
            out.write(d)
            written += Int64(d.count)
            job.info.segDone = n + 1
            job.info.bytes = written
            job.save(job.info)
            job.progress(Double(n + 1) / Double(segments.count), written)
        }
        return ext
    }

    private static func hexData(_ s: String) -> Data? {
        var hex = s.lowercased()
        if hex.hasPrefix("0x") { hex = String(hex.dropFirst(2)) }
        if hex.count % 2 != 0 { return nil }
        var out = Data(); var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let b = UInt8(hex[i..<j], radix: 16) else { return nil }
            out.append(b); i = j
        }
        return out
    }

    private static func decrypt(_ data: Data, key: Data, iv: Data) throws -> Data {
        #if canImport(CommonCrypto)
        var out = Data(count: data.count + kCCBlockSizeAES128)
        var moved = 0
        let outCount = out.count
        let status = out.withUnsafeMutableBytes { o in
            data.withUnsafeBytes { d in
                key.withUnsafeBytes { k in
                    iv.withUnsafeBytes { v in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding), k.baseAddress, key.count, v.baseAddress, d.baseAddress, data.count, o.baseAddress, outCount, &moved)
                    }
                }
            }
        }
        if status != kCCSuccess { throw DownloadError(description: "Segmento non leggibile.") }
        out.count = moved
        return out
        #else
        throw DownloadError(description: "Fonte cifrata non supportata.")
        #endif
    }

    private static func file(_ url: String, _ headers: [String: String], _ dest: URL, _ job: DownloadJob) async throws -> String {
        guard let u = URL(string: url) ?? URL(string: url.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? "") else { throw DownloadError(description: "Indirizzo non valido.") }
        let known = ["mp4", "m4v", "mov", "mkv", "avi", "webm", "ts"]
        let ext = known.contains(u.pathExtension.lowercased()) ? u.pathExtension.lowercased() : "mp4"
        // the same file as before and its part is all there: go on from where it stopped (HTTP Range)
        let fm = FileManager.default
        let have = ((try? fm.attributesOfItem(atPath: dest.path))?[.size] as? NSNumber)?.int64Value ?? -1
        var from: Int64 = 0
        if job.info.url == url && job.info.ext == ext && job.info.segTotal == 0 && job.info.bytes > 0 && have >= job.info.bytes {
            from = job.info.bytes
            NxLog.i("NxDownloads", "\(job.id): resuming the file at \(Downloads.size(from))")
        } else {
            fm.createFile(atPath: dest.path, contents: nil)
            job.info.bytes = 0
        }
        job.info.url = url
        job.info.ext = ext
        job.info.segDone = 0; job.info.segTotal = 0
        job.save(job.info)
        var lastSave = Clock.now
        try await FileStreamer.shared.run(url: u, headers: headers, cellular: job.cellular, dest: dest, from: from, check: job.check) { got, total in
            job.info.bytes = got
            if Clock.now - lastSave > 2000 { lastSave = Clock.now; job.save(job.info) }
            job.progress(total > 0 ? Double(got) / Double(total) : 0, got)
        }
        job.save(job.info)
        try job.check()
        return ext
    }
}

/// Plain files, read in this process like the HLS segments: every block that arrives passes the same check (VPN on,
/// room left, Wi-Fi when asked for) before it is written, and the transfer is cut as soon as the check fails. Nothing is
/// handed to the system's background transfer service, which would carry on without the VPN while the app is suspended.
/// A stopped file keeps what it saved and goes on with an HTTP Range request (also after a restart).
final class FileStreamer: NSObject, URLSessionDataDelegate {
    static let shared = FileStreamer()
    /// The background session of the older versions: its leftover transfers are cancelled once at start.
    static let legacySessionId = "app.nexstream.one.downloads"

    private final class Transfer {
        let out: FileHandle
        var got: Int64
        var total: Int64 = 0
        let from: Int64
        let check: () throws -> Void
        let progress: (Int64, Int64) -> Void
        var failure: Error? = nil
        var done: ((Error?) -> Void)?
        init(out: FileHandle, from: Int64, check: @escaping () throws -> Void, progress: @escaping (Int64, Int64) -> Void, done: @escaping (Error?) -> Void) {
            self.out = out; self.got = from; self.from = from; self.check = check; self.progress = progress; self.done = done
        }
    }

    private let lock = NSLock()
    private var transfers = [Int: Transfer]()
    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 60
        c.timeoutIntervalForResource = 7 * 86_400
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        return URLSession(configuration: c, delegate: self, delegateQueue: q)
    }()

    /// Cancels whatever the background session of an older version still had going. Once per launch.
    static func cancelLegacyTransfers() {
        #if os(iOS)
        let s = URLSession(configuration: URLSessionConfiguration.background(withIdentifier: legacySessionId))
        s.getAllTasks { tasks in
            if !tasks.isEmpty { NxLog.i("NxDownloads", "cancelled \(tasks.count) leftover background transfers") }
            for t in tasks { t.cancel() }
            s.invalidateAndCancel()
        }
        #endif
    }

    /// Writes `url` into `dest` from byte `from` on; returns when it is all there. Throws `DownloadStop` when `check` says so.
    func run(url: URL, headers: [String: String], cellular: Bool, dest: URL, from: Int64, check: @escaping () throws -> Void, progress: @escaping (Int64, Int64) -> Void) async throws {
        try check()
        if !Vpn.shared.active.value { throw VpnRequiredError() }
        guard let out = try? FileHandle(forWritingTo: dest) else { throw DownloadError(description: "Non riesco a scrivere il file.") }
        try out.truncate(atOffset: UInt64(from))
        _ = try out.seekToEnd()
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.allowsCellularAccess = cellular
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if from > 0 { req.setValue("bytes=\(from)-", forHTTPHeaderField: "Range") }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let task = session.dataTask(with: req)
            let t = Transfer(out: out, from: from, check: check, progress: progress) { e in
                try? out.close()
                if let e = e { c.resume(throwing: e) } else { c.resume() }
            }
            lock.lock(); transfers[task.taskIdentifier] = t; lock.unlock()
            task.resume()
        }
    }

    /// Cuts at once the transfers whose check now fails (paused, removed, VPN off), even if no block is arriving.
    func recheck() {
        session.getAllTasks { [weak self] tasks in
            guard let self = self else { return }
            for task in tasks {
                guard let t = self.transfer(task), t.failure == nil else { continue }
                do { try t.check(); if !Vpn.shared.active.value { throw VpnRequiredError() } } catch { t.failure = error; task.cancel() }
            }
        }
    }

    private func transfer(_ task: URLSessionTask) -> Transfer? { lock.lock(); defer { lock.unlock() }; return transfers[task.taskIdentifier] }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let t = transfer(dataTask) else { completionHandler(.cancel); return }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 200 && t.from > 0 {
            // the server ignores ranges: the whole file again
            do { try t.out.truncate(atOffset: 0); _ = try t.out.seekToEnd() } catch { t.failure = error; completionHandler(.cancel); return }
            t.got = 0
        } else if status != 200 && status != 206 {
            t.failure = HttpError(status: status, url: dataTask.originalRequest?.url?.absoluteString ?? "")
            completionHandler(.cancel)
            return
        }
        let len = response.expectedContentLength
        t.total = len > 0 ? t.got + len : 0
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let t = transfer(dataTask), t.failure == nil else { return }
        // every block passes the check before it is kept: VPN off (or anything else) cuts the transfer here
        do { try t.check() } catch { t.failure = error; dataTask.cancel(); return }
        if !Vpn.shared.active.value { t.failure = VpnRequiredError(); dataTask.cancel(); return }
        t.out.write(data)
        t.got += Int64(data.count)
        t.progress(t.got, t.total)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let t = transfers.removeValue(forKey: task.taskIdentifier); lock.unlock()
        guard let t = t else { return }
        let result: Error? = t.failure ?? error
        if result == nil && t.total > 0 && t.got < t.total { t.done?(DownloadError(description: "File incompleto.")) }
        else { t.done?(result) }
        t.done = nil
    }
}

/// Offline downloads (iPhone): a queue that resolves a title through Stream4Me, saves it in the app's private storage,
/// and keeps the TMDB facts next to it so it plays with no network at all — VPN gate included. Two at a time; they wait
/// (and go on by themselves) while the VPN is off, the storage is low, or — with "Solo Wi-Fi" — the phone is on mobile data.
final class Downloads {
    enum Block: String { case vpn, storage, wifi, network }
    private enum Stop { case user, removed, system }
    static let qualities = ["Risparmio", "Standard", "Alta"]
    static let maxParallel = 2
    /// Below this the downloads wait for room.
    static let minFree: Int64 = 400_000_000

    private let core: NexCore
    private let lock = NSLock()
    private var running = [String: Task<Void, Never>]()
    private var stops = [String: Stop]()
    private var recovered = false
    private var watches = [Watch]()
    private var timer: DispatchSourceTimer? = nil
    private let defaults = UserDefaults.standard

    /// Why the downloads are not moving (nil when nothing waits or nothing stops them).
    let blocked = Observable<Block?>(nil)
    /// A download finished (the UI layer sends the notification).
    var onFinished: ((DownloadEntity) -> Void)? = nil
    /// Something is being downloaded / nothing any more: the UI layer asks the system for time in the background.
    var onActivity: ((Bool) -> Void)? = nil

    init(core: NexCore) {
        self.core = core
        NetMonitor.shared.start()
        FileStreamer.cancelLegacyTransfers()
        watches.append(Vpn.shared.active.observe(fire: false) { [weak self] _ in self?.pump() })
        watches.append(NetMonitor.shared.expensive.observe(fire: false) { [weak self] _ in self?.pump() })
        watches.append(NetMonitor.shared.online.observe(fire: false) { [weak self] _ in self?.pump() })
        // the storage has no event: looked at every 20 s, which also restarts what a passing failure left waiting
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        t.schedule(deadline: .now() + 20, repeating: 20)
        t.setEventHandler { [weak self] in self?.pump() }
        t.resume()
        timer = t
    }

    static func id(_ r: PlayRequest) -> String { "\(r.details.media)-\(r.details.id)-\(r.season)-\(r.episode)" }

    // MARK: settings

    /// "Solo Wi-Fi" (default) or mobile data too.
    var wifiOnly: Bool {
        get { defaults.object(forKey: "dl.wifiOnly") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "dl.wifiOnly"); pump() }
    }
    /// 0 Risparmio (480p) · 1 Standard (720p) · 2 Alta (1080p): the variant taken from HLS sources.
    var quality: Int {
        get { defaults.object(forKey: "dl.quality") as? Int ?? 1 }
        set { defaults.set(max(0, min(2, newValue)), forKey: "dl.quality") }
    }

    // MARK: files

    var dir: URL {
        let d = Paths.support.appendingPathComponent("downloads", isDirectory: true)
        if !FileManager.default.fileExists(atPath: d.path) {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            var u = d
            var rv = URLResourceValues(); rv.isExcludedFromBackup = true
            try? u.setResourceValues(rv)
        }
        return d
    }
    private func partURL(_ id: String) -> URL { dir.appendingPathComponent("\(id).part") }
    private func infoURL(_ id: String) -> URL { dir.appendingPathComponent("\(id).info") }
    private func jsonURL(_ id: String) -> URL { dir.appendingPathComponent("\(id).json") }
    func fileURL(_ d: DownloadEntity) -> URL? { d.file.map { dir.appendingPathComponent($0) } }
    func all() -> [DownloadEntity] { core.db.downloads() }
    func get(_ id: String) -> DownloadEntity? { core.db.download(id) }
    func info(_ id: String) -> DownloadInfo? { (try? Data(contentsOf: infoURL(id))).flatMap { try? JSONDecoder().decode(DownloadInfo.self, from: $0) } }
    private func saveInfo(_ id: String, _ i: DownloadInfo) { if let d = try? JSONEncoder().encode(i) { try? d.write(to: infoURL(id)) } }

    func completed(_ r: PlayRequest) -> DownloadEntity? {
        guard let d = core.db.download(Downloads.id(r)), d.state == "done", let f = fileURL(d), FileManager.default.fileExists(atPath: f.path) else { return nil }
        return d
    }

    /// Room taken by the downloads and room still free on the device.
    func space() -> (used: Int64, free: Int64) {
        var used: Int64 = 0
        if let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
            for n in names {
                let p = dir.appendingPathComponent(n).path
                used += ((try? FileManager.default.attributesOfItem(atPath: p))?[.size] as? NSNumber)?.int64Value ?? 0
            }
        }
        return (used, freeSpace())
    }
    func freeSpace() -> Int64 {
        #if os(iOS) || os(macOS)
        if let v = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage, v > 0 { return v }
        #endif
        if let a = try? FileManager.default.attributesOfFileSystem(forPath: dir.path), let n = a[.systemFreeSize] as? NSNumber { return n.int64Value }
        return Int64.max
    }

    static func size(_ b: Int64) -> String {
        if b >= 1_000_000_000 { return String(format: "%.1f GB", Double(b) / 1e9).replacingOccurrences(of: ".", with: ",") }
        if b >= 1_000_000 { return String(format: "%.0f MB", Double(b) / 1e6) }
        return String(format: "%.0f kB", Double(b) / 1e3)
    }

    // MARK: what the screens do

    func enqueue(_ pid: Int64, _ r: PlayRequest) {
        let id = Downloads.id(r)
        if let d = core.db.download(id) {
            if d.state == "done" || d.state == "running" || d.state == "queued" { return }
            resume(id)
            return
        }
        let det = r.details
        let sub: String? = det.isTv ? "S\(r.season) E\(r.episode)" + (r.episodeTitle.map { " · \($0)" } ?? "") : (det.year > 0 ? String(det.year) : nil)
        if let json = try? JSONEncoder().encode(det) { try? json.write(to: jsonURL(id)) }
        saveInfo(id, DownloadInfo(quality: Downloads.qualities[quality]))
        core.db.upsertDownload(DownloadEntity(id: id, profileId: pid, tmdbId: det.id, media: det.media, season: r.season, episode: r.episode, title: det.displayTitle, sub: sub,
                                              poster: det.posterPath, backdrop: det.backdropPath, state: "queued", progress: 0, bytes: 0, file: nil))
        pump()
    }

    /// "Metti in pausa": stops where it is; nothing restarts it but "Riprendi".
    func pause(_ id: String) {
        if isRunning(id) { stop(id, .user) }
        else if var d = core.db.download(id), d.state == "queued" { d.state = "paused"; core.db.upsertDownload(d) }
    }
    /// "Riprendi" / "Riprova il download": back in the queue, from what was already saved.
    func resume(_ id: String) {
        guard var d = core.db.download(id), d.state != "done", d.state != "running" else { return }
        d.state = "queued"; d.error = nil
        core.db.upsertDownload(d)
        pump()
    }
    func retry(_ id: String) { resume(id) }

    func remove(_ id: String) {
        stop(id, .removed)
        let row = core.db.download(id)
        core.db.deleteDownload(id)
        let fm = FileManager.default
        if let d = row, let f = fileURL(d) { try? fm.removeItem(at: f) }
        for u in [partURL(id), infoURL(id), jsonURL(id), dir.appendingPathComponent("\(id).resume")] { try? fm.removeItem(at: u) }
    }
    func removeAll() {
        for d in core.db.downloads() { remove(d.id) }
        // leftovers of anything the table no longer knows
        if let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
            for n in names { try? FileManager.default.removeItem(at: dir.appendingPathComponent(n)) }
        }
    }

    /// The request that plays a finished download from the device.
    func playRequest(_ d: DownloadEntity, startMs: Millis = 0) -> PlayRequest? {
        guard let f = fileURL(d), FileManager.default.fileExists(atPath: f.path),
              let json = try? Data(contentsOf: jsonURL(d.id)), var det = try? JSONDecoder().decode(TmdbDetails.self, from: json) else { return nil }
        det.mediaType = d.media
        let ep = d.sub.flatMap { $0.contains(" · ") ? $0.substringAfter(" · ") : nil }
        return PlayRequest(details: det, season: d.season, episode: d.episode, episodeTitle: ep, startMs: startMs, localFile: f.path)
    }

    /// Starts (or resumes after a restart) the queue.
    func wake() { pump() }

    // MARK: the queue

    /// What keeps the downloads from moving right now.
    func blockReason() -> Block? {
        if !Vpn.shared.active.value { return .vpn }
        if !NetMonitor.shared.online.value { return .network }
        if freeSpace() < Downloads.minFree { return .storage }
        if wifiOnly && NetMonitor.shared.expensive.value { return .wifi }
        return nil
    }

    private func isRunning(_ id: String) -> Bool { lock.lock(); defer { lock.unlock() }; return running[id] != nil }
    private func stopFor(_ id: String) -> Stop? { lock.lock(); defer { lock.unlock() }; return stops[id] }

    private func stop(_ id: String, _ why: Stop) {
        lock.lock()
        let on = running[id] != nil
        if on && stops[id] != .removed { stops[id] = why }
        lock.unlock()
        if on { FileStreamer.shared.recheck() }
    }

    /// Looks at the queue: stops everything while something keeps it from moving, else starts what waits (two at a time).
    func pump() {
        let rows = core.db.downloads()
        let reason = blockReason()
        let waiting = rows.contains { $0.state == "queued" || $0.state == "running" }
        let shown: Block? = waiting ? reason : nil
        if blocked.value != shown { blocked.value = shown }
        lock.lock()
        let firstRun = !recovered
        recovered = true
        let active = Set(running.keys)
        lock.unlock()
        // a download cut short by the app closing waits in the queue again, with what it had saved
        if firstRun { for r in rows where r.state == "running" && !active.contains(r.id) { var x = r; x.state = "queued"; core.db.upsertDownload(x) } }
        if let r = reason {
            for id in active { stop(id, .system) }
            FileStreamer.shared.recheck()
            onActivity?(false)
            return
        }
        // oldest first
        let queued = core.db.downloads().reversed().filter { $0.state == "queued" }
        lock.lock()
        var started = [String]()
        for r in queued where running[r.id] == nil && running.count < Downloads.maxParallel {
            let id = r.id
            stops[id] = nil
            running[id] = Task { [weak self] in
                await self?.one(id)
                self?.finished(id)
            }
            started.append(id)
        }
        let busy = !running.isEmpty
        lock.unlock()
        if !started.isEmpty { NxLog.i("NxDownloads", "started \(started)") }
        onActivity?(busy)
    }

    private func finished(_ id: String) {
        lock.lock()
        running[id] = nil
        stops[id] = nil
        lock.unlock()
        pump()
    }

    private func check(_ id: String) throws {
        if stopFor(id) != nil { throw DownloadStop() }
        if blockReason() != nil { throw DownloadStop() }
    }

    private func one(_ id: String) async {
        guard var row = core.db.download(id) else { return }
        func save() { if core.db.download(id) != nil { core.db.upsertDownload(row) } }
        func fail(_ m: String) { row.state = "failed"; row.error = m; save(); NxLog.w("NxDownloads", "\(id) failed: \(m)") }
        func settle() {
            switch stopFor(id) {
            case .user?: row.state = "paused"; save()
            case .removed?: break
            default: row.state = "queued"; save()
            }
        }
        // without the VPN (or with the queue held for any other reason) nothing is touched: no search, no data, no segments
        if blockReason() != nil { settle(); return }
        var det: TmdbDetails
        if let json = try? Data(contentsOf: jsonURL(id)), let d = try? JSONDecoder().decode(TmdbDetails.self, from: json) { det = d }
        else if let d = try? await core.catalog.details(row.media, row.tmdbId) {
            // the title's facts were not saved with it (an older version, a copy from another device): fetched again
            det = d
            if let j = try? JSONEncoder().encode(d) { try? j.write(to: jsonURL(id)) }
        } else {
            if stopFor(id) != nil || blockReason() != nil { settle(); return }
            fail("Dati del titolo mancanti: riprova quando c'è la rete.")
            return
        }
        det.mediaType = row.media
        row.state = "running"; row.error = nil
        save()
        var info = self.info(id) ?? DownloadInfo()
        if info.quality.isEmpty { info.quality = Downloads.qualities[quality] }
        let q = Downloads.qualities.firstIndex(of: info.quality) ?? quality
        let req = PlayRequest(details: det, season: row.season, episode: row.episode)
        // up to three sources: one the downloader cannot read is left out and the next one is tried; one whose link died
        // half way (expired token, the add-on's local proxy restarted) is found again and goes on from where it was
        var excluded = Set<String>()
        var lastError: Error? = nil
        var lastSave = Clock.now
        for _ in 0..<5 where excluded.count < 3 {
            if stopFor(id) != nil || blockReason() != nil { settle(); return }
            guard let stream = await core.resolver.resolve(req, exclude: excluded) else {
                if stopFor(id) != nil || blockReason() != nil { settle(); return }
                fail(excluded.isEmpty ? "Nessuna fonte disponibile adesso." : "Nessuna fonte scaricabile per questo titolo.")
                return
            }
            if stopFor(id) != nil || blockReason() != nil { settle(); return }
            if let ch = info.channel, ch != stream.channel { info.segDone = 0; info.segTotal = 0; info.bytes = 0; info.url = nil }
            info.channel = stream.channel
            let before = info.segDone, beforeBytes = info.bytes
            NxLog.i("NxDownloads", "\(id) from \(stream.channel) (\(stream.kind), \(info.quality))")
            let job = DownloadJob(id: id, quality: q, cellular: !wifiOnly, info: info, check: { [weak self] in try self?.check(id) },
                                  save: { [weak self] i in self?.saveInfo(id, i) }) { p, bytes in
                if Clock.now - lastSave < 1200 { return }
                lastSave = Clock.now
                row.progress = p; row.bytes = bytes
                save()
            }
            do {
                let ext = try await StreamDownloader.download(url: stream.url, headers: stream.headers, kind: stream.kind, to: partURL(id), job: job)
                info = job.info
                if stopFor(id) == .removed { return }
                finish(row, ext: ext, info: info)
                return
            } catch {
                info = job.info
                saveInfo(id, info)
                if stopFor(id) != nil || error is DownloadStop || error is VpnRequiredError || blockReason() != nil { settle(); return }
                NxLog.w("NxDownloads", "\(id) on \(stream.channel): \(error)")
                lastError = error
                // nothing saved from this source: it cannot be downloaded
                if info.segDone <= before && info.bytes <= beforeBytes { excluded.insert(stream.channel) }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
        fail((lastError as? DownloadError)?.description ?? "Download interrotto: riprova.")
    }

    private func finish(_ done: DownloadEntity, ext: String, info: DownloadInfo) {
        var row = done
        let id = row.id
        let name = "\(id).\(ext)"
        let final = dir.appendingPathComponent(name)
        let fm = FileManager.default
        try? fm.removeItem(at: final)
        do { try fm.moveItem(at: partURL(id), to: final) }
        catch { row.state = "failed"; row.error = "Non riesco a salvare il file."; core.db.upsertDownload(row); return }
        row.state = "done"; row.progress = 1; row.file = name; row.error = nil
        row.bytes = ((try? fm.attributesOfItem(atPath: final.path))?[.size] as? NSNumber)?.int64Value ?? row.bytes
        var i = info; i.segDone = 0; i.segTotal = 0; i.url = nil
        saveInfo(id, i)
        try? fm.removeItem(at: dir.appendingPathComponent("\(id).resume"))
        if core.db.download(id) == nil { return }
        core.db.upsertDownload(row)
        NxLog.i("NxDownloads", "\(id) done (\(Downloads.size(row.bytes)))")
        onFinished?(row)
    }
}
