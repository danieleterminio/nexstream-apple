import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CommonCrypto)
import CommonCrypto
#endif

struct DownloadError: Error, CustomStringConvertible { let description: String }

/// Saves a stream to one local file. HLS (most Stream4Me sources) is fetched segment by segment and the segments are
/// written one after the other — MPEG-TS and fragmented MP4 both play that way; AES-128 segments are decrypted on the fly.
/// Plain files are downloaded as they are.
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

    /// Returns the file extension used ("ts" / "mp4"). `progress` gets 0…1 and the bytes written so far.
    static func download(url: String, headers: [String: String], kind: String, to dest: URL, cancelled: @escaping () -> Bool, progress: @escaping (Double, Int64) -> Void) async throws -> String {
        var h = headers
        if h["User-Agent"] == nil && h["user-agent"] == nil { h["User-Agent"] = "Mozilla/5.0 (Linux; Android 11; SHIELD Android TV) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36" }
        if kind == "hls" || url.contains(".m3u8") { return try await hls(url, h, dest, cancelled, progress) }
        if kind == "dash" { throw DownloadError(description: "Questa fonte non si può scaricare.") }
        try await file(url, h, dest, cancelled, progress)
        return "mp4"
    }

    private static func hls(_ url: String, _ headers: [String: String], _ dest: URL, _ cancelled: @escaping () -> Bool, _ progress: @escaping (Double, Int64) -> Void) async throws -> String {
        var playlistUrl = url
        var text = try await Http.text(playlistUrl, headers: headers)
        // master playlist: take the best variant
        if text.contains("#EXT-X-STREAM-INF") {
            var best: (Int, String)? = nil
            let lines = text.components(separatedBy: .newlines).map { $0.trimmed }
            for (i, l) in lines.enumerated() where l.hasPrefix("#EXT-X-STREAM-INF") {
                let bw = Int(attributes(l)["BANDWIDTH"] ?? "") ?? 0
                if let next = lines[(i + 1)...].first(where: { !$0.isEmpty && !$0.hasPrefix("#") }), best == nil || bw > best!.0 { best = (bw, next) }
            }
            guard let b = best else { throw DownloadError(description: "Playlist non valida.") }
            playlistUrl = resolve(b.1, playlistUrl)
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
        FileManager.default.createFile(atPath: dest.path, contents: nil)
        guard let out = try? FileHandle(forWritingTo: dest) else { throw DownloadError(description: "Non riesco a scrivere il file.") }
        defer { try? out.close() }
        var written: Int64 = 0
        if let i = initSegment { let d = try await Http.data(i, headers: headers); out.write(d); written += Int64(d.count) }
        for (n, s) in segments.enumerated() {
            if cancelled() { throw DownloadError(description: "Annullato") }
            var data: Data? = nil; var lastError: Error? = nil
            for attempt in 0..<4 {
                do { data = try await Http.data(s.0, headers: headers, timeout: 40); break }
                catch { lastError = error; try? await Task.sleep(nanoseconds: UInt64(600 * (attempt + 1)) * 1_000_000) }
            }
            guard var d = data else { throw lastError ?? DownloadError(description: "Segmento non scaricato.") }
            if let k = s.1, let v = s.2 { d = try decrypt(d, key: k, iv: v) }
            out.write(d)
            written += Int64(d.count)
            progress(Double(n + 1) / Double(segments.count), written)
        }
        return initSegment != nil ? "mp4" : "ts"
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

    private static func file(_ url: String, _ headers: [String: String], _ dest: URL, _ cancelled: @escaping () -> Bool, _ progress: @escaping (Double, Int64) -> Void) async throws {
        guard let u = URL(string: url) else { throw DownloadError(description: "Indirizzo non valido.") }
        var req = URLRequest(url: u, timeoutInterval: 60)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let task = Http.session.downloadTask(with: req) { tmp, resp, err in
                if let err = err { c.resume(throwing: err); return }
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard status >= 200 && status < 300, let tmp = tmp else { c.resume(throwing: HttpError(status: status, url: url)); return }
                do {
                    try? FileManager.default.removeItem(at: dest)
                    try FileManager.default.moveItem(at: tmp, to: dest)
                    c.resume()
                } catch { c.resume(throwing: error) }
            }
            task.resume()
            // progress and cancellation, polled
            DispatchQueue.global(qos: .utility).async {
                while task.state == .running || task.state == .suspended {
                    if cancelled() { task.cancel(); break }
                    let total = task.countOfBytesExpectedToReceive, got = task.countOfBytesReceived
                    if total > 0 { progress(Double(got) / Double(total), got) }
                    Thread.sleep(forTimeInterval: 1)
                }
            }
        }
    }
}

/// Offline downloads (iPhone): a queue that resolves a title through Stream4Me, saves it in the app's private storage,
/// and keeps the TMDB facts next to it so it plays with no network at all — VPN gate included.
final class Downloads {
    private let core: NexCore
    private let lock = NSLock()
    private var running: String? = nil
    private var cancelledIds = Set<String>()
    private var worker: Task<Void, Never>? = nil

    init(core: NexCore) { self.core = core }

    static func id(_ r: PlayRequest) -> String { "\(r.details.media)-\(r.details.id)-\(r.season)-\(r.episode)" }

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
    func fileURL(_ d: DownloadEntity) -> URL? { d.file.map { dir.appendingPathComponent($0) } }
    func all() -> [DownloadEntity] { core.db.downloads() }
    func get(_ id: String) -> DownloadEntity? { core.db.download(id) }
    func completed(_ r: PlayRequest) -> DownloadEntity? {
        guard let d = core.db.download(Downloads.id(r)), d.state == "done", let f = fileURL(d), FileManager.default.fileExists(atPath: f.path) else { return nil }
        return d
    }

    func enqueue(_ pid: Int64, _ r: PlayRequest) {
        let id = Downloads.id(r)
        if let d = core.db.download(id), d.state == "done" || d.state == "running" || d.state == "queued" { return }
        let det = r.details
        let sub: String? = det.isTv ? "S\(r.season) E\(r.episode)" + (r.episodeTitle.map { " · \($0)" } ?? "") : (det.year > 0 ? String(det.year) : nil)
        core.db.upsertDownload(DownloadEntity(id: id, profileId: pid, tmdbId: det.id, media: det.media, season: r.season, episode: r.episode, title: det.displayTitle, sub: sub,
                                              poster: det.posterPath, backdrop: det.backdropPath, state: "queued", progress: 0, bytes: 0, file: nil))
        if let json = try? JSONEncoder().encode(det) { try? json.write(to: dir.appendingPathComponent("\(id).json")) }
        lock.lock(); cancelledIds.remove(id); lock.unlock()
        wake()
    }

    func remove(_ id: String) {
        lock.lock(); cancelledIds.insert(id); lock.unlock()
        if let d = core.db.download(id), let f = fileURL(d) { try? FileManager.default.removeItem(at: f) }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(id).json"))
        core.db.deleteDownload(id)
    }

    /// The request that plays a finished download from the device.
    func playRequest(_ d: DownloadEntity, startMs: Millis = 0) -> PlayRequest? {
        guard let f = fileURL(d), FileManager.default.fileExists(atPath: f.path),
              let json = try? Data(contentsOf: dir.appendingPathComponent("\(d.id).json")), var det = try? JSONDecoder().decode(TmdbDetails.self, from: json) else { return nil }
        det.mediaType = d.media
        let ep = d.sub.flatMap { $0.contains(" · ") ? $0.substringAfter(" · ") : nil }
        return PlayRequest(details: det, season: d.season, episode: d.episode, episodeTitle: ep, startMs: startMs, localFile: f.path)
    }

    /// Starts (or resumes after a restart) the queue: one download at a time.
    func wake() {
        lock.lock()
        if worker != nil { lock.unlock(); return }
        worker = Task { [weak self] in await self?.run() }
        lock.unlock()
    }

    private func isCancelled(_ id: String) -> Bool { lock.lock(); defer { lock.unlock() }; return cancelledIds.contains(id) }

    private func run() async {
        // a download cut short by the app closing starts over
        for d in core.db.downloads() where d.state == "running" { var x = d; x.state = "queued"; x.progress = 0; core.db.upsertDownload(x) }
        while let next = core.db.downloads().reversed().first(where: { $0.state == "queued" }) {
            await one(next)
        }
        lock.lock(); worker = nil; lock.unlock()
    }

    private func one(_ d: DownloadEntity) async {
        var row = d
        func fail(_ m: String) { row.state = "failed"; row.error = m; core.db.upsertDownload(row) }
        guard let json = try? Data(contentsOf: dir.appendingPathComponent("\(d.id).json")), var det = try? JSONDecoder().decode(TmdbDetails.self, from: json) else { fail("Dati del titolo mancanti."); return }
        det.mediaType = d.media
        row.state = "running"; row.error = nil
        core.db.upsertDownload(row)
        let req = PlayRequest(details: det, season: d.season, episode: d.episode)
        guard let stream = await core.resolver.resolve(req) else { fail("Nessuna fonte disponibile adesso."); return }
        let tmp = dir.appendingPathComponent("\(d.id).part")
        var lastSave = Clock.now
        let id = d.id
        do {
            let ext = try await StreamDownloader.download(url: stream.url, headers: stream.headers, kind: stream.kind, to: tmp, cancelled: { [weak self] in self?.isCancelled(id) ?? true }) { [weak self] p, bytes in
                guard let self = self, Clock.now - lastSave > 1200 else { return }
                lastSave = Clock.now
                row.progress = p; row.bytes = bytes
                if self.core.db.download(id) != nil { self.core.db.upsertDownload(row) }
            }
            if isCancelled(id) { try? FileManager.default.removeItem(at: tmp); return }
            let name = "\(d.id).\(ext)"
            let final = dir.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: final)
            try FileManager.default.moveItem(at: tmp, to: final)
            row.state = "done"; row.progress = 1; row.file = name
            row.bytes = ((try? FileManager.default.attributesOfItem(atPath: final.path))?[.size] as? Int64) ?? row.bytes
            core.db.upsertDownload(row)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            if isCancelled(id) { return }
            fail((error as? DownloadError)?.description ?? "Download interrotto: controlla la connessione.")
        }
    }
}
