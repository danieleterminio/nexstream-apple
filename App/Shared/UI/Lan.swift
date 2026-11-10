import Foundation
import Network
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// The few lines of HTTP/1.1 the home-network features need, on Network.framework: a tiny server (with Bonjour) and a
/// tiny client that can also talk to a service found by Bonjour. Same wire format as the Android app, so the two talk.
enum Lan {
    struct Request {
        var method: String
        var path: String
        var query: [String: String]
        var headers: [String: String]
        var body: Data
        var bodyText: String { String(data: body, encoding: .utf8) ?? "" }
        var form: [String: String] { (headers["content-type"] ?? "").hasPrefix("application/x-www-form-urlencoded") ? Lan.parseQuery(bodyText) : [:] }
        func param(_ k: String) -> String? { form[k] ?? query[k] }
    }
    struct Response {
        var status = 200
        var type = "application/json"
        var body = ""
        var location: String? = nil
        static func json(_ status: Int, _ body: String) -> Response { Response(status: status, type: "application/json", body: body) }
        static func html(_ status: Int, _ body: String) -> Response { Response(status: status, type: "text/html", body: body) }
    }

    static func parseQuery(_ q: String) -> [String: String] {
        var out = [String: String]()
        for kv in q.split(separator: "&") where !kv.isEmpty {
            let parts = kv.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            func dec(_ s: Substring) -> String { String(s).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(s) }
            out[dec(parts[0])] = parts.count > 1 ? dec(parts[1]) : ""
        }
        return out
    }

    /// Only the home network is served: private, link-local and loopback addresses.
    static func isPrivate(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        var s = "\(host)".lowercased()
        if let pct = s.firstIndex(of: "%") { s = String(s[..<pct]) }
        if s.hasPrefix("::ffff:") { s = String(s.dropFirst(7)) }
        if s == "::1" || s.hasPrefix("127.") || s.hasPrefix("10.") || s.hasPrefix("192.168.") || s.hasPrefix("169.254.") || s.hasPrefix("fe80:") || s.hasPrefix("fc") || s.hasPrefix("fd") { return true }
        if s.hasPrefix("172."), let second = Int(s.split(separator: ".")[safe: 1] ?? "") { return (16...31).contains(second) }
        return false
    }

    /// The IPv4 address of the home network (Wi-Fi / Ethernet), skipping VPN tunnels.
    static func address() -> String? {
        var best: (Int, String)? = nil
        var ifaddr: UnsafeMutablePointer<ifaddrs>? = nil
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            let ifa = cur.pointee
            p = ifa.ifa_next
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET), (ifa.ifa_flags & UInt32(IFF_UP)) != 0, (ifa.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            let name = String(cString: ifa.ifa_name)
            if name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("ppp") || name.hasPrefix("tun") || name.hasPrefix("awdl") || name.hasPrefix("llw") { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) != 0 { continue }
            let ip = String(cString: host)
            let privateIp = ip.hasPrefix("10.") || ip.hasPrefix("192.168.") || (ip.hasPrefix("172.") && (16...31).contains(Int(ip.split(separator: ".")[safe: 1] ?? "") ?? 0))
            if !privateIp { continue }
            let rank = name.hasPrefix("en0") ? 0 : (name.hasPrefix("en") ? 1 : 2)
            if best == nil || rank < best!.0 { best = (rank, ip) }
        }
        return best?.1
    }

    static func deviceName() -> String {
        #if os(tvOS)
        return "NexStream · Apple TV"
        #else
        return "NexStream · " + (UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone")
        #endif
    }

    static func token(_ n: Int, alphabet: String = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789") -> String {
        let a = Array(alphabet)
        return String((0..<n).map { _ in a[Int.random(in: 0..<a.count)] })
    }

    static func qr(_ text: String) -> UIImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 12, y: 12)), let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    // ------------------------------------------------------------------------------------------------------- server

    final class Server {
        private var listener: NWListener?
        private let queue = DispatchQueue(label: "nx.lan.server")
        private let handler: (Request) async -> Response
        private(set) var port: UInt16 = 0

        init(handler: @escaping (Request) async -> Response) { self.handler = handler }

        /// Starts on the first free port of `ports` (any free port otherwise); announces itself when `bonjour` is given.
        func start(ports: [UInt16], bonjour: (String, String)? = nil) -> Bool {
            for p in ports + [0] {
                guard let l = try? NWListener(using: .tcp, on: p == 0 ? .any : (NWEndpoint.Port(rawValue: p) ?? .any)) else { continue }
                if let b = bonjour { l.service = NWListener.Service(name: b.0, type: b.1) }
                l.newConnectionHandler = { [weak self] c in self?.accept(c) }
                let ready = DispatchSemaphore(value: 0)
                var ok = false
                l.stateUpdateHandler = { st in
                    switch st {
                    case .ready: ok = true; ready.signal()
                    case .failed, .cancelled: ready.signal()
                    default: break
                    }
                }
                l.start(queue: queue)
                _ = ready.wait(timeout: .now() + 2)
                if ok, let actual = l.port?.rawValue { listener = l; port = actual; l.stateUpdateHandler = nil; return true }
                l.cancel()
            }
            return false
        }

        func stop() { listener?.cancel(); listener = nil }

        private func accept(_ c: NWConnection) {
            c.start(queue: queue)
            read(c, Data())
        }

        private func read(_ c: NWConnection, _ buffer: Data) {
            c.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, done, err in
                guard let self = self else { c.cancel(); return }
                var buf = buffer
                if let d = data { buf.append(d) }
                if let req = Server.parse(buf) {
                    if !Lan.isPrivate(c.endpoint) { self.send(c, .json(403, "{\"ok\":false}")); return }
                    Task { let resp = await self.handler(req); self.send(c, resp) }
                } else if done || err != nil || buf.count > 3 * 1024 * 1024 { c.cancel() }
                else { self.read(c, buf) }
            }
        }

        /// A complete request, or nil while bytes are still missing.
        private static func parse(_ buf: Data) -> Request? {
            guard let end = buf.range(of: Data([13, 10, 13, 10])) else { return nil }
            guard let head = String(data: buf[buf.startIndex..<end.lowerBound], encoding: .utf8) else { return nil }
            let lines = head.components(separatedBy: "\r\n")
            let parts = (lines.first ?? "").split(separator: " ")
            if parts.count < 2 { return nil }
            var headers = [String: String]()
            for l in lines.dropFirst() { if let i = l.firstIndex(of: ":") { headers[l[..<i].trimmingCharacters(in: .whitespaces).lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces) } }
            let len = min(max(Int(headers["content-length"] ?? "") ?? 0, 0), 2 * 1024 * 1024)
            let bodyStart = end.upperBound
            if buf.count - buf.distance(from: buf.startIndex, to: bodyStart) < len { return nil }
            let target = String(parts[1])
            let path = target.substringBefore("?")
            let query = target.contains("?") ? Lan.parseQuery(target.substringAfter("?")) : [:]
            return Request(method: parts[0].uppercased(), path: path, query: query, headers: headers, body: Data(buf[bodyStart..<buf.index(bodyStart, offsetBy: len)]))
        }

        private func send(_ c: NWConnection, _ r: Response) {
            let body = Data(r.body.utf8)
            let reason: String
            switch r.status { case 200: reason = "OK"; case 302: reason = "Found"; case 401: reason = "Unauthorized"; case 403: reason = "Forbidden"; case 404: reason = "Not Found"; case 410: reason = "Gone"; default: reason = "OK" }
            var head = "HTTP/1.1 \(r.status) \(reason)\r\nContent-Type: \(r.type); charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nX-Frame-Options: DENY\r\nConnection: close\r\n"
            if let l = r.location { head += "Location: \(l)\r\n" }
            head += "\r\n"
            var out = Data(head.utf8); out.append(body)
            c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
        }
    }

    // ------------------------------------------------------------------------------------------------------- client

    struct Reply {
        var status: Int
        var text: String
        var json: J { J.parse(text) }
        var ok: Bool { status >= 200 && status < 300 && json["ok"].boolOrNil != false }
        var error: String? { json["error"].stringOrNil }
    }

    /// "192.168.1.50" / "192.168.1.50:8765" / "http://…" -> host and port.
    static func endpoint(_ address: String, defaultPort: UInt16) -> NWEndpoint? {
        let a = address.trimmed.removingPrefix("http://").trimmingEnd("/")
        let parts = a.split(separator: ":")
        guard let host = parts.first, !host.isEmpty else { return nil }
        let port = parts.count > 1 ? (UInt16(parts[1]) ?? defaultPort) : defaultPort
        guard let p = NWEndpoint.Port(rawValue: port) else { return nil }
        return .hostPort(host: NWEndpoint.Host(String(host)), port: p)
    }

    /// One HTTP request to a device of the home network (never through the VPN filter: it stays on the LAN).
    static func call(_ endpoint: NWEndpoint, _ path: String, headers: [String: String] = [:], body: String? = nil, timeout: Double = 8) async -> Reply {
        await withCheckedContinuation { (cont: CheckedContinuation<Reply, Never>) in
            let params = NWParameters.tcp
            params.prohibitedInterfaceTypes = [.cellular]
            let c = NWConnection(to: endpoint, using: params)
            let q = DispatchQueue(label: "nx.lan.client")
            var finished = false
            func finish(_ r: Reply) { if !finished { finished = true; c.cancel(); cont.resume(returning: r) } }
            var received = Data()
            func readAll() {
                c.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, done, err in
                    if let d = data { received.append(d) }
                    if done || err != nil {
                        guard let end = received.range(of: Data([13, 10, 13, 10])), let head = String(data: received[received.startIndex..<end.lowerBound], encoding: .utf8) else { finish(Reply(status: 0, text: "")); return }
                        let status = Int(head.split(separator: " ")[safe: 1] ?? "") ?? 0
                        finish(Reply(status: status, text: String(data: received[end.upperBound...], encoding: .utf8) ?? ""))
                    } else { readAll() }
                }
            }
            c.stateUpdateHandler = { st in
                switch st {
                case .ready:
                    let payload = Data((body ?? "").utf8)
                    var head = "\(body == nil ? "GET" : "POST") \(path) HTTP/1.1\r\nHost: nexstream.local\r\nConnection: close\r\nAccept: application/json\r\n"
                    if body != nil { head += "Content-Type: application/json\r\nContent-Length: \(payload.count)\r\n" }
                    for (k, v) in headers { head += "\(k): \(v)\r\n" }
                    head += "\r\n"
                    var out = Data(head.utf8); out.append(payload)
                    c.send(content: out, completion: .contentProcessed { _ in })
                    readAll()
                case .failed, .cancelled: finish(Reply(status: 0, text: ""))
                case .waiting: finish(Reply(status: 0, text: ""))
                default: break
                }
            }
            c.start(queue: q)
            q.asyncAfter(deadline: .now() + timeout) { finish(Reply(status: 0, text: "")) }
        }
    }

    /// A device found on the network.
    struct Device: Identifiable, Hashable {
        let name: String
        let endpoint: NWEndpoint
        var id: String { name }
        var label: String { name.substringAfter("· ", orElse: name) }
    }

    /// Looks for a Bonjour service type on the home network, calling back with the list as it changes.
    final class Finder {
        private var browser: NWBrowser?
        func start(type: String, onChange: @escaping ([Device]) -> Void) {
            let params = NWParameters()
            params.includePeerToPeer = false
            let b = NWBrowser(for: .bonjour(type: type, domain: nil), using: params)
            b.browseResultsChangedHandler = { results, _ in
                var out = [Device]()
                for r in results { if case .service(let name, _, _, _) = r.endpoint, name != Lan.deviceName() || true { out.append(Device(name: name, endpoint: r.endpoint)) } }
                DispatchQueue.main.async { onChange(out.sorted { $0.name < $1.name }) }
            }
            b.start(queue: DispatchQueue(label: "nx.lan.finder"))
            browser = b
        }
        func stop() { browser?.cancel(); browser = nil }
        deinit { browser?.cancel() }
    }
}
