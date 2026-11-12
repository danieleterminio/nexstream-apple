import Foundation
import Network

/// Lets the system player show a live channel. The line serves channels as one endless MPEG-TS download, which the
/// system player cannot open; this reads that download, cuts it into HLS segments in memory and serves them from a
/// tiny HTTP server inside the app. With it come AirPlay, picture in picture and the system's own controls.
/// One instance per tuned channel: `start`, wait for `onReady`, `stop`.
final class LiveProxy: NSObject, URLSessionDataDelegate {
    /// The playlist can be opened (two segments are in memory).
    var onReady: ((URL) -> Void)?
    /// The stream uses codecs the system player cannot decode: use the other engine.
    var onUnsupported: ((String) -> Void)?
    /// The download from the line stopped. `true` = before anything could be played.
    var onEnded: ((Bool) -> Void)?

    private let queue = DispatchQueue(label: "nx.liveproxy")
    private var listener: NWListener?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private let segmenter = TsSegmenter()
    private var segments = [TsSegmenter.Segment]()
    private var target = 0
    private let token = String(UUID().uuidString.prefix(8)).lowercased()
    private var port: UInt16 = 0
    private var stopped = false
    private var readySent = false
    private var unsupported = false
    private var ended = false
    private var upstream: URLRequest?
    private(set) var info: TsSegmenter.StreamInfo? = nil

    private static let windowSize = 6
    private static let kept = 14

    func start(url: URL, headers: [String: String]) {
        var req = URLRequest(url: url)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.timeoutInterval = 15
        upstream = req
        segmenter.onInfo = { [weak self] i in self?.gotInfo(i) }
        segmenter.onSegment = { [weak self] s in self?.gotSegment(s) }
        queue.async { self.listen() }
    }

    func stop() {
        queue.async {
            self.stopped = true
            self.task?.cancel(); self.task = nil
            self.session?.invalidateAndCancel(); self.session = nil
            self.listener?.cancel(); self.listener = nil
            self.segments = []
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
        c.timeoutIntervalForRequest = 15
        c.timeoutIntervalForResource = 60 * 60 * 24
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        let q = OperationQueue()
        q.underlyingQueue = queue
        q.maxConcurrentOperationCount = 1
        let s = URLSession(configuration: c, delegate: self, delegateQueue: q)
        session = s
        let t = s.dataTask(with: req)
        task = t
        t.resume()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status < 200 || status >= 300 {
            NxLog.w("NxProxy", "line answered \(status)")
            completionHandler(.cancel)
            finish(early: true)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if stopped || unsupported { return }
        segmenter.feed(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if stopped { return }
        if let e = error { NxLog.w("NxProxy", "download ended: \(e.localizedDescription)") }
        segmenter.finish()
        ended = true
        if !readySent && !segments.isEmpty && !unsupported { publish() }
        finish(early: !readySent)
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
            let cb = onUnsupported
            DispatchQueue.main.async { cb?(i.summary) }
        }
    }

    private func gotSegment(_ s: TsSegmenter.Segment) {
        if stopped { return }
        segments.append(s)
        if segments.count > LiveProxy.kept { segments.removeFirst(segments.count - LiveProxy.kept) }
        if !readySent && segments.count >= 2 { publish() }
    }

    private func publish() {
        do {
            readySent = true
            // the target length is fixed from what the first segments look like: the player needs it constant
            let longest = segments.map { $0.duration }.max() ?? 2
            target = max(3, Int(longest.rounded(.up)) + 1)
            segmenter.maxDuration = Double(target) - 0.2
            segmenter.minDuration = min(2.0, Double(target) - 1)
            chooseHost { [weak self] host in
                guard let self = self, !self.stopped, let u = URL(string: "http://\(host):\(self.port)/\(self.token)/live.m3u8") else { return }
                let cb = self.onReady
                DispatchQueue.main.async { cb?(u) }
            }
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
        c.start(queue: queue)
        read(c, Data())
    }

    private func read(_ c: NWConnection, _ soFar: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, done, error in
            guard let self = self else { c.cancel(); return }
            var buf = soFar
            if let d = data { buf.append(d) }
            if let r = buf.range(of: Data([13, 10, 13, 10])) {
                let head = String(decoding: buf.subdata(in: buf.startIndex..<r.lowerBound), as: UTF8.self)
                self.respond(c, head)
            } else if done || error != nil || buf.count > 64 * 1024 { c.cancel() }
            else { self.read(c, buf) }
        }
    }

    private func respond(_ c: NWConnection, _ head: String) {
        let first = head.split(separator: "\r\n").first.map(String.init) ?? ""
        let parts = first.split(separator: " ")
        let method = parts.count > 0 ? String(parts[0]) : ""
        var path = parts.count > 1 ? String(parts[1]) : ""
        if let q = path.firstIndex(of: "?") { path = String(path[..<q]) }
        var status = "404 Not Found"
        var type = "text/plain"
        var body = Data()
        let prefix = "/\(token)/"
        if path.hasPrefix(prefix) {
            let name = String(path.dropFirst(prefix.count))
            if name == "live.m3u8" {
                status = "200 OK"; type = "application/vnd.apple.mpegurl"; body = Data(playlist().utf8)
            } else if name.hasPrefix("seg"), name.hasSuffix(".ts"), let n = Int(name.dropFirst(3).dropLast(3)), let s = segments.first(where: { $0.seq == n }) {
                status = "200 OK"; type = "video/mp2t"; body = s.data
            }
        }
        var out = Data("HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-cache\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n".utf8)
        if method != "HEAD" { out.append(body) }
        c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
    }

    private func playlist() -> String {
        let window = segments.suffix(LiveProxy.windowSize)
        var s = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:\(target)\n#EXT-X-MEDIA-SEQUENCE:\(window.first?.seq ?? 0)\n"
        for seg in window { s += "#EXTINF:" + String(format: "%.3f", seg.duration) + ",\nseg\(seg.seq).ts\n" }
        if ended { s += "#EXT-X-ENDLIST\n" }
        return s
    }
}
