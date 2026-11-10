import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Thrown for every request attempted while the VPN is off: nothing leaves the device unprotected.
struct VpnRequiredError: Error, CustomStringConvertible { var description: String { "VPN non attiva" } }

struct HttpError: Error, CustomStringConvertible {
    let status: Int
    let url: String
    var description: String { "http \(status) \(url)" }
}

struct HttpResponse {
    let data: Data
    let status: Int
    var ok: Bool { status >= 200 && status < 300 }
    var text: String { String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self) }
}

/// Shared HTTP. Every request — API, guide, images — goes through the VPN filter first, unless it says otherwise
/// (home-network features, TMDB and the addon updater on Android had their own unfiltered clients; here only the LAN ones do).
enum Http {
    /// Xtream panels behind proxies answer 502 to requests without a "player-like" User-Agent.
    static let userAgent = "NexStream/1.0 (Linux; Android) IPTVSmartersPlayer"
    static let browserUA = "Mozilla/5.0 (Linux; Android 12; TV) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"

    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 20
        c.timeoutIntervalForResource = 180
        c.httpMaximumConnectionsPerHost = 6
        c.requestCachePolicy = .useProtocolCachePolicy
        c.httpAdditionalHeaders = ["User-Agent": userAgent]
        return URLSession(configuration: c)
    }()

    static func request(_ url: String, method: String = "GET", headers: [String: String] = [:], body: Data? = nil,
                        timeout: TimeInterval = 20, needsVpn: Bool = true) async throws -> HttpResponse {
        if needsVpn && !Vpn.shared.active.value { throw VpnRequiredError() }
        guard let u = URL(string: url) ?? URL(string: url.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? url) else { throw HttpError(status: -1, url: url) }
        var req = URLRequest(url: u, timeoutInterval: timeout)
        req.httpMethod = method
        if headers["User-Agent"] == nil { req.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = body
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<HttpResponse, Error>) in
            let task = session.dataTask(with: req) { data, resp, err in
                if let err = err { c.resume(throwing: err); return }
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                c.resume(returning: HttpResponse(data: data ?? Data(), status: status))
            }
            task.resume()
        }
    }

    /// GET returning the body as text; a non-2xx status is an error.
    static func text(_ url: String, headers: [String: String] = [:], timeout: TimeInterval = 20, needsVpn: Bool = true) async throws -> String {
        let r = try await request(url, headers: headers, timeout: timeout, needsVpn: needsVpn)
        if !r.ok { throw HttpError(status: r.status, url: url) }
        return r.text
    }

    static func data(_ url: String, headers: [String: String] = [:], timeout: TimeInterval = 20, needsVpn: Bool = true) async throws -> Data {
        let r = try await request(url, headers: headers, timeout: timeout, needsVpn: needsVpn)
        if !r.ok { throw HttpError(status: r.status, url: url) }
        return r.data
    }

    /// GET decoded as JSON (unknown keys ignored).
    static func json<T: Decodable>(_ type: T.Type, _ url: String, headers: [String: String] = [:], needsVpn: Bool = true) async throws -> T {
        var h = headers
        if h["Accept"] == nil { h["Accept"] = "application/json" }
        let d = try await data(url, headers: h, needsVpn: needsVpn)
        return try JSONDecoder().decode(type, from: d)
    }

    /// Any JSON, as Foundation objects (dictionaries / arrays), for the feeds read field by field.
    static func jsonObject(_ url: String, headers: [String: String] = [:], needsVpn: Bool = true) async throws -> Any {
        var h = headers
        if h["Accept"] == nil { h["Accept"] = "application/json" }
        let d = try await data(url, headers: h, needsVpn: needsVpn)
        return try JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed])
    }

    /// Streams a big download (the XMLTV guides) straight to a file.
    static func download(_ url: String, to dest: URL, headers: [String: String] = [:], needsVpn: Bool = true) async throws {
        if needsVpn && !Vpn.shared.active.value { throw VpnRequiredError() }
        guard let u = URL(string: url) else { throw HttpError(status: -1, url: url) }
        var req = URLRequest(url: u, timeoutInterval: 60)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let task = session.downloadTask(with: req) { tmp, resp, err in
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
        }
    }
}

/// Reading loosely-typed JSON (the broadcaster feeds) without a model for every shape.
struct J {
    let raw: Any?
    init(_ raw: Any?) { self.raw = raw is NSNull ? nil : raw }
    static func parse(_ text: String) -> J { J(try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])) }
    static func parse(_ data: Data) -> J { J(try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) }

    subscript(_ key: String) -> J { J((raw as? [String: Any])?[key]) }
    subscript(_ i: Int) -> J { let a = raw as? [Any]; return J(a != nil && i >= 0 && i < a!.count ? a![i] : nil) }
    var exists: Bool { raw != nil }
    var array: [J] { (raw as? [Any])?.map { J($0) } ?? [] }
    var dict: [String: J] { (raw as? [String: Any])?.mapValues { J($0) } ?? [:] }
    /// Text of a string / number / bool value; nil for objects, arrays and null.
    var stringOrNil: String? {
        if let s = raw as? String { return s }
        if let n = raw as? NSNumber {
            if CFNumberTypeCheck.isBool(n) { return n.boolValue ? "true" : "false" }
            if n.doubleValue == n.doubleValue.rounded() && abs(n.doubleValue) < 1e15 { return String(n.int64Value) }
            return String(n.doubleValue)
        }
        return nil
    }
    var string: String { stringOrNil ?? "" }
    var intOrNil: Int? {
        if let n = raw as? NSNumber { return n.intValue }
        if let s = raw as? String { return Int(s.trimmed) }
        return nil
    }
    var int: Int { intOrNil ?? 0 }
    var int64OrNil: Int64? {
        if let n = raw as? NSNumber { return n.int64Value }
        if let s = raw as? String { return Int64(s.trimmed) }
        return nil
    }
    var doubleOrNil: Double? {
        if let n = raw as? NSNumber { return n.doubleValue }
        if let s = raw as? String { return Double(s.trimmed) }
        return nil
    }
    var double: Double { doubleOrNil ?? 0 }
    var boolOrNil: Bool? {
        if let n = raw as? NSNumber { return n.boolValue }
        if let s = raw as? String { return s == "true" || s == "1" }
        return nil
    }
    var bool: Bool { boolOrNil ?? false }
}

enum CFNumberTypeCheck {
    static func isBool(_ n: NSNumber) -> Bool {
        #if canImport(CoreFoundation) && !os(Windows) && !os(Linux)
        return CFGetTypeID(n) == CFBooleanGetTypeID()
        #else
        return String(cString: n.objCType) == "c"
        #endif
    }
}

/// JSON text for a value built from dictionaries / arrays / strings / numbers.
func jsonString(_ value: Any) -> String {
    guard JSONSerialization.isValidJSONObject(value), let d = try? JSONSerialization.data(withJSONObject: value, options: []) else {
        if let s = value as? String, let d = try? JSONSerialization.data(withJSONObject: [s], options: []), let t = String(data: d, encoding: .utf8) { return String(t.dropFirst().dropLast()) }
        return "null"
    }
    return String(data: d, encoding: .utf8) ?? "null"
}
