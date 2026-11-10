import SwiftUI
import Network

extension Notification.Name {
    /// A key sent by a phone remote ("playpause", "chup", "chdown", "back", "ok"); the players listen.
    static let nxRemoteKey = Notification.Name("nx.remote.key")
}

/// Phone side of "telefono come telecomando": talks to NexStream on a TV of the home network — the Android TV / Fire TV
/// app (full remote) or the Apple TV one (channels, search, play/pause). Plain HTTP on the LAN: no internet, no VPN.
final class RemoteClient {
    struct Tv: Identifiable, Hashable { var name: String; var address: String; var token: String?; var id: String { address } }
    struct Channel: Identifiable, Hashable { let id: String; let num: Int; let name: String; let logo: String?; let now: String?; let cat: String }

    private let d = UserDefaults.standard
    static let service = "_nexremote._tcp"
    static let defaultPort: UInt16 = 8790

    /// Paired TVs, last used first.
    func saved() -> [Tv] {
        (d.string(forKey: "remote.tvs") ?? "").split(separator: "\n").compactMap { l in
            let p = l.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            return p.count == 3 ? Tv(name: p[2], address: p[0], token: p[1].isEmpty ? nil : p[1]) : nil
        }
    }
    func remember(_ tv: Tv) {
        let list = [tv] + saved().filter { $0.address != tv.address }
        d.set(list.prefix(6).map { "\($0.address)|\($0.token ?? "")|\($0.name)" }.joined(separator: "\n"), forKey: "remote.tvs")
    }
    func forget(_ address: String) { d.set(saved().filter { $0.address != address }.map { "\($0.address)|\($0.token ?? "")|\($0.name)" }.joined(separator: "\n"), forKey: "remote.tvs") }

    private func call(_ address: String, _ path: String, token: String?, body: [String: Any]?) async -> Lan.Reply {
        guard let ep = Lan.endpoint(address, defaultPort: RemoteClient.defaultPort) else { return Lan.Reply(status: 0, text: "") }
        return await Lan.call(ep, path, headers: token.map { ["X-Token": $0] } ?? [:], body: body.map { jsonString($0) }, timeout: 6)
    }
    func hello(_ address: String, token: String?) async -> Lan.Reply { await call(address, "/hello", token: token, body: nil) }
    func pairStart(_ address: String) async -> Lan.Reply { await call(address, "/pair/start", token: nil, body: ["name": Lan.deviceName().substringAfter("· ")]) }
    func pair(_ address: String, pin: String) async -> Lan.Reply { await call(address, "/pair", token: nil, body: ["pin": pin, "name": Lan.deviceName().substringAfter("· ")]) }
    @discardableResult func key(_ tv: Tv, _ k: String) async -> Lan.Reply { await call(tv.address, "/key", token: tv.token, body: ["k": k]) }
    @discardableResult func home(_ tv: Tv) async -> Lan.Reply { await call(tv.address, "/home", token: tv.token, body: [:]) }
    @discardableResult func volume(_ tv: Tv, _ dir: String) async -> Lan.Reply { await call(tv.address, "/vol", token: tv.token, body: ["d": dir]) }
    @discardableResult func search(_ tv: Tv, _ q: String) async -> Lan.Reply { await call(tv.address, "/search", token: tv.token, body: ["q": q]) }
    @discardableResult func tune(_ tv: Tv, id: String) async -> Lan.Reply { await call(tv.address, "/tune", token: tv.token, body: ["id": id]) }
    func channels(_ tv: Tv) async -> [Channel]? {
        let r = await call(tv.address, "/channels", token: tv.token, body: [:])
        if r.status != 200 { return nil }
        return J.parse(r.text).array.compactMap { o in
            guard let id = o["id"].stringOrNil else { return nil }
            return Channel(id: id, num: o["num"].int, name: o["name"].string, logo: o["logo"].stringOrNil, now: o["now"].stringOrNil, cat: o["cat"].string)
        }
    }

    /// The address ("host:port") behind a service found by Bonjour.
    static func resolve(_ endpoint: NWEndpoint) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            let c = NWConnection(to: endpoint, using: .tcp)
            let q = DispatchQueue(label: "nx.remote.resolve")
            var done = false
            func finish(_ v: String?) { if !done { done = true; c.cancel(); cont.resume(returning: v) } }
            c.stateUpdateHandler = { st in
                switch st {
                case .ready:
                    if case .hostPort(let host, let port)? = c.currentPath?.remoteEndpoint {
                        var h = "\(host)"
                        if let pct = h.firstIndex(of: "%") { h = String(h[..<pct]) }
                        finish(h.contains(":") ? nil : "\(h):\(port.rawValue)")
                    } else { finish(nil) }
                case .failed, .cancelled, .waiting: finish(nil)
                default: break
                }
            }
            c.start(queue: q)
            q.asyncAfter(deadline: .now() + 4) { finish(nil) }
        }
    }
}

#if os(iOS)
/// The phone as the TV's remote: pick the TV (found on the network or by address), pair once with the PIN it shows, then
/// arrows, OK, back, volume, channels and search with the phone keyboard — all on one screen.
struct RemoteView: View {
    @EnvironmentObject var app: AppModel
    @State private var client = RemoteClient()
    @State private var tv: RemoteClient.Tv? = nil
    @State private var saved: [RemoteClient.Tv] = []
    @State private var found: [Lan.Device] = []
    @State private var finder = Lan.Finder()
    @State private var manual = ""
    @State private var pairingAddress: String? = nil
    @State private var pairingName = ""
    @State private var pin = ""
    @State private var message: String? = nil
    @State private var busy = false
    @State private var volume = false
    @State private var channels: [RemoteClient.Channel] = []
    @State private var showChannels = false
    @State private var query = ""

    var body: some View {
        Group {
            if let t = tv { pad(t) } else if let a = pairingAddress { pairing(a) } else { picker }
        }
        .nxPage()
        .nxTitle(tv?.name ?? "Telecomando")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .onAppear {
            saved = client.saved()
            finder.start(type: RemoteClient.service) { found = $0 }
            if tv == nil, let last = saved.first { connect(last.address, name: last.name, token: last.token) }
        }
        .onDisappear { finder.stop() }
        .sheet(isPresented: $showChannels) { channelSheet }
    }

    private func connect(_ address: String, name: String, token: String?) {
        busy = true; message = nil
        Task {
            let r = await client.hello(address, token: token)
            busy = false
            if r.status == 0 { message = "Non trovo la TV a \(address). NexStream deve essere aperto sulla TV, sulla stessa rete."; return }
            let tvName = r.json["name"].stringOrNil?.substringAfter("· ") ?? name
            volume = r.json["volume"].bool
            if r.json["paired"].bool, let tok = token {
                let t = RemoteClient.Tv(name: tvName, address: address, token: tok)
                client.remember(t); saved = client.saved(); tv = t
                channels = await client.channels(t) ?? []
            } else {
                pairingName = tvName; pin = ""
                _ = await client.pairStart(address)
                pairingAddress = address
            }
        }
    }

    private var picker: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Apri NexStream sulla TV: compare qui sotto. La prima volta la TV mostra un codice da scrivere sul telefono.").font(NxFont.meta).foregroundStyle(NxColor.textMuted)
                if busy { HStack(spacing: 8) { ProgressView(); Text("Mi collego…").font(NxFont.meta).foregroundStyle(NxColor.textMuted) } }
                if let m = message { Label(m, systemImage: "exclamationmark.triangle.fill").font(NxFont.meta).foregroundStyle(NxColor.accentBright) }
                if !saved.isEmpty {
                    Text("LE TUE TV").font(NxFont.label).tracking(1).foregroundStyle(NxColor.textDim)
                    ForEach(saved) { t in
                        HStack {
                            NxButton(t.name, icon: "tv", wide: true) { connect(t.address, name: t.name, token: t.token) }
                            NxIconButton(icon: "trash", label: "Dimentica", size: 40) { client.forget(t.address); saved = client.saved() }
                        }
                    }
                }
                let fresh = found.filter { d in !saved.contains { $0.name == d.label } }
                if !fresh.isEmpty {
                    Text("TROVATE IN RETE").font(NxFont.label).tracking(1).foregroundStyle(NxColor.textDim)
                    ForEach(fresh) { d in
                        NxButton(d.label, icon: "dot.radiowaves.left.and.right", wide: true) {
                            busy = true
                            Task {
                                if let a = await RemoteClient.resolve(d.endpoint) { connect(a, name: d.label, token: nil) }
                                else { busy = false; message = "Non riesco a raggiungere \(d.label)." }
                            }
                        }
                    }
                }
                Text("OPPURE L'INDIRIZZO DELLA TV").font(NxFont.label).tracking(1).foregroundStyle(NxColor.textDim)
                HStack {
                    TextField("192.168.1.68", text: $manual).keyboardType(.numbersAndPunctuation).textFieldStyle(.roundedBorder).autocorrectionDisabled()
                    NxButton("Collega", kind: .primary) { connect(manual.trimmed, name: "TV", token: nil) }.disabled(manual.trimmed.isEmpty)
                }
            }
            .padding(20)
        }
    }

    private func pairing(_ address: String) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "tv.and.mediabox").font(.system(size: 44)).foregroundStyle(NxColor.textMuted)
            Text("Scrivi il codice che vedi su \(pairingName)").font(NxFont.titleM).foregroundStyle(NxColor.text).multilineTextAlignment(.center)
            TextField("0000", text: $pin).keyboardType(.numberPad).font(NxFont.display(30, .bold)).multilineTextAlignment(.center).frame(maxWidth: 180)
                .padding(10).background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .onChange(of: pin) { _, v in if v.count > 4 { pin = String(v.prefix(4)) } }
            if let m = message { Text(m).font(NxFont.meta).foregroundStyle(NxColor.accentBright) }
            HStack(spacing: 10) {
                NxButton("Annulla", kind: .quiet) { pairingAddress = nil; message = nil }
                NxButton(busy ? "Un momento…" : "Abbina", kind: .primary) {
                    busy = true; message = nil
                    Task {
                        let r = await client.pair(address, pin: pin)
                        busy = false
                        if let tok = r.json["token"].stringOrNil {
                            pairingAddress = nil
                            connect(address, name: pairingName, token: tok)
                        } else { message = r.error ?? "Non riesco ad abbinare la TV." }
                    }
                }.disabled(pin.count != 4 || busy)
            }
        }
        .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func send(_ t: RemoteClient.Tv, _ k: String) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Task { let r = await client.key(t, k); if r.status == 401 { tv = nil; message = "La TV chiede di abbinare di nuovo il telefono." } }
    }

    private func key(_ t: RemoteClient.Tv, _ icon: String, _ k: String, size: CGFloat = 58) -> some View {
        NxIconButton(icon: icon, label: k, size: size) { send(t, k) }
    }

    /// Everything on one screen, without scrolling, on every phone: sizes follow the room there is.
    private func pad(_ t: RemoteClient.Tv) -> some View {
        GeometryReader { g in
            let u = min(g.size.width / 5.4, (g.size.height - 150) / 6.4)
            VStack(spacing: u * 0.26) {
                HStack(spacing: 8) {
                    TextField("Cerca sulla TV", text: $query).textFieldStyle(.roundedBorder).submitLabel(.search).autocorrectionDisabled()
                        .onSubmit { let q = query.trimmed; if !q.isEmpty { Task { await client.search(t, q) }; query = "" } }
                    NxIconButton(icon: "list.bullet", label: "Canali", size: 40) { showChannels = true; Task { channels = await client.channels(t) ?? channels } }
                }
                Spacer(minLength: 0)
                HStack(spacing: u * 0.9) {
                    key(t, "arrow.uturn.backward", "back", size: u * 0.86)
                    NxIconButton(icon: "house.fill", label: "Home", size: u * 0.86) { Task { await client.home(t) } }
                    key(t, "line.3.horizontal", "menu", size: u * 0.86)
                }
                VStack(spacing: u * 0.12) {
                    key(t, "chevron.up", "up", size: u)
                    HStack(spacing: u * 0.12) {
                        key(t, "chevron.left", "left", size: u)
                        Button { send(t, "ok") } label: { Text("OK").font(Font.custom("Sora-Regular_Bold", fixedSize: u * 0.34)).foregroundStyle(NxColor.ink0).frame(width: u * 1.2, height: u * 1.2) }
                            .buttonStyle(.plain).glassEffect(Glass.regular.tint(.white).interactive(), in: Circle())
                        key(t, "chevron.right", "right", size: u)
                    }
                    key(t, "chevron.down", "down", size: u)
                }
                HStack(spacing: u * 0.5) {
                    VStack(spacing: u * 0.12) {
                        if volume {
                            NxIconButton(icon: "speaker.plus.fill", label: "Volume su", size: u * 0.8) { Task { await client.volume(t, "up") } }
                            NxIconButton(icon: "speaker.minus.fill", label: "Volume giù", size: u * 0.8) { Task { await client.volume(t, "down") } }
                        }
                    }
                    key(t, "playpause.fill", "playpause", size: u * 0.95)
                    VStack(spacing: u * 0.12) {
                        key(t, "plus", "chup", size: u * 0.8)
                        key(t, "minus", "chdown", size: u * 0.8)
                    }
                }
                Spacer(minLength: 0)
                Button("Cambia TV") { tv = nil }.font(NxFont.caption).foregroundStyle(NxColor.textDim).buttonStyle(.plain)
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
            .frame(width: g.size.width, height: g.size.height)
        }
    }

    private var channelSheet: some View {
        OptionSheet(title: "Canali sulla TV") {
            if channels.isEmpty { Text("Nessun canale: sulla TV scegli prima un profilo.").font(NxFont.meta).foregroundStyle(NxColor.textDim) }
            ForEach(channels) { c in
                OptionRow(title: (c.num > 0 ? "\(c.num)  " : "") + c.name, sub: c.now, selected: false) {
                    showChannels = false
                    if let t = tv { Task { await client.tune(t, id: c.id) } }
                }
            }
        }
    }
}
#else
struct RemoteView: View {
    var body: some View {
        StateMessage(icon: "appletvremote.gen4", title: "Telecomando dal telefono", text: "Apri NexStream sul telefono, poi Impostazioni e “Telecomando della TV”: questa Apple TV compare da sola. La prima volta mostro qui un codice.")
            .nxPage().nxTitle("Telecomando")
    }
}

/// TV side: while NexStream is open on the Apple TV, a small JSON server on the home network lets a paired phone change
/// channel, search with its keyboard, go Home, pause. (tvOS does not let an app receive made-up remote presses, so the
/// arrows only work inside the players.) Pairing: the phone asks, the TV shows a 4-digit PIN for 2 minutes.
@MainActor
final class RemoteHost: ObservableObject {
    static let shared = RemoteHost()
    struct PairRequest: Equatable { let phone: String; let pin: String; let until: Millis }
    @Published private(set) var pairing: PairRequest? = nil
    private var server: Lan.Server?
    private var wrongPins = 0
    private let d = UserDefaults.standard

    private func tokens() -> [String: String] {
        var out = [String: String]()
        for l in (d.string(forKey: "remote.tokens") ?? "").split(separator: "\n") { let p = l.split(separator: "|", maxSplits: 1).map(String.init); if p.count == 2 { out[p[0]] = p[1] } }
        return out
    }
    private func addToken(_ t: String, _ name: String) {
        var m = tokens().filter { $0.value != name }
        m[t] = name.replacingOccurrences(of: "|", with: " ").replacingOccurrences(of: "\n", with: " ")
        d.set(m.map { "\($0.key)|\($0.value)" }.joined(separator: "\n"), forKey: "remote.tokens")
    }

    func start() {
        if server != nil { return }
        let s = Lan.Server { [weak self] req in await self?.serve(req) ?? .json(410, "{\"ok\":false}") }
        if s.start(ports: [8790, 8791, 8792], bonjour: (Lan.deviceName(), RemoteClient.service)) { server = s; NxLog.i("NxRemote", "remote host on port \(s.port)") }
    }
    func stop() { server?.stop(); server = nil; pairing = nil }

    private func serve(_ r: Lan.Request) async -> Lan.Response {
        let body = J.parse(r.bodyText)
        let authed = r.headers["x-token"].map { tokens()[$0] != nil } ?? false
        let core = NexCore.shared
        switch r.path {
        case "/hello": return .json(200, jsonString(["app": "nexstream", "name": Lan.deviceName(), "paired": authed, "volume": false] as [String: Any]))
        case "/pair/start":
            let now = Clock.now
            if pairing == nil || pairing!.until < now {
                wrongPins = 0
                pairing = PairRequest(phone: body["name"].stringOrNil?.take(40) ?? "Telefono", pin: String(Int.random(in: 1000...9999)), until: now + 120_000)
            }
            return .json(200, "{\"ok\":true}")
        case "/pair":
            guard let p = pairing, p.until >= Clock.now else { return .json(410, "{\"ok\":false,\"error\":\"Il codice è scaduto: riprova.\"}") }
            if body["pin"].stringOrNil != p.pin {
                wrongPins += 1
                if wrongPins >= 5 { pairing = nil }
                return .json(401, "{\"ok\":false,\"error\":\"Codice sbagliato.\"}")
            }
            let t = Lan.token(32, alphabet: "abcdefghijkmnpqrstuvwxyz23456789")
            addToken(t, p.phone); pairing = nil
            return .json(200, jsonString(["ok": true, "token": t, "name": Lan.deviceName()] as [String: Any]))
        default: break
        }
        if !authed { return .json(401, "{\"ok\":false,\"error\":\"Da abbinare\"}") }
        switch r.path {
        case "/key":
            guard let k = body["k"].stringOrNil else { return .json(200, "{\"ok\":false}") }
            NotificationCenter.default.post(name: .nxRemoteKey, object: k)
            return .json(200, "{\"ok\":true}")
        case "/home": NotificationCenter.default.post(name: .nxRemoteKey, object: "home"); return .json(200, "{\"ok\":true}")
        case "/search":
            guard let q = body["q"].stringOrNil?.trimmed, !q.isEmpty else { return .json(200, "{\"ok\":false}") }
            NotificationCenter.default.post(name: .nxRemoteKey, object: "home")
            core.pendingSearch.value = q.take(40)
            return .json(200, "{\"ok\":true}")
        case "/tune":
            var c: ChannelEntity? = nil
            if let id = body["id"].stringOrNil { c = core.channels.get(id) }
            else if let n = body["num"].intOrNil { c = core.channels.visible().first { $0.num == n } }
            guard let ch = c, core.profiles.id > 0 else { return .json(200, "{\"ok\":false}") }
            core.pendingOpen.value = (ch.streamId, core.profiles.id)
            return .json(200, "{\"ok\":true}")
        case "/channels":
            if core.profiles.id <= 0 { return .json(200, "[]") }
            var nowBy = [String: ProgrammeEntity]()
            for p in core.db.programmesAt(Clock.now) { nowBy[p.epgId] = p }
            let list = core.channels.visible().filter { $0.shiftMin == 0 }.prefix(400).map { ch -> [String: Any] in
                var o: [String: Any] = ["id": ch.streamId, "num": ch.num, "name": ch.name, "cat": ch.categoryId]
                if let l = ch.logo ?? ch.icon { o["logo"] = l }
                let p = ch.epgId.flatMap { nowBy[$0] }
                if let n = ch.event ?? p?.title { o["now"] = n }
                if let p = p { o["start"] = p.start; o["stop"] = p.stop }
                return o
            }
            return .json(200, jsonString(Array(list)))
        default: return .json(200, "{\"ok\":false}")
        }
    }
}

/// The PIN a phone has to type to become this TV's remote.
struct RemotePairBanner: View {
    @ObservedObject private var host = RemoteHost.shared
    var body: some View {
        if let p = host.pairing {
            VStack(spacing: 14) {
                Text("\(p.phone) vuole fare da telecomando").font(NxFont.titleM).foregroundStyle(NxColor.text)
                Text(p.pin).font(NxFont.display(44, .heavy)).foregroundStyle(NxColor.text).monospacedDigit().tracking(8)
                Text("Scrivi questo codice sul telefono.").font(NxFont.meta).foregroundStyle(NxColor.textMuted)
            }
            .padding(40).nxGlassPanel()
        }
    }
}
#endif
