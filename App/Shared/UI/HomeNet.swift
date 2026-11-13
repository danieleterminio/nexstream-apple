import SwiftUI
import Network

/// A tiny web server on the home network, alive only while a "dal telefono" panel is on screen.
///
///  - The QR holds `http://<lan ip>:<port>/?t=<one-time token>`: any phone camera opens a page served by this device,
///    where the line credentials are typed with the phone keyboard. No app needed on the phone.
///  - Typing the address by hand works too: the page then asks the 6-digit code shown on screen.
///  - `.receive` is another NexStream asking to copy profiles here: it POSTs JSON to /import with the code, and the
///    service is announced on the network (`_nexstream._tcp`) so it can be found.
///
/// Safety: only private / loopback addresses are served, the token and the code are random and die after 10 minutes,
/// five wrong codes close the server, and it stops as soon as the job is done.
@MainActor
final class LanLink: ObservableObject {
    /// `.profileName`: the TV's profile editor asks the name, typed with the phone keyboard (Android: LanLink.Kind.ProfileName).
    enum Kind { case login, receive, profileName }
    enum Status: Equatable { case waiting, opened, working, done(String), failed(String), expired }

    static let service = "_nexstream._tcp"
    private static let ttl: Millis = 10 * Clock.minute

    let kind: Kind
    @Published private(set) var status: Status = .waiting
    private(set) var host = ""
    private(set) var port: UInt16 = 0
    private(set) var token = ""
    private(set) var code = ""
    private var expiresAt: Millis = 0
    private var server: Lan.Server?
    private var wrongCodes = 0
    private var closed = false
    private var lastUser = ""
    private let onSubmit: ([String: String]) async -> String?

    var address: String { "\(host):\(port)" }
    var url: String { "http://\(host):\(port)/?t=\(token)" }
    var codeLabel: String { String(code.prefix(3)) + " " + String(code.dropFirst(3)) }

    /// `onSubmit` gets the form fields (or `["json": body]` for `.receive`) and returns nil when it went fine, else why not.
    init(kind: Kind, onSubmit: @escaping ([String: String]) async -> String?) {
        self.kind = kind
        self.onSubmit = onSubmit
    }

    /// Opens the server; false when this device has no home-network address.
    func open() -> Bool {
        guard let h = Lan.address() else { return false }
        let s = Lan.Server { [weak self] req in await self?.serve(req) ?? .json(410, "{\"ok\":false}") }
        guard s.start(ports: [8765, 8766, 8767, 8780], bonjour: kind == .receive ? (Lan.deviceName(), LanLink.service) : nil) else { return false }
        server = s; host = h; port = s.port
        token = Lan.token(16); code = String(Int.random(in: 100_000...999_999))
        expiresAt = Clock.now + LanLink.ttl
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(LanLink.ttl) * 1_000_000)
            guard let self = self, !self.closed else { return }
            self.status = .expired; self.close()
        }
        return true
    }

    func close() {
        if closed { return }
        closed = true
        let s = server
        // let the last response go out
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { s?.stop() }
    }
    /// The done state comes from the screen (it knows when the login really went through).
    func finish(_ message: String) { status = .done(message); close() }

    private func codeOk(_ given: String?) -> Bool {
        if (given ?? "").filter({ $0.isNumber }) == code { if status == .waiting { status = .opened }; return true }
        wrongCodes += 1
        if wrongCodes >= 5 { status = .failed("Troppi codici sbagliati"); close() }
        return false
    }

    private func serve(_ r: Lan.Request) async -> Lan.Response {
        let expired = closed || Clock.now > expiresAt
        if r.path == "/favicon.ico" { return Lan.Response(status: 404, type: "text/plain", body: "") }
        if r.path == "/ping" { return .json(200, jsonString(["app": "nexstream", "kind": kind == .login ? "Login" : (kind == .profileName ? "ProfileName" : "Receive"), "name": Lan.deviceName()])) }
        if expired { return .html(410, page("Tempo scaduto", "<p>Questo codice non vale più. Riapri la schermata sulla TV per averne uno nuovo.</p>")) }
        if r.path == "/import" && r.method == "POST" {
            if kind != .receive { return .json(404, "{\"ok\":false}") }
            if !codeOk(r.headers["x-code"]) { return .json(401, "{\"ok\":false,\"error\":\"Codice sbagliato\"}") }
            status = .working
            if let err = await onSubmit(["json": r.bodyText]) { status = .failed(err); return .json(200, jsonString(["ok": false, "error": err] as [String: Any])) }
            return .json(200, "{\"ok\":true}")
        }
        if kind == .receive { return .html(200, page("NexStream", "<p>Questo dispositivo sta aspettando i profili da un'altra app NexStream: usa <b>Invia a un altro dispositivo</b> sull'altra app.</p>")) }
        if r.path == "/code" && r.method == "POST" {
            if codeOk(r.param("code")) { return Lan.Response(status: 302, type: "text/plain", body: "", location: "/?t=\(token)") }
            return .html(200, codePage(closed ? "Troppi tentativi: riapri la schermata sulla TV." : "Codice sbagliato, riprova."))
        }
        if r.path == "/" && r.method == "GET" {
            if r.param("t") != token { return .html(200, codePage(nil)) }
            if status == .waiting { status = .opened }
            return .html(200, formPage(nil))
        }
        if r.path == "/send" && r.method == "POST" {
            if r.param("t") != token { return .html(200, codePage(nil)) }
            var fields = r.form; fields["t"] = nil
            fields = fields.mapValues { $0.trimmed }
            lastUser = fields["username"] ?? fields["name"] ?? ""
            status = .working
            if let err = await onSubmit(fields) { status = .failed(err); return .html(200, formPage(err)) }
            let doneText = kind == .profileName ? "Il nome è arrivato: guarda la TV." : "La linea è collegata: guarda la TV."
            return .html(200, page("Fatto!", "<div class='ok'>✓</div><p>\(doneText)</p><p class='dim'>Puoi chiudere questa pagina.</p>"))
        }
        return .html(404, page("Non trovato", "<p>Pagina non trovata.</p>"))
    }

    private func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#39;")
    }

    private func formPage(_ error: String?) -> String {
        let err = error.map { "<div class='err'>\(esc($0))</div>" } ?? ""
        if kind == .profileName {
            let nameField = """
            <label>Nome del profilo<input name="name" value="\(esc(lastUser))" maxlength="16" autocomplete="off" autocapitalize="words" required autofocus></label>
            <button class="go">Invia alla TV</button>
            """
            return page("Il nome del profilo", "\(err)<form method='post' action='/send'><input type='hidden' name='t' value='\(token)'>\(nameField)</form>")
        }
        let fields = """
        <label>Nome utente<input name="username" value="\(esc(lastUser))" autocomplete="username" autocapitalize="none" autocorrect="off" spellcheck="false" required autofocus></label>
        <label>Password<span class="pw"><input id="pw" name="password" type="password" autocomplete="current-password" autocapitalize="none" autocorrect="off" spellcheck="false" required><button type="button" class="eye" onclick="var p=document.getElementById('pw');p.type=p.type=='password'?'text':'password';this.textContent=p.type=='password'?'Mostra':'Nascondi'">Mostra</button></span></label>
        <p class="dim">L'indirizzo del server è automatico: bastano nome utente e password.</p>
        <button class="go">Accedi sulla TV</button>
        """
        return page("Accedi alla tua linea", "\(err)<form method='post' action='/send' onsubmit=\"this.querySelector('.go').disabled=true;this.querySelector('.go').textContent='Attendi…'\"><input type='hidden' name='t' value='\(token)'>\(fields)</form>")
    }

    private func codePage(_ error: String?) -> String {
        page("Scrivi il codice", (error.map { "<div class='err'>\(esc($0))</div>" } ?? "") + """
        <p>Scrivi il codice di 6 cifre che vedi sulla TV.</p>
        <form method="post" action="/code"><input name="code" inputmode="numeric" pattern="[0-9 ]*" maxlength="7" autocomplete="one-time-code" class="code" required autofocus><button class="go">Continua</button></form>
        """)
    }

    private func page(_ title: String, _ body: String) -> String {
        """
        <!doctype html><html lang="it"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <meta name="color-scheme" content="dark"><title>NexStream · \(esc(title))</title><style>
        *{box-sizing:border-box}body{margin:0;background:#0b0b0d;color:#f5f5f7;font:16px/1.45 system-ui,-apple-system,Roboto,sans-serif;display:flex;justify-content:center}
        main{width:100%;max-width:440px;padding:28px 18px 40px}.brand{display:flex;align-items:center;gap:10px;margin-bottom:22px;font-weight:700;letter-spacing:.02em}
        .logo{width:34px;height:34px;border-radius:9px;background:linear-gradient(135deg,#ff4b3a,#b30f30);display:grid;place-items:center}.logo:after{content:"";border-left:13px solid #fff;border-top:8px solid transparent;border-bottom:8px solid transparent;margin-left:4px}
        h1{font-size:24px;margin:0 0 14px}p{margin:0 0 14px;color:#c9c9cf}.dim{color:#8c8c94;font-size:14px}label{display:block;margin:0 0 14px;font-size:13px;letter-spacing:.06em;text-transform:uppercase;color:#9d9da5}
        input{display:block;width:100%;margin-top:6px;padding:14px;border-radius:12px;border:1px solid #33333a;background:#18181c;color:#fff;font-size:18px;text-transform:none;letter-spacing:0}
        input:focus{outline:2px solid #e5173f;border-color:transparent}.pw{position:relative;display:block}.eye{position:absolute;right:6px;top:12px;padding:8px 10px;border:0;background:#2a2a30;color:#ddd;border-radius:8px;font-size:13px}
        .code{font-size:30px;letter-spacing:.3em;text-align:center}.go{width:100%;padding:15px;margin-top:6px;border:0;border-radius:12px;background:#e5173f;color:#fff;font-size:17px;font-weight:700}.go:disabled{opacity:.6}
        .err{background:#3a1114;border:1px solid #7a1c22;color:#ffb4b8;padding:12px 14px;border-radius:12px;margin-bottom:16px}.ok{width:72px;height:72px;border-radius:50%;background:#1f7a3a;display:grid;place-items:center;font-size:40px;margin:8px 0 18px}
        </style></head><body><main><div class="brand"><span class="logo"></span>NexStream</div><h1>\(esc(title))</h1>\(body)</main></body></html>
        """
    }
}

/// "Copia da un altro dispositivo": profiles with their favourite channels, "Da guardare" and followed teams go from one
/// NexStream to another on the same home network — Android or Apple, the format is the same. Profiles are matched by
/// name: an existing one is merged into, a missing one is created. Nothing is ever deleted.
enum Transfer {
    static func export(_ core: NexCore) -> String {
        var o = Backup.export(core, progress: false)
        o["from"] = Lan.deviceName()
        return jsonString(o)
    }

    /// Merges what another device sent; returns a summary ("2 profili, 14 canali preferiti, 1 squadra") or throws why not.
    static func importJson(_ core: NexCore, _ json: String) async -> (String?, String?) {
        let root = J.parse(json)
        guard root["app"].stringOrNil == "nexstream" else { return (nil, "Dati non validi") }
        var existing = core.profiles.all()
        var nProfiles = 0, nNew = 0, nFav = 0, nList = 0, nTeams = 0
        for o in root["profiles"].array {
            guard let name = o["name"].stringOrNil?.trimmed.take(16), !name.isEmpty else { continue }
            nProfiles += 1
            var pid = existing.first { $0.name.equalsIgnoringCase(name) }?.id ?? 0
            if pid == 0 {
                nNew += 1
                let kids = o["kids"].bool
                var pin = o["pin"].stringOrNil
                if let p = pin, !(p.count == 4 && p.allSatisfy({ $0.isNumber })) { pin = nil }
                pid = core.profiles.add(name: name, color: o["color"].int, kids: kids, icon: o["icon"].int, maturity: o["maturity"].intOrNil ?? (kids ? 0 : 2), pin: pin)
                existing = core.profiles.all()
            }
            let favs = Set(core.db.favoriteIds(pid))
            for f in o["favorites"].array { if let s = f.stringOrNil, !favs.contains(s) { core.db.addFavorite(pid, s); nFav += 1 } }
            for i in o["list"].array {
                guard let id = i["id"].intOrNil, let media = i["media"].stringOrNil else { continue }
                if !core.db.inList(pid, id, media) { core.db.addToList(ListItemEntity(profileId: pid, tmdbId: id, media: media, addedAt: i["at"].int64OrNil ?? Clock.now)); nList += 1 }
            }
            let incoming = o["teams"].array.compactMap { t -> Teams.Team? in
                guard let n = t["n"].stringOrNil, let c = t["c"].stringOrNil else { return nil }
                return Teams.Team(name: n, crest: c)
            }
            nTeams += await core.teams.merge(pid, incoming)
        }
        if nProfiles == 0 { return (nil, "Nessun profilo ricevuto") }
        var parts = [nNew > 0 ? "\(nNew) \(nNew == 1 ? "profilo nuovo" : "profili nuovi")" : "\(nProfiles) \(nProfiles == 1 ? "profilo aggiornato" : "profili aggiornati")"]
        if nFav > 0 { parts.append("\(nFav) \(nFav == 1 ? "canale preferito" : "canali preferiti")") }
        if nList > 0 { parts.append("\(nList) \(nList == 1 ? "titolo" : "titoli") nella lista") }
        if nTeams > 0 { parts.append("\(nTeams) \(nTeams == 1 ? "squadra" : "squadre")") }
        return (parts.joined(separator: ", "), nil)
    }

    /// Sends this device's profiles; nil when it went fine, else the reason.
    static func send(_ core: NexCore, to endpoint: NWEndpoint, code: String) async -> String? {
        let r = await Lan.call(endpoint, "/import", headers: ["X-Code": code.filter { $0.isNumber }], body: export(core), timeout: 20)
        if r.json["ok"].boolOrNil == true { return nil }
        switch r.status {
        case 401: return "Codice sbagliato: controlla quello sull'altro dispositivo."
        case 410: return "Il codice è scaduto: riapri la schermata sull'altro dispositivo."
        case 0: return r.problem ?? "Non riesco a raggiungere l'altro dispositivo. Siete sulla stessa rete? Alcune VPN bloccano la rete di casa."
        default: return r.error ?? "L'altro dispositivo non ha accettato i dati (\(r.status))."
        }
    }
}

/// QR + address + code of a `LanLink`, as shown on the screen that waits.
struct LanLinkPanel: View {
    @ObservedObject var link: LanLink
    let title: String
    let hint: String

    var body: some View {
        HStack(alignment: .center, spacing: Metrics.u(24)) {
            if link.kind != .receive, let img = Lan.qr(link.url) {
                Image(uiImage: img).interpolation(.none).resizable().scaledToFit().frame(width: Metrics.u(170), height: Metrics.u(170))
                    .padding(Metrics.u(10)).background(Color.white, in: RoundedRectangle(cornerRadius: Metrics.u(14), style: .continuous))
            }
            VStack(alignment: .leading, spacing: Metrics.u(10)) {
                Text(title).font(NxFont.titleM).foregroundStyle(NxColor.text)
                Text(hint).font(NxFont.meta).foregroundStyle(NxColor.textMuted)
                VStack(alignment: .leading, spacing: 4) {
                    Text(link.kind != .receive ? "OPPURE APRI NEL BROWSER" : "INDIRIZZO DI QUESTO DISPOSITIVO").font(NxFont.label).tracking(1).foregroundStyle(NxColor.textDim)
                    Text(link.address).font(NxFont.display(18, .semibold)).foregroundStyle(NxColor.text)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("CODICE").font(NxFont.label).tracking(1).foregroundStyle(NxColor.textDim)
                    Text(link.codeLabel).font(NxFont.display(26, .bold)).foregroundStyle(NxColor.text).monospacedDigit()
                }
                statusLine
            }
        }
        .padding(Metrics.u(22))
        .nxPanel()
    }

    @ViewBuilder private var statusLine: some View {
        switch link.status {
        case .waiting: Label("In attesa…", systemImage: "hourglass").font(NxFont.caption).foregroundStyle(NxColor.textDim)
        case .opened: Label("Pagina aperta sul telefono", systemImage: "iphone").font(NxFont.caption).foregroundStyle(NxColor.success)
        case .working: HStack(spacing: 8) { NxSpinner(); Text("Un momento…").font(NxFont.caption).foregroundStyle(NxColor.textMuted) }
        case .done(let m): Label(m, systemImage: "checkmark.circle.fill").font(NxFont.caption).foregroundStyle(NxColor.success)
        case .failed(let m): Label(m, systemImage: "exclamationmark.triangle.fill").font(NxFont.caption).foregroundStyle(NxColor.accentBright)
        case .expired: Label("Codice scaduto: riapri questa schermata.", systemImage: "clock").font(NxFont.caption).foregroundStyle(NxColor.warning)
        }
    }
}

/// Profiles between devices: receive here (this device shows a code) or send from here (pick the device, type its code).
struct TransferView: View {
    @EnvironmentObject var app: AppModel
    @State private var mode = 0
    @State private var link: LanLink? = nil
    @State private var noNetwork = false
    @State private var devices: [Lan.Device] = []
    @State private var finder = Lan.Finder()
    @State private var target: Lan.Device? = nil
    @State private var manual = ""
    @State private var code = ""
    @State private var busy = false
    @State private var result: String? = nil
    @State private var failure: String? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.u(18)) {
                HStack(spacing: Metrics.u(8)) {
                    NxChip(title: "Ricevi qui", icon: "arrow.down", selected: mode == 0) { mode = 0 }
                    NxChip(title: "Invia da qui", icon: "arrow.up", selected: mode == 1) { mode = 1 }
                }
                if mode == 0 { receive } else { send }
            }
            .padding(Metrics.u(20))
            .frame(maxWidth: Metrics.u(760), alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .nxScreen("Profili tra dispositivi")
        .onAppear { openLink(); finder.start(type: LanLink.service) { devices = $0.filter { $0.name != Lan.deviceName() } } }
        .onDisappear { link?.close(); finder.stop() }
    }

    private func openLink() {
        if link != nil { return }
        let core = app.core
        let l = LanLink(kind: .receive) { fields in
            let (summary, err) = await Transfer.importJson(core, fields["json"] ?? "")
            if let s = summary { await MainActor.run { self.link?.finish("Ricevuti: \(s)") } }
            return err
        }
        if l.open() { link = l } else { noNetwork = true }
    }

    @ViewBuilder private var receive: some View {
        Text("Sull'altro dispositivo apri Impostazioni, poi “Invia a un altro dispositivo”, scegli questo e scrivi il codice. Arrivano profili, canali preferiti, la tua lista e le squadre. Qui non viene cancellato nulla.")
            .font(NxFont.meta).foregroundStyle(NxColor.textMuted)
        if let l = link { LanLinkPanel(link: l, title: Lan.deviceName().substringAfter("· "), hint: "Questo dispositivo è pronto a ricevere per 10 minuti.") }
        else if noNetwork { StateMessage(icon: "wifi.slash", title: "Nessuna rete di casa", text: "Collega questo dispositivo al Wi-Fi o al cavo di rete.").frame(height: Metrics.u(220)) }
    }

    @ViewBuilder private var send: some View {
        Text("Sull'altro dispositivo apri “Copia da un altro dispositivo”: compare un codice. Scegli qui sotto il dispositivo (o scrivi il suo indirizzo) e inserisci il codice.")
            .font(NxFont.meta).foregroundStyle(NxColor.textMuted)
        if !devices.isEmpty {
            VStack(alignment: .leading, spacing: Metrics.u(8)) {
                Text("DISPOSITIVI TROVATI").font(NxFont.label).tracking(1).foregroundStyle(NxColor.textDim)
                ForEach(devices) { d in NxChip(title: d.label, icon: "tv", selected: target == d) { target = d; manual = "" } }
            }
        }
        VStack(alignment: .leading, spacing: Metrics.u(6)) {
            Text("OPPURE L'INDIRIZZO").font(NxFont.label).tracking(1).foregroundStyle(NxColor.textDim)
            NxField {
                TextField("", text: $manual, prompt: Text("192.168.1.50:8765").foregroundColor(NxColor.textDim)).autocorrectionDisabled().textInputAutocapitalization(.never)
                    #if os(iOS)
                    .keyboardType(.numbersAndPunctuation)
                    #endif
                    .onChange(of: manual) { _, v in if !v.isEmpty { target = nil } }
            }
        }
        VStack(alignment: .leading, spacing: Metrics.u(6)) {
            Text("CODICE DI 6 CIFRE").font(NxFont.label).tracking(1).foregroundStyle(NxColor.textDim)
            NxField {
                TextField("", text: $code, prompt: Text("000 000").foregroundColor(NxColor.textDim))
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
            }
        }
        if let r = result { Label(r, systemImage: "checkmark.circle.fill").font(NxFont.meta).foregroundStyle(NxColor.success) }
        if let f = failure { Label(f, systemImage: "exclamationmark.triangle.fill").font(NxFont.meta).foregroundStyle(NxColor.accentBright) }
        NxButton(busy ? "Invio…" : "Invia i profili", icon: "paperplane.fill", kind: .primary) { doSend() }
            .disabled(busy || code.filter { $0.isNumber }.count != 6 || (target == nil && manual.trimmed.isEmpty))
    }

    private func doSend() {
        guard let ep = target?.endpoint ?? Lan.endpoint(manual, defaultPort: 8765) else { failure = "Indirizzo non valido."; return }
        busy = true; result = nil; failure = nil
        Task {
            let err = await Transfer.send(app.core, to: ep, code: code)
            busy = false
            if let e = err { failure = e } else { result = "Profili inviati."; code = "" }
        }
    }
}

#if os(tvOS)
/// "Accedi dal telefono" on the Apple TV login: a QR that opens a page where the credentials are typed on the phone.
struct PhoneLoginPanel: View {
    let onClose: () -> Void
    /// "Cambia linea dal telefono" (settings) closes with its own words and goes away once the new line is in.
    var closeLabel = "Scrivi qui con il telecomando"
    var onDone: (() -> Void)? = nil
    @EnvironmentObject var app: AppModel
    @State private var link: LanLink? = nil
    @State private var noNetwork = false

    var body: some View {
        VStack(spacing: 30) {
            if let l = link { LanLinkPanel(link: l, title: "Accedi dal telefono", hint: "Inquadra il codice con la fotocamera del telefono e scrivi lì nome utente e password.") }
            else if noNetwork { StateMessage(icon: "wifi.slash", title: "Nessuna rete di casa", text: "Collega l'Apple TV alla rete e riprova.") }
            NxButton(closeLabel, kind: .quiet, action: onClose)
        }
        .onAppear {
            let core = app.core
            let done = onDone
            let l = LanLink(kind: .login) { fields in
                let u = fields["username"] ?? "", p = fields["password"] ?? ""
                if u.isEmpty || p.isEmpty { return "Scrivi nome utente e password." }
                switch await core.loginRepo.login(username: u, password: p) {
                case .success:
                    core.syncIfNeeded(force: true)
                    if let done = done { Task { @MainActor in try? await Task.sleep(nanoseconds: 1_500_000_000); done() } }
                    return nil
                case .notFound: return "Nome utente non trovato."
                case .authFailed: return "Password sbagliata."
                case .expired: return "La linea è scaduta o sospesa."
                case .error(let m): return m
                }
            }
            if l.open() { link = l } else { noNetwork = true }
        }
        .onDisappear { link?.close() }
    }
}

/// "Scrivilo dal telefono" in the profile editor: a QR to a page where the name is typed with the phone keyboard.
struct PhoneNamePanel: View {
    let onName: (String) -> Void
    let onClose: () -> Void
    @State private var link: LanLink? = nil
    @State private var noNetwork = false

    var body: some View {
        VStack(spacing: 30) {
            if let l = link { LanLinkPanel(link: l, title: "Scrivi il nome dal telefono", hint: "Inquadra il codice con la fotocamera del telefono e scrivi lì il nome del profilo.") }
            else if noNetwork { StateMessage(icon: "wifi.slash", title: "Nessuna rete di casa", text: "Collega l'Apple TV alla rete e riprova.") }
            NxButton("Chiudi", kind: .quiet, action: onClose)
        }
        .onAppear {
            let give = onName
            let l = LanLink(kind: .profileName) { fields in
                let n = String((fields["name"] ?? "").trimmed.prefix(16))
                if n.isEmpty { return "Scrivi un nome" }
                await MainActor.run { give(n.prefix(1).uppercased() + n.dropFirst()) }
                return nil
            }
            if l.open() { link = l } else { noNetwork = true }
        }
        .onDisappear { link?.close() }
    }
}
#endif
