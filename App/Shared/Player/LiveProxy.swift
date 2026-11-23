import Foundation
import Network

/// Lets the system player show a live channel. The line serves channels as one endless MPEG-TS download, which the
/// system player cannot open; this reads that download, cuts it into HLS segments in memory and serves them from a
/// tiny HTTP server inside the app. With it come AirPlay, picture in picture and the system's own controls.
/// One instance per tuned channel: `start`, wait for `onReady`, `stop`.
///
/// Never-stall rules (the Android player plays the same download directly and almost never freezes):
/// - when the line's download stops (closed, error, or silent for a few seconds) it is opened again here, silently:
///   the player keeps its playlist and its buffer, the new data continues the same playlist after a discontinuity;
/// - the playlist is long (`HlsWindow`), so a player that fell behind after a stall still finds its next segment;
/// - the server keeps connections alive and answers at once from memory, it never waits for the line.
final class LiveProxy: NSObject, URLSessionDataDelegate {
    /// The playlist can be opened (two segments are in memory).
    var onReady: ((URL) -> Void)?
    /// The stream uses codecs the system player cannot decode: use the other engine.
    var onUnsupported: ((String) -> Void)?
    /// The proxy gave up on the line. `true` = before anything could be played (wrong address, refused, no network);
    /// `false` = it played, then the line stayed unreachable through every silent reconnection.
    var onEnded: ((Bool) -> Void)?
    /// A silent reconnection to the line is under way (true) or new video came in again (false). Main thread.
    var onRecovering: ((Bool) -> Void)?

    private let queue = DispatchQueue(label: "nx.liveproxy")
    private var listener: NWListener?
    private var clients = [ObjectIdentifier: NWConnection]()
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private let segmenter = TsSegmenter()
    private var hls = HlsWindow()
    private var target = 0
    private let token = String(UUID().uuidString.prefix(8)).lowercased()
    private var port: UInt16 = 0
    private var stopped = false
    private var readySent = false
    private var unsupported = false
    private var ended = false
    private var upstream: URLRequest?
    private(set) var info: TsSegmenter.StreamInfo? = nil
    /// Why the download from the line stopped, when it is known: "http:403", "network".
    private(set) var failure: String? = nil

    // the line's download
    private let createdAt = Date()
    private var connections = 0
    /// Reconnections in a row that have not produced a new segment yet.
    private var attempts = 0
    private var reconnecting = false
    private var connectedAt = Date()
    private var lastDataAt = Date()
    private var bytesThisConnection = 0
    private var firstDataAt: Date? = nil
    private var contentSeconds = 0.0
    private var lastSegmentAt: Date? = nil
    private var recoveringSent = false
    private var timer: DispatchSourceTimer? = nil
    /// Build pipeline: `-nxProxyDrop <s>` cuts the line's download every s seconds, to exercise the silent reconnection.
    private let dropEvery: Double? = Demo.enabled ? Demo.value("-nxProxyDrop").flatMap { Double($0) } : nil

    // numbers for the log
    private var statsAt = Date()
    private var statsBytes = 0
    private var statsSegments = 0
    private var statsSeconds = 0.0
    private var reconnects = 0
    private var gaps = 0
    private var misses = 0
    private var requests = 0

    /// Seconds without a byte from the line after which the download is considered dead (it is a live channel: data
    /// never stops for this long on a healthy connection). Before the first segment the line gets longer.
    private static let silentLimit = 4.0
    private static let silentLimitStarting = 10.0
    /// The proxy gives up when no new segment arrived for this long, whatever the reconnections did.
    private static let giveUpAfter = 25.0

    func start(url: URL, headers: [String: String]) {
        var req = URLRequest(url: url)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.timeoutInterval = 10
        upstream = req
        segmenter.onInfo = { [weak self] i in self?.gotInfo(i) }
        segmenter.onSegment = { [weak self] s in self?.gotSegment(s) }
        queue.async { self.listen() }
    }

    func stop() {
        queue.async {
            if !self.stopped { self.logStats(final: true) }
            self.stopped = true
            self.timer?.cancel(); self.timer = nil
            self.task?.cancel(); self.task = nil
            self.session?.invalidateAndCancel(); self.session = nil
            self.listener?.cancel(); self.listener = nil
            for c in self.clients.values { c.cancel() }
            self.clients = [:]
            self.hls = HlsWindow()
        }
    }

    // MARK: upstream

    private func listen() {
        do {
            let l = try NWListener(using: .tcp, on: .any)
            l.newConnectionHandler = { [weak self] c in self?.accept(c) }
            l.stateUpdateHandler = { [weak self] st in
                guard let self = self, !self.stopped else { return }
                switch st {
                case .ready:
                    self.port = l.port?.rawValue ?? 0
                    self.download()
                    self.startTimer()
                case .failed(let e):
                    NxLog.w("NxProxy", "listener failed: \(e)")
                    self.finish(early: true)
                default: break
                }
            }
            listener = l
            l.start(queue: queue)
        } catch {
            NxLog.w("NxProxy", "cannot listen: \(error)")
            finish(early: true)
        }
    }

    private func download() {
        guard let req = upstream, !stopped else { return }
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 10
        c.timeoutIntervalForResource = 60 * 60 * 24
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        c.httpMaximumConnectionsPerHost = 1
        let q = OperationQueue()
        q.underlyingQueue = queue
        q.maxConcurrentOperationCount = 1
        let s = URLSession(configuration: c, delegate: self, delegateQueue: q)
        session = s
        connections += 1
        connectedAt = Date()
        lastDataAt = Date()
        bytesThisConnection = 0
        let t = s.dataTask(with: req)
        task = t
        t.resume()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard dataTask === task, !stopped else { completionHandler(.cancel); return }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status < 200 || status >= 300 {
            NxLog.w("NxProxy", "line answered \(status) (connection \(connections))")
            failure = "http:\(status)"
            completionHandler(.cancel)
            if !readySent && hls.isEmpty && connections == 1 { stopDownload(); finish(early: true) }
            // otherwise the completion that follows reconnects
            return
        }
        if connections > 1 { NxLog.i("NxProxy", "line open again (connection \(connections), \(String(format: "%.2f", Date().timeIntervalSince(connectedAt))) s)") }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard dataTask === task, !stopped, !unsupported else { return }
        let now = Date()
        if firstDataAt == nil { firstDataAt = now }
        lastDataAt = now
        bytesThisConnection += data.count
        statsBytes += data.count
        segmenter.feed(data)
    }

    func urlSession(_ session: URLSession, task t: URLSessionTask, didCompleteWithError error: Error?) {
        guard t === task, !stopped else { return }
        task = nil
        var why = "closed by the line"
        if let e = error {
            let ns = e as NSError
            why = e.localizedDescription
            if failure == nil && ns.domain == NSURLErrorDomain && ns.code != NSURLErrorCancelled { failure = "network" }
        }
        NxLog.w("NxProxy", "download ended after \(bytesThisConnection / 1024) KB: \(why)")
        if unsupported { return }
        // nothing ever came from the first connection: a wrong address, a refusal, no network. The caller decides
        // (another quality, the error screen).
        if !readySent && hls.isEmpty && connections == 1 && bytesThisConnection == 0 {
            finish(early: true)
            return
        }
        reconnect(why)
    }

    private func stopDownload() {
        task?.cancel(); task = nil
        session?.invalidateAndCancel(); session = nil
    }

    /// Opens the line again after a pause, keeping the playlist, the segments and the player's connection to us.
    private func reconnect(_ why: String) {
        if stopped || ended || reconnecting { return }
        stopDownload()
        segmenter.restart()
        let now = Date()
        let sinceSegment = now.timeIntervalSince(lastSegmentAt ?? createdAt)
        // before the first picture a broken channel must fail fast (the caller then tries another quality); once it
        // played, the line gets every chance
        if (!readySent && attempts >= 2) || (sinceSegment > LiveProxy.giveUpAfter && attempts >= 3) {
            NxLog.w("NxProxy", "no video for \(Int(sinceSegment)) s after \(attempts) reconnections: giving up")
            ended = true
            timer?.cancel(); timer = nil
            finish(early: !readySent)
            return
        }
        attempts += 1
        reconnects += 1
        reconnecting = true
        let ahead = contentSeconds - (firstDataAt.map { now.timeIntervalSince($0) } ?? 0)
        let delay = HlsWindow.reconnectDelay(attempt: attempts, contentAhead: ahead)
        NxLog.w("NxProxy", "reconnect #\(attempts) in \(String(format: "%.2f", delay)) s (\(why)); \(hls.count) segments in memory, video ahead of the clock \(String(format: "%.1f", ahead)) s")
        if readySent && !recoveringSent {
            recoveringSent = true
            let cb = onRecovering
            DispatchQueue.main.async { cb?(true) }
        }
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, !self.stopped else { return }
            self.reconnecting = false
            self.download()
        }
    }

    private func startTimer() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.5, repeating: 0.5)
        t.setEventHandler { [weak self] in self?.everyHalfSecond() }
        timer = t
        t.resume()
    }

    private func everyHalfSecond() {
        if stopped || ended { return }
        let now = Date()
        if task != nil && !reconnecting {
            let silent = now.timeIntervalSince(lastDataAt)
            let limit = readySent ? LiveProxy.silentLimit : LiveProxy.silentLimitStarting
            if silent > limit {
                reconnect("no data for \(String(format: "%.1f", silent)) s")
            } else if let every = dropEvery, now.timeIntervalSince(connectedAt) > every, bytesThisConnection > 0 {
                reconnect("test drop every \(Int(every)) s")
            }
        }
        if now.timeIntervalSince(statsAt) >= 60 { logStats(final: false) }
    }

    private func logStats(final: Bool) {
        let dt = max(1, Date().timeIntervalSince(statsAt))
        let mbps = Double(statsBytes) * 8 / dt / 1_000_000
        let avg = statsSegments > 0 ? statsSeconds / Double(statsSegments) : 0
        NxLog.i("NxProxy", "\(final ? "closing" : "last \(Int(dt)) s"): \(String(format: "%.2f", mbps)) Mb/s from the line, \(statsSegments) segments of \(String(format: "%.1f", avg)) s, playlist \(hls.window().count) segments, \(hls.bytes / 1_048_576) MB kept; reconnections \(reconnects), gaps \(gaps), missing segments \(misses), requests \(requests), players connected \(clients.count)")
        statsAt = Date(); statsBytes = 0; statsSegments = 0; statsSeconds = 0
    }

    private func finish(early: Bool) {
        if stopped { return }
        let cb = onEnded
        DispatchQueue.main.async { cb?(early) }
    }

    private func gotInfo(_ i: TsSegmenter.StreamInfo) {
        info = i
        NxLog.i("NxProxy", "stream: \(i.summary)")
        if !i.systemPlayable && !readySent {
            unsupported = true
            stopDownload()
            let cb = onUnsupported
            DispatchQueue.main.async { cb?(i.summary) }
        }
    }

    private func gotSegment(_ s: TsSegmenter.Segment) {
        if stopped { return }
        let now = Date()
        if readySent, let last = lastSegmentAt, now.timeIntervalSince(last) > Double(target) + 2 {
            gaps += 1
            NxLog.w("NxProxy", "no new segment for \(String(format: "%.1f", now.timeIntervalSince(last))) s (target \(target) s)")
        }
        lastSegmentAt = now
        if s.discontinuity { NxLog.i("NxProxy", "segment \(s.seq) continues after the reconnection") }
        hls.append(HlsWindow.Entry(seq: s.seq, duration: s.duration, discontinuity: s.discontinuity, data: s.data))
        contentSeconds += s.duration
        statsSegments += 1
        statsSeconds += s.duration
        if attempts > 0 { attempts = 0 }
        if recoveringSent {
            recoveringSent = false
            let cb = onRecovering
            DispatchQueue.main.async { cb?(false) }
        }
        if !readySent && hls.count >= 2 { publish() }
    }

    private func publish() {
        readySent = true
        // the target length is fixed from what the first segments look like: the player needs it constant. One second
        // more than the longest leaves room for a late key frame without ever breaking the rule.
        target = max(4, Int(hls.longest.rounded(.up)) + 1)
        segmenter.maxDuration = Double(target) - 0.2
        segmenter.minDuration = min(2.0, Double(target) - 1)
        NxLog.i("NxProxy", "ready: target \(target) s, first segments \(hls.window().map { String(format: "%.1f", $0.duration) }.joined(separator: "/")) s")
        chooseHost { [weak self] host in
            guard let self = self, !self.stopped, let u = URL(string: "http://\(host):\(self.port)/\(self.token)/live.m3u8") else { return }
            let cb = self.onReady
            DispatchQueue.main.async { cb?(u) }
        }
    }

    // MARK: server

    /// The address in the playlist link. An AirPlay receiver fetches the video itself, so it must be able to reach this
    /// device: the Wi-Fi address when it answers, the loopback otherwise.
    private func chooseHost(_ done: @escaping (String) -> Void) {
        #if os(iOS)
        guard let ip = LiveProxy.wifiAddress(), let p = NWEndpoint.Port(rawValue: port) else { done("127.0.0.1"); return }
        let c = NWConnection(host: NWEndpoint.Host(ip), port: p, using: .tcp)
        var answered = false
        let finish: (String) -> Void = { h in
            if answered { return }
            answered = true
            c.cancel()
            done(h)
        }
        c.stateUpdateHandler = { st in
            switch st {
            case .ready: finish(ip)
            case .failed, .cancelled: finish("127.0.0.1")
            default: break
            }
        }
        c.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 0.5) { finish("127.0.0.1") }
        #else
        done("127.0.0.1")
        #endif
    }

    static func wifiAddress() -> String? {
        var out: String? = nil
        var ifaddr: UnsafeMutablePointer<ifaddrs>? = nil
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            let i = cur.pointee
            if let sa = i.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET), String(cString: i.ifa_name) == "en0" {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 { out = String(cString: host) }
            }
            p = i.ifa_next
        }
        return out
    }

    private func accept(_ c: NWConnection) {
        if stopped { c.cancel(); return }
        let id = ObjectIdentifier(c)
        clients[id] = c
        c.stateUpdateHandler = { [weak self] st in
            switch st {
            case .failed, .cancelled: self?.clients.removeValue(forKey: id)
            default: break
            }
        }
        c.start(queue: queue)
        read(c, Data())
    }

    /// Reads one request; the connection stays open for the next one (the player reloads the playlist every few
    /// seconds and fetches a segment each time: no new connection for each).
    private func read(_ c: NWConnection, _ soFar: Data) {
        if let r = soFar.range(of: Data([13, 10, 13, 10])) {
            let head = String(decoding: soFar.subdata(in: soFar.startIndex..<r.lowerBound), as: UTF8.self)
            let rest = soFar.subdata(in: r.upperBound..<soFar.endIndex)
            respond(c, head) { [weak self] keep in
                if keep, let self = self, !self.stopped { self.read(c, rest) } else { c.cancel() }
            }
            return
        }
        c.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, done, error in
            guard let self = self, !self.stopped else { c.cancel(); return }
            var buf = soFar
            if let d = data { buf.append(d) }
            let complete = buf.range(of: Data([13, 10, 13, 10])) != nil
            if !complete && (done || error != nil || buf.count > 64 * 1024) { c.cancel() }
            else { self.read(c, buf) }
        }
    }

    private func respond(_ c: NWConnection, _ head: String, _ next: @escaping (Bool) -> Void) {
        requests += 1
        let lines = head.split(separator: "\r\n")
        let first = lines.first.map(String.init) ?? ""
        let parts = first.split(separator: " ")
        let method = parts.count > 0 ? String(parts[0]) : ""
        var path = parts.count > 1 ? String(parts[1]) : ""
        let http10 = parts.count > 2 && parts[2] == "HTTP/1.0"
        let wantsClose = lines.dropFirst().contains { $0.lowercased().hasPrefix("connection:") && $0.lowercased().contains("close") }
        let keep = !http10 && !wantsClose
        if let q = path.firstIndex(of: "?") { path = String(path[..<q]) }
        var status = "404 Not Found"
        var type = "text/plain"
        var body = Data()
        let prefix = "/\(token)/"
        if path.hasPrefix(prefix) {
            let name = String(path.dropFirst(prefix.count))
            if name == "live.m3u8" {
                status = "200 OK"; type = "application/vnd.apple.mpegurl"; body = Data(hls.playlist(target: target, ended: ended).utf8)
            } else if name.hasPrefix("seg"), name.hasSuffix(".ts"), let n = Int(name.dropFirst(3).dropLast(3)) {
                if let s = hls.segment(n) { status = "200 OK"; type = "video/mp2t"; body = s.data }
                else {
                    misses += 1
                    if misses <= 20 { NxLog.w("NxProxy", "player asked for segment \(n), not in memory (kept \(hls.entries.first?.seq ?? -1)…\(hls.entries.last?.seq ?? -1))") }
                }
            }
        }
        var out = Data("HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-cache, no-store\r\nAccess-Control-Allow-Origin: *\r\nConnection: \(keep ? "keep-alive" : "close")\r\n\r\n".utf8)
        if method != "HEAD" { out.append(body) }
        c.send(content: out, completion: .contentProcessed { e in next(keep && e == nil) })
    }
}
