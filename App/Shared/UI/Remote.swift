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
    /// Tunes by channel number, as typed on a real remote.
    @discardableResult func tune(_ tv: Tv, num: Int) async -> Lan.Reply { await call(tv.address, "/tune", token: tv.token, body: ["num": num]) }
    /// What a TV is playing (remote protocol 2).
    struct TvState: Equatable {
        var playing = false
        var kind = ""
        var title = ""
        var sub = ""
        var art: String? = nil
        var pos: Millis = 0
        var dur: Millis = 0
        var paused = false
        var id = ""
        var media = ""
        var tmdb = 0
        var season = 0
        var episode = 0
    }
    /// "Riproduci su…": starts a channel or a title on the TV.
    func play(_ tv: Tv, _ body: [String: Any]) async -> Lan.Reply { await call(tv.address, "/play", token: tv.token, body: body) }
    func state(_ tv: Tv) async -> TvState? {
        let r = await call(tv.address, "/state", token: tv.token, body: [:])
        if r.status != 200 { return nil }
        let j = r.json
        return TvState(playing: j["playing"].bool, kind: j["kind"].string, title: j["title"].string, sub: j["sub"].string, art: j["art"].stringOrNil?.nilIfBlank,
                       pos: j["pos"].int64OrNil ?? 0, dur: j["dur"].int64OrNil ?? 0, paused: j["paused"].bool, id: j["id"].string, media: j["media"].string,
                       tmdb: j["tmdb"].int, season: j["season"].int, episode: j["episode"].int)
    }
    @discardableResult func seek(_ tv: Tv, to pos: Millis) async -> Lan.Reply { await call(tv.address, "/seek", token: tv.token, body: ["pos": pos]) }
    @discardableResult func seek(_ tv: Tv, by delta: Millis) async -> Lan.Reply { await call(tv.address, "/seek", token: tv.token, body: ["by": delta]) }
    @discardableResult func stop(_ tv: Tv) async -> Lan.Reply { await call(tv.address, "/stop", token: tv.token, body: [:]) }

    func channels(_ tv: Tv) async -> [Channel]? {
        let r = await call(tv.address, "/channels", token: tv.token, body: [:])
        if r.status != 200 { return nil }
        return J.parse(r.text).array.compactMap { o in
            guard let id = o["id"].stringOrNil else { return nil }
            return Channel(id: id, num: o["num"].int, name: o["name"].string, logo: o["logo"].stringOrNil, now: o["now"].stringOrNil, cat: o["cat"].string)
        }
    }

    /// The IPv4 address ("host:port") behind a service found by Bonjour. IPv4 on purpose: Android announces IPv6
    /// addresses too and the system likes them better, but what is kept and typed here is "a.b.c.d:port". First on the
    /// home network only (never a VPN tunnel), then the way the system prefers.
    static func resolve(_ endpoint: NWEndpoint) async -> String? {
        if let a = await resolve(endpoint, bound: true) { return a }
        return await resolve(endpoint, bound: false)
    }

    private static func resolve(_ endpoint: NWEndpoint, bound: Bool) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            let params = Lan.parameters(bound: bound)
            // also without the home-network binding an IPv6 address is of no use here
            if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
            let c = NWConnection(to: endpoint, using: params)
            let q = DispatchQueue(label: "nx.remote.resolve")
            var done = false
            func finish(_ v: String?) { if !done { done = true; c.stateUpdateHandler = nil; c.cancel(); cont.resume(returning: v) } }
            c.stateUpdateHandler = { st in
                switch st {
                case .ready:
                    if case .hostPort(let host, let port)? = c.currentPath?.remoteEndpoint {
                        var h = "\(host)"
                        if let pct = h.firstIndex(of: "%") { h = String(h[..<pct]) }
                        if h.lowercased().hasPrefix("::ffff:") { h = String(h.dropFirst(7)) }
                        finish(h.contains(":") || h.isEmpty ? nil : "\(h):\(port.rawValue)")
                    } else { finish(nil) }
                case .waiting(let err):
                    // keep waiting: the path may still come up; only a refused permission is final
                    NxLog.i("NxRemote", "resolve waiting (\(bound ? "home network" : "default")): \(err)")
                    if c.currentPath?.unsatisfiedReason == .localNetworkDenied { finish(nil) }
                case .failed(let err):
                    NxLog.i("NxRemote", "resolve failed (\(bound ? "home network" : "default")): \(err)")
                    finish(nil)
                case .cancelled: finish(nil)
                default: break
                }
            }
            c.start(queue: q)
            q.asyncAfter(deadline: .now() + 3.5) { finish(nil) }
        }
    }
}

#if os(iOS)
/// The phone as the TV's remote: pick the TV (found on the network or by address), pair once with the PIN it shows, then
/// arrows, OK, back, volume, channels and search with the phone keyboard — all on one screen.
struct RemoteView: View {
    /// Opened from the VPN gate: no stack of pages behind it, a "Chiudi" takes it away.
    var onClose: (() -> Void)? = nil
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
    @State private var query = ""
    @State private var retried = false
    @State private var version = 1
    @State private var now = RemoteClient.TvState()
    @State private var scrub: Millis? = nil
    /// A paired TV that did not answer: "non risponde", Riprova, Cambia TV (Android: RemoteScreen reachable == false).
    @State private var unreachable: RemoteClient.Tv? = nil

    var body: some View {
        Group {
            if let t = tv { pad(t) }
            else if let u = unreachable { notAnswering(u) }
            else if let a = pairingAddress { pairing(a) }
            else { picker }
        }
        .nxScreen(tv?.name ?? "Telecomando", back: onClose == nil) {
            if let close = onClose { NxButton("Chiudi", kind: .quiet, action: close) }
        }
        .onAppear {
            saved = client.saved()
            finder.start(type: RemoteClient.service, onProblem: { p in if let p = p { message = p } }) { found = $0 }
            if tv == nil {
                if let target = app.remoteTarget {
                    app.remoteTarget = nil
                    connect(target.address, name: target.name, token: saved.first { $0.address == target.address }?.token)
                } else if let last = saved.first { connect(last.address, name: last.name, token: last.token) }
            }
        }
        .onDisappear { finder.stop() }
        .task { await debugPairing() }
        .task(id: tv?.address ?? "") {
            // what the TV is playing, while this screen is open
            guard let t = tv, version >= 2 else { return }
            while !Task.isCancelled {
                if scrub == nil, let st = await client.state(t) { now = st }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func connect(_ address: String, name: String, token: String?) {
        busy = true; message = nil
        Task {
            let r = await client.hello(address, token: token)
            busy = false
            if r.status == 0 {
                // a remembered TV may have changed address: look for it again by name
                if token != nil, !retried, let d = found.first(where: { $0.label == name }), let fresh = await RemoteClient.resolve(d.endpoint), fresh != address {
                    retried = true
                    client.forget(address)
                    connect(fresh, name: name, token: token)
                    return
                }
                if let tok = token, r.problem == nil { unreachable = RemoteClient.Tv(name: name, address: address, token: tok); return }
                message = r.problem ?? "Non trovo la TV a \(address). NexStream deve essere aperto sulla TV, sulla stessa rete."
                return
            }
            retried = false
            unreachable = nil
            let tvName = r.json["name"].stringOrNil?.substringAfter("· ") ?? name
            volume = r.json["volume"].bool
            version = r.json["v"].intOrNil ?? 1
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

    private func notAnswering(_ u: RemoteClient.Tv) -> some View {
        VStack(spacing: 14) {
            StateMessage(icon: "appletvremote.gen4", title: "\(u.name) non risponde",
                         text: "Accendi la TV e apri NexStream: il telecomando funziona solo mentre l'app è aperta, sulla stessa rete di casa.",
                         actionTitle: busy ? "Un momento…" : "Riprova") {
                if !busy { retried = false; connect(u.address, name: u.name, token: u.token) }
            }
            .frame(maxHeight: .infinity)
            NxButton("Cambia TV", kind: .quiet) { unreachable = nil }.padding(.bottom, 16)
        }
    }

    private var picker: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Apri NexStream sulla TV: compare qui sotto. La prima volta la TV mostra un codice da scrivere sul telefono. Se sul telefono è accesa la VPN, consenti la rete locale nella VPN (in NordVPN: “Accesso alla rete locale”).").font(NxFont.meta).foregroundStyle(NxColor.textMuted)
                if busy { HStack(spacing: 8) { NxSpinner(); Text("Mi collego…").font(NxFont.meta).foregroundStyle(NxColor.textMuted) } }
                if let m = message { Label(m, systemImage: "exclamationmark.triangle.fill").font(NxFont.meta).foregroundStyle(NxColor.accentBright) }
                if !saved.isEmpty {
                    Text("LE TUE TV").font(NxFont.label).tracking(1).foregroundStyle(NxColor.textDim)
                    ForEach(saved) { t in
                        HStack {
                            NxButton(t.name, icon: "tv", wide: true) { connect(t.address, name: t.name, token: t.token) }
                            BarIcon(icon: "trash", label: "Dimentica") { client.forget(t.address); saved = client.saved() }
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
                    NxField { TextField("", text: $manual, prompt: Text("192.168.1.68").foregroundColor(NxColor.textDim)).keyboardType(.numbersAndPunctuation).autocorrectionDisabled() }
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
                .foregroundStyle(.white).tint(.white).padding(10).background(NxColor.ink3, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .onChange(of: pin) { _, v in
                    let digits = String(v.filter { $0.isNumber }.prefix(4))
                    if digits != v { pin = digits }
                    // four digits are the whole code: no need to press "Abbina"
                    if digits.count == 4 && !busy { pair(address) }
                }
            if let m = message { Text(m).font(NxFont.meta).foregroundStyle(NxColor.accentBright) }
            HStack(spacing: 10) {
                NxButton("Annulla", kind: .quiet) { pairingAddress = nil; message = nil }
                NxButton(busy ? "Un momento…" : "Abbina", kind: .primary) { pair(address) }.disabled(pin.count != 4 || busy)
            }
        }
        .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func pair(_ address: String) {
        busy = true; message = nil
        Task {
            let r = await client.pair(address, pin: pin)
            busy = false
            NxLog.i("NxRemote", "pair \(address): \(r.status)")
            if let tok = r.json["token"].stringOrNil {
                pairingAddress = nil
                connect(address, name: pairingName, token: tok)
            } else { message = r.error ?? "Non riesco ad abbinare la TV." }
        }
    }

    /// Build pipeline (-nxRemotePin <pin>, the TV started with -nxFixedPin): finds the TV by Bonjour (else this machine),
    /// pairs, sends a few keys — the whole remote path, with the VPN off on both sides.
    private func debugPairing() async {
        guard Demo.enabled, let code = Demo.value("-nxRemotePin") else { return }
        var address: String? = nil
        var name = "TV"
        for _ in 0..<20 {
            if let d = found.first { name = d.label; address = await RemoteClient.resolve(d.endpoint); break }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        NxLog.i("NxDebug", "remote test: found \(found.map { $0.label }) -> \(address ?? "none")")
        connect(address ?? "127.0.0.1:\(RemoteClient.defaultPort)", name: name, token: nil)
        for _ in 0..<15 where pairingAddress == nil { try? await Task.sleep(nanoseconds: 1_000_000_000) }
        guard let a = pairingAddress else { NxLog.i("NxDebug", "remote test: no pairing step (\(message ?? "-"))"); return }
        try? await Task.sleep(nanoseconds: 8_000_000_000)   // time for the TV's code to be on screen
        _ = a
        pin = code   // four digits: the field sends them by itself
        for _ in 0..<15 where tv == nil { try? await Task.sleep(nanoseconds: 1_000_000_000) }
        guard let t = tv else { NxLog.i("NxDebug", "remote test: not paired (\(message ?? "-"))"); return }
        for k in ["down", "ok", "playpause"] {
            let r = await client.key(t, k)
            NxLog.i("NxDebug", "remote test: key \(k) -> \(r.status) \(r.text)")
        }
        let st = await client.state(t)
        let count = await client.channels(t)?.count ?? -1
        NxLog.i("NxDebug", "remote test: state \(st.map { "playing=\($0.playing)" } ?? "none"), channels \(count)")
    }

    private func send(_ t: RemoteClient.Tv, _ k: String) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Task {
            let r = await client.key(t, k)
            if r.status == 401 { tv = nil; message = "La TV chiede di abbinare di nuovo il telefono." }
            else if r.status == 0 { app.say("La TV non risponde") }
            else if !r.ok { app.say(r.error ?? "Comando non riuscito") }
        }
    }

    /// What the TV is playing: artwork, title, the bar that moves it, pause and the ten-second jumps.
    @ViewBuilder private func nowPlaying(_ t: RemoteClient.Tv) -> some View {
        if version >= 2 && now.playing {
            VStack(spacing: 8) {
                HStack(spacing: 12) {
                    NxImage(url: now.art, maxPixel: 400) { ZStack { NxColor.ink3; Image(systemName: now.kind == "live" ? "play.tv" : "film").foregroundStyle(NxColor.textDim) } }
                        .frame(width: 96, height: 54).clipShape(RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(now.title).font(NxFont.ui(15, .bold)).foregroundStyle(.white).lineLimit(1)
                        Text(now.sub).font(NxFont.caption).foregroundStyle(NxColor.textMuted).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    // carrying on here needs this phone able to play: the VPN on and a profile chosen (never from the gate)
                    if app.vpn && app.profile != nil { NxButton("Riprendi qui", icon: "iphone") { resumeHere(t) } }
                }
                if now.kind == "vod" && now.dur > 0 {
                    HStack(spacing: 8) {
                        Text(playerClock(scrub ?? now.pos)).font(NxFont.ui(11, .bold)).foregroundStyle(.white).monospacedDigit()
                        Scrubber(position: scrub ?? now.pos, duration: now.dur, onScrub: { scrub = $0 }, onEnd: {
                            if let target = scrub { now.pos = target; Task { await client.seek(t, to: target); scrub = nil } }
                        })
                        Text("-" + playerClock(now.dur - (scrub ?? now.pos))).font(NxFont.ui(11, .bold)).foregroundStyle(NxColor.textMuted).monospacedDigit()
                    }
                } else if now.dur > 0 {
                    NxProgressBar(value: Double(now.pos) / Double(now.dur))
                }
            }
            .padding(12)
            .background(NxColor.ink2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    /// Stops the TV and carries on here, from where the TV was.
    private func resumeHere(_ t: RemoteClient.Tv) {
        let st = now
        Task {
            await client.stop(t)
            if st.kind == "live", let c = app.core.channels.get(st.id) { app.play(c) }
            else if st.kind == "vod", let d = try? await app.core.catalog.details(st.media, st.tmdb) {
                app.play(PlayRequest(details: d, season: st.season, episode: st.episode, startMs: st.pos))
            }
        }
    }

    /// Everything on one screen, without scrolling, on every phone: sizes follow the room there is.
    private func pad(_ t: RemoteClient.Tv) -> some View {
        GeometryReader { g in
            let top: CGFloat = (version >= 2 && now.playing) ? 250 : 150
            let u = min(g.size.width / 5.4, (g.size.height - top) / 6.0)
            VStack(spacing: u * 0.22) {
                nowPlaying(t)
                HStack(spacing: 8) {
                    NxField(icon: "magnifyingglass") {
                        TextField("", text: $query, prompt: Text("Cerca sulla TV").foregroundColor(NxColor.textDim)).submitLabel(.search).autocorrectionDisabled()
                            .onSubmit { let q = query.trimmed; if !q.isEmpty { Task { await client.search(t, q) }; query = "" } }
                    }
                    NxButton("Canali", icon: "list.bullet") { showChannelList(t) }
                }
                Spacer(minLength: 0)
                VStack(spacing: u * 0.12) {
                    key(t, "chevron.up", "up", size: u)
                    HStack(spacing: u * 0.12) {
                        key(t, "chevron.left", "left", size: u)
                        Button { send(t, "ok") } label: {
                            Text("OK").font(Font.custom("Sora-Regular_Bold", fixedSize: u * 0.34)).foregroundStyle(Color.black).frame(width: u * 1.2, height: u * 1.2).background(Color.white, in: Circle())
                        }
                        .buttonStyle(NxPlainStyle(scale: 0.92))
                        key(t, "chevron.right", "right", size: u)
                    }
                    key(t, "chevron.down", "down", size: u)
                }
                HStack(spacing: u * 0.7) {
                    labelled("Indietro") { key(t, "arrow.uturn.backward", "back", size: u * 0.82) }
                    labelled("Home") { round("house.fill", "Home", u * 0.82) { Task { await client.home(t) } } }
                    labelled("Menu") { key(t, "line.3.horizontal", "menu", size: u * 0.82) }
                }
                HStack(spacing: u * 0.5) {
                    if volume {
                        pill(u, "speaker.minus.fill", "speaker.plus.fill", "Volume", { Task { await client.volume(t, "down") } }, { Task { await client.volume(t, "up") } })
                    }
                    if version >= 2 && now.playing && now.kind == "vod" {
                        round("gobackward.10", "Indietro 10 secondi", u * 0.82) { Task { await client.seek(t, by: -10_000) } }
                    }
                    key(t, now.playing && now.paused ? "play.fill" : "playpause.fill", "playpause", size: u * 0.95)
                    if version >= 2 && now.playing && now.kind == "vod" {
                        round("goforward.10", "Avanti 10 secondi", u * 0.82) { Task { await client.seek(t, by: 10_000) } }
                    }
                    pill(u, "minus", "plus", "Canale", { send(t, "chdown") }, { send(t, "chup") })
                }
                Spacer(minLength: 0)
                NxButton("Cambia TV", kind: .quiet) { tv = nil }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .frame(width: g.size.width, height: g.size.height)
        }
    }

    private func labelled<C: View>(_ text: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 4) { content(); Text(text).font(NxFont.ui(10, .semibold)).foregroundStyle(NxColor.textDim) }
    }

    /// Two keys in one capsule with their name under it (volume, channel).
    private func pill(_ u: CGFloat, _ minus: String, _ plus: String, _ label: String, _ down: @escaping () -> Void, _ up: @escaping () -> Void) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 0) {
                Button(action: { UIImpactFeedbackGenerator(style: .light).impactOccurred(); down() }) {
                    Image(systemName: minus).font(.system(size: u * 0.26, weight: .bold)).foregroundStyle(.white).frame(width: u * 0.74, height: u * 0.72).contentShape(Rectangle())
                }
                .buttonStyle(NxPlainStyle(scale: 0.9))
                Rectangle().fill(NxColor.ink5).frame(width: 1, height: u * 0.36)
                Button(action: { UIImpactFeedbackGenerator(style: .light).impactOccurred(); up() }) {
                    Image(systemName: plus).font(.system(size: u * 0.26, weight: .bold)).foregroundStyle(.white).frame(width: u * 0.74, height: u * 0.72).contentShape(Rectangle())
                }
                .buttonStyle(NxPlainStyle(scale: 0.9))
            }
            .background(NxColor.ink3, in: Capsule())
            Text(label).font(NxFont.ui(10, .semibold)).foregroundStyle(NxColor.textDim)
        }
    }

    private func showChannelList(_ t: RemoteClient.Tv) {
        let client = self.client
        app.present("Canali sulla TV") {
            RemoteChannelSheet(client: client, tv: t)
        }
    }

    private func round(_ icon: String, _ label: String, _ size: CGFloat, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: size * 0.38, weight: .semibold)).foregroundStyle(.white)
                .frame(width: size, height: size).background(NxColor.ink3, in: Circle())
        }
        .buttonStyle(NxPlainStyle(scale: 0.9))
        .accessibilityLabel(label)
    }

    private func key(_ t: RemoteClient.Tv, _ icon: String, _ k: String, size: CGFloat = 58) -> some View {
        round(icon, k, size) { send(t, k) }
    }
}
/// "Canali sulla TV": the TV's own list with what is on now; a tap tunes the TV. The filter also takes a channel number
/// (submit = tune that number, like typing it on a real remote). Android: RemoteScreen ChannelSheet.
struct RemoteChannelSheet: View {
    let client: RemoteClient
    let tv: RemoteClient.Tv
    @EnvironmentObject var app: AppModel
    @State private var list: [RemoteClient.Channel]? = nil
    @State private var failed = false
    @State private var filter = ""

    var body: some View {
        VStack(spacing: 8) {
            NxField(icon: "magnifyingglass") {
                TextField("", text: $filter, prompt: Text("Cerca un canale o scrivi il numero").foregroundColor(NxColor.textDim))
                    .autocorrectionDisabled().submitLabel(.go)
                    .onSubmit {
                        guard let n = Int(filter.trimmed) else { return }
                        app.dismissSheet()
                        Task { await tuned(await client.tune(tv, num: n)) }
                    }
            }
            .padding(.horizontal, 16)
            if failed {
                StateMessage(icon: "tv", title: "Non riesco a leggere i canali dalla TV.", actionTitle: "Riprova") { Task { await load() } }.frame(height: 220)
            } else if let l = list {
                if l.isEmpty { Text("Nessun canale: sulla TV scegli prima un profilo.").font(NxFont.meta).foregroundStyle(NxColor.textDim).padding(20) }
                let q = filter.trimmed.lowercased()
                let shown = q.isEmpty ? l : l.filter { $0.name.lowercased().contains(q) || ($0.now?.lowercased().contains(q) ?? false) || String($0.num) == q }
                LazyVStack(spacing: 0) {
                    ForEach(shown) { c in
                        OptionRow(title: (c.num > 0 ? "\(c.num)  " : "") + c.name, sub: c.now) {
                            app.dismissSheet()
                            Task { await tuned(await client.tune(tv, id: c.id)) }
                        }
                    }
                }
            } else {
                NxSpinner().frame(height: 160)
            }
        }
        .task { await load() }
    }

    private func load() async {
        failed = false
        if let l = await client.channels(tv) { list = l } else { failed = true }
    }

    @MainActor private func tuned(_ r: Lan.Reply) {
        if r.status == 0 { app.say("La TV non risponde") } else if !r.ok { app.say(r.error ?? "Canale non trovato sulla TV") }
    }
}
#else
/// "Telecomando dal telefono" (Apple TV settings): how to pair a phone, this TV's address, the phones paired, unpair.
/// Android: SettingsScreen "Telecomando dal telefono" + RemoteHost.unpairAll.
struct RemoteView: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject private var host = RemoteHost.shared
    @State private var address: String? = nil

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: Metrics.u(18)) {
                Text("Sul telefono apri NexStream, poi Il mio spazio › Impostazioni › “Telecomando della TV”: questa Apple TV compare da sola. La prima volta qui compare un codice da scrivere sul telefono. Funziona anche senza VPN, sulla rete di casa.")
                    .font(NxFont.meta).foregroundStyle(NxColor.textMuted)
                VStack(alignment: .leading, spacing: Metrics.u(4)) {
                    Text("INDIRIZZO DI QUESTA APPLE TV").font(NxFont.label).tracking(1).foregroundStyle(NxColor.textDim)
                    Text(address.map { "\($0):\(host.port)" } ?? "Nessuna rete di casa").font(NxFont.display(20, .semibold)).foregroundStyle(NxColor.text)
                }
                VStack(alignment: .leading, spacing: Metrics.u(8)) {
                    Text("TELEFONI ABBINATI").font(NxFont.label).tracking(1).foregroundStyle(NxColor.textDim)
                    if host.pairedPhones.isEmpty {
                        Text("Nessun telefono abbinato.").font(NxFont.meta).foregroundStyle(NxColor.textDim)
                    } else {
                        ForEach(host.pairedPhones, id: \.self) { n in
                            Label(n, systemImage: "iphone").font(NxFont.ui(15, .bold)).foregroundStyle(NxColor.text)
                        }
                        NxButton("Scollega i telefoni", icon: "xmark.circle", kind: .danger) {
                            app.confirm("Scollegare i telefoni?", message: "Per usarli di nuovo come telecomando andranno abbinati un'altra volta.", confirm: "Scollega", destructive: true) {
                                host.unpairAll(); app.say("Telefoni scollegati")
                            }
                        }
                        .padding(.top, Metrics.u(6))
                    }
                }
            }
            .padding(Metrics.u(20))
            .frame(maxWidth: Metrics.u(760), alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .focusSection()
        }
        .nxScreen("Telecomando dal telefono")
        .onAppear { address = Lan.address() }
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
    /// Names of the phones that may send commands (Android: RemoteHost.pairedPhones).
    @Published private(set) var pairedPhones: [String] = []
    var port: UInt16 { server?.port ?? 8790 }
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
        pairedPhones = m.values.sorted()
    }
    /// Forgets every paired phone: they have to pair again.
    func unpairAll() { d.removeObject(forKey: "remote.tokens"); pairedPhones = [] }

    func start() {
        pairedPhones = tokens().values.sorted()
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
        case "/hello": return .json(200, jsonString(["app": "nexstream", "name": Lan.deviceName(), "paired": authed, "volume": false, "v": 2, "platform": "tvos"] as [String: Any]))
        case "/pair/start":
            let now = Clock.now
            if pairing == nil || pairing!.until < now {
                wrongPins = 0
                // -nxFixedPin: the build pipeline pairs a simulated phone with this TV without reading the screen
                let pin = Demo.enabled ? (Demo.value("-nxFixedPin") ?? String(Int.random(in: 1000...9999))) : String(Int.random(in: 1000...9999))
                pairing = PairRequest(phone: body["name"].stringOrNil?.take(40) ?? "Telefono", pin: pin, until: now + 120_000)
                NxLog.i("NxRemote", "pairing asked by \(pairing?.phone ?? "?")")
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
            NxLog.i("NxRemote", "paired \(p.phone)")
            return .json(200, jsonString(["ok": true, "token": t, "name": Lan.deviceName()] as [String: Any]))
        default: break
        }
        if !authed { return .json(401, "{\"ok\":false,\"error\":\"Da abbinare\"}") }
        switch r.path {
        case "/key":
            guard let k = body["k"].stringOrNil else { return .json(200, "{\"ok\":false}") }
            NxLog.i("NxRemote", "key \(k)")
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
        case "/play":
            let app = AppModel.shared
            // the TV must be able to play it: nothing streams without the VPN (same answer as Android's RemoteHost)
            if !Vpn.shared.active.value { return .json(200, "{\"ok\":false,\"error\":\"Attiva la VPN sulla TV\"}") }
            if let u = body["profile"].stringOrNil, let pid = core.sync.profileId(uuid: u), pid != core.profiles.id, let p = core.db.profile(pid), p.pin == nil { core.profiles.select(p) }
            if core.profiles.id <= 0 { app.autoSelectProfile() }
            guard core.profiles.id > 0 else { return .json(200, "{\"ok\":false,\"error\":\"Scegli un profilo sulla TV\"}") }
            if body["kind"].string == "live" {
                guard let ch = body["id"].stringOrNil.flatMap({ core.channels.get($0) }) else { return .json(200, "{\"ok\":false,\"error\":\"Canale non trovato sulla TV\"}") }
                core.pendingOpen.value = (ch.streamId, core.profiles.id)
                return .json(200, "{\"ok\":true}")
            }
            let media = body["media"].string, tmdb = body["tmdb"].int
            guard media == "movie" || media == "tv", tmdb > 0 else { return .json(200, "{\"ok\":false}") }
            let tvShow = media == "tv"
            let season = tvShow ? max(1, body["season"].int) : 0, episode = tvShow ? max(1, body["episode"].int) : 0, pos = max(0, body["pos"].int64OrNil ?? 0)
            Task { @MainActor in
                guard let d = try? await core.catalog.details(media, tmdb) else { app.say("Non riesco a caricare il titolo inviato dal telefono."); return }
                // the episode's name, for the player's title (Android: RemoteHost.play)
                var name: String? = nil
                if tvShow { name = (try? await core.catalog.season(tmdb, season))?.episodes?.first { $0.episodeNumber == episode }?.name }
                app.play(PlayRequest(details: d, season: season, episode: episode, episodeTitle: name, startMs: pos))
            }
            return .json(200, "{\"ok\":true}")
        case "/state":
            let app = AppModel.shared
            if let m = app.live, let c = m.channel {
                let s = m.showing
                var o: [String: Any] = ["ok": true, "playing": true, "kind": "live", "id": c.streamId, "title": (m.now != nil || c.event != nil) ? (s?.cardTitle ?? c.name) : c.name, "sub": c.name, "paused": m.paused]
                if let a = Img.card(s?.image) ?? c.icon { o["art"] = a }
                if let st = s?.start, let en = s?.stop, en > st { o["pos"] = max(0, Clock.now - st); o["dur"] = en - st }
                return .json(200, jsonString(o))
            }
            if let m = app.vod {
                let d = m.details
                var o: [String: Any] = ["ok": true, "playing": true, "kind": "vod", "title": d.displayTitle, "sub": m.subtitle, "pos": m.position, "dur": m.duration, "paused": m.paused,
                                        "media": d.media, "tmdb": d.id, "season": m.request.season, "episode": m.request.episode]
                if let a = Img.tmdb(d.bestBackdrop ?? d.backdropPath ?? d.posterPath, "w780") { o["art"] = a }
                return .json(200, jsonString(o))
            }
            return .json(200, "{\"ok\":true,\"playing\":false}")
        case "/seek":
            guard let m = AppModel.shared.vod else { return .json(200, "{\"ok\":false}") }
            if let p = body["pos"].int64OrNil { m.seekTarget = max(0, p); m.applySeek() }
            else if let by = body["by"].int64OrNil { m.seekBy(by); m.applySeek() }
            return .json(200, "{\"ok\":true}")
        case "/stop":
            AppModel.shared.closePlayer()
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
            .padding(40).nxPanel(fill: NxColor.ink3)
        }
    }
}
#endif
