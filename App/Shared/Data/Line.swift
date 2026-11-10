import Foundation

// MegaOTT reseller API + Xtream Codes client + the "username and password only" login that ties them.

/// A subscription (line) as returned by the reseller API. Only the fields the app needs.
struct Subscription {
    var id: Int64 = 0
    var username: String? = nil
    var maxConnections: Int = 1
    var expiringAt: String? = nil
    var dnsLink: String? = nil

    init(_ j: J) {
        id = j["id"].int64OrNil ?? 0
        username = j["username"].stringOrNil
        maxConnections = j["max_connections"].intOrNil ?? 1
        expiringAt = j["expiring_at"].stringOrNil
        dnsLink = j["dns_link"].stringOrNil
    }
}

enum LookupResult {
    case found(Subscription)
    case notFound
    case multiple([Int64])
    case error(Int, String)
}

/// Client for the MegaOTT reseller API (https://megaott.net/api/v1). The Bearer token is baked in at build time and must
/// have the `subscription_read` ability. It resolves a line's current `dns_link` from its username, so the user only ever
/// types username + password.
final class MegaOttApi {
    private let base: String
    private let token: String
    init(base: String = "https://megaott.net/api/v1", token: String = Secrets.megaOttToken) { self.base = base; self.token = token }

    private func get(_ path: String) async throws -> HttpResponse {
        try await Http.request(base + path, headers: ["Authorization": "Bearer \(token)", "Accept": "application/json"])
    }

    func byUsername(_ username: String) async -> LookupResult {
        do {
            let r = try await get("/subscriptions/by-username?username=\(username.urlQueryEncoded)")
            switch r.status {
            case 200: return .found(Subscription(J.parse(r.data)))
            case 404: return .notFound
            case 409: return .multiple(J.parse(r.data)["matches"].array.compactMap { $0["id"].int64OrNil })
            default: return .error(r.status, r.text.take(200))
            }
        } catch let e as VpnRequiredError { return .error(-2, e.description) }
        catch { return .error(-1, error.localizedDescription) }
    }

    func byId(_ id: Int64) async throws -> Subscription {
        let r = try await get("/subscriptions/\(id)")
        if !r.ok { throw HttpError(status: r.status, url: "subscription \(id)") }
        return Subscription(J.parse(r.data))
    }
}

struct XtreamCategory { var categoryId: String; var categoryName: String }
struct LiveStream {
    var num: String?
    var name: String
    var streamId: String
    var streamIcon: String?
    var epgChannelId: String?
    var categoryId: String?
    var tvArchive: Int
}
struct XtreamUserInfo { var auth: Int; var status: String; var expDate: String? }

/// Xtream Codes client. `base` is the line's dns_link (e.g. http://host:port), resolved from MegaOTT.
/// Panels return ids/numbers sometimes as JSON numbers, sometimes as strings: everything is read as text.
final class XtreamClient {
    let base: String
    private let username: String
    private let password: String

    init(base: String, username: String, password: String) {
        self.base = base.trimmed.trimmingEnd("/")
        self.username = username
        self.password = password
    }

    private var creds: String { "username=\(username.urlQueryEncoded)&password=\(password.urlQueryEncoded)" }
    private func api(_ action: String? = nil, _ extra: String = "") -> String {
        base + "/player_api.php?" + creds + (action.map { "&action=\($0)" } ?? "") + extra
    }
    private func raw(_ url: String) async throws -> Data {
        let r = try await Http.request(url, headers: ["Accept": "application/json"], timeout: 30)
        if !r.ok { throw HttpError(status: r.status, url: "xtream") }
        return r.data
    }

    func authenticate() async throws -> XtreamUserInfo? {
        let j = J.parse(try await raw(api()))["user_info"]
        guard j.exists else { return nil }
        return XtreamUserInfo(auth: j["auth"].int, status: j["status"].string, expDate: j["exp_date"].stringOrNil)
    }

    func liveCategories() async throws -> [XtreamCategory] {
        J.parse(try await raw(api("get_live_categories"))).array.map { XtreamCategory(categoryId: $0["category_id"].string, categoryName: $0["category_name"].string) }
    }

    func liveStreams() async throws -> [LiveStream] {
        J.parse(try await raw(api("get_live_streams"))).array.map { s in
            LiveStream(num: s["num"].stringOrNil, name: s["name"].string, streamId: s["stream_id"].string, streamIcon: s["stream_icon"].stringOrNil,
                       epgChannelId: s["epg_channel_id"].stringOrNil, categoryId: s["category_id"].stringOrNil, tvArchive: s["tv_archive"].int)
        }
    }

    // --- stream URL builders
    func liveUrl(_ streamId: String, ext: String = "m3u8") -> String { "\(base)/live/\(username.urlQueryEncoded)/\(password.urlQueryEncoded)/\(streamId).\(ext)" }
    func xmltvUrl() -> String { "\(base)/xmltv.php?\(creds)" }

    /// Validate that a dns_link looks usable as an Xtream base.
    static func isValidBase(_ dns: String?) -> Bool {
        guard let d = dns, let u = URL(string: d), let scheme = u.scheme?.lowercased(), (scheme == "http" || scheme == "https"), let h = u.host, !h.isEmpty else { return false }
        return true
    }
}

enum LoginResult {
    case success(LineSession)
    case notFound          // username not under this reseller account
    case authFailed        // dns resolved but Xtream rejected user/pass
    case expired           // line found but not Active
    case error(String)
}

/// Ties the two steps of "username + password only" login:
///  1. resolve the line's current dns_link from MegaOTT (by-username),
///  2. authenticate user+pass against that Xtream server.
/// The dns_link is re-resolved on each login/startup so a rotated server keeps working.
final class LoginRepository {
    private let megaOtt: MegaOttApi
    private let session: Session
    init(megaOtt: MegaOttApi, session: Session) { self.megaOtt = megaOtt; self.session = session }

    func login(username: String, password: String) async -> LoginResult {
        let sub: Subscription
        switch await megaOtt.byUsername(username) {
        case .found(let s): sub = s
        case .multiple(let ids):
            guard let id = ids.first else { return .notFound }
            do { sub = try await megaOtt.byId(id) } catch { return .error("Ricerca della linea non riuscita") }
        case .notFound: return .notFound
        case .error(let code, let message):
            if code == 403 { return .error("API non autorizzata (manca subscription_read)") }
            if code == -2 { return .error("Accendi la VPN e riprova.") }
            if code == -1 { return .error("Nessuna connessione: \(message)") }
            return .error("Errore \(code): \(message)")
        }
        guard let base = sub.dnsLink?.trimmed.trimmingEnd("/"), !base.isEmpty, XtreamClient.isValidBase(base) else { return .error("Server non disponibile per questa linea") }
        let client = XtreamClient(base: base, username: username, password: password)
        guard let info = (try? await client.authenticate()) ?? nil, info.auth == 1 else { return .authFailed }
        if !info.status.equalsIgnoringCase("Active") { return .expired }
        let s = LineSession(username: username, password: password, base: base, expiringAt: sub.expiringAt ?? info.expDate, maxConnections: sub.maxConnections)
        session.save(s)
        return .success(s)
    }

    /// On startup, re-resolve the dns_link for the stored line so a rotated server keeps working. Best-effort.
    func refreshDns() async {
        guard let s = session.current.value else { return }
        if case .found(let sub) = await megaOtt.byUsername(s.username), let link = sub.dnsLink?.trimmed.trimmingEnd("/"), XtreamClient.isValidBase(link) {
            session.updateBase(link)
        }
    }
}
