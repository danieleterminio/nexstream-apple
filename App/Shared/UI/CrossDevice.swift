import SwiftUI

/// "Stavi guardando su …": what was left half way on another device of the line, as a row on top of Home.
@MainActor
final class OthersWatcher: ObservableObject {
    @Published private(set) var row: HomeRow? = nil
    private var watch: Watch?
    private var pid: Int64 = 0

    func start(pid: Int64) {
        self.pid = pid
        if watch != nil { return }
        watch = onMain(NexCore.shared.sync.others) { [weak self] list in self?.build(list) }
    }

    private func build(_ all: [SyncEngine.Other]) {
        let mine = all.filter { $0.profileId == pid }
        if mine.isEmpty { row = nil; return }
        Task {
            let core = NexCore.shared
            var titles = [TmdbTitle](); var overlays = [String: CardOverlay]()
            for o in mine.prefix(10) {
                guard let e = await core.catalog.ensureTitle(o.tmdbId, o.media) else { continue }
                let t = CatalogRepository.asTmdb(e)
                if overlays[t.key] != nil { continue }
                titles.append(t)
                overlays[t.key] = CardOverlay(progress: o.dur > 0 ? Double(o.pos) / Double(o.dur) : nil, label: (o.media == "tv" ? "S\(o.season) E\(o.episode) · " : "") + o.dev)
            }
            if titles.isEmpty { self.row = nil; return }
            let devs = Set(mine.map { $0.dev })
            let title = devs.count == 1 ? "Stavi guardando su \(devs.first ?? "")" : "Stavi guardando su un altro dispositivo"
            self.row = .vod(id: "other-devices", title: title, row: VodRow(id: "other-devices", title: title, items: titles, kind: .continue), overlays: overlays, sub: nil, tag: nil)
        }
    }
}

#if os(iOS)
/// "Riproduci su…": the TVs of the home that run NexStream. Choosing one starts there what is playing here, from the
/// same point, and turns the phone into its remote. Same flow as Android's CastPanel (PlayerChrome.kt): hello and
/// protocol 2 first, a TV that does not know this phone asks for its code right here, and the player here closes only
/// once the TV said yes.
struct CastPanel: View {
    @EnvironmentObject var app: AppModel
    @State private var client = RemoteClient()
    @State private var saved: [RemoteClient.Tv] = []
    @State private var found: [Lan.Device] = []
    @State private var finder = Lan.Finder()
    @State private var problem: String? = nil
    @State private var busy: String? = nil
    @State private var pairAddress: String? = nil
    @State private var pairName = ""
    @State private var pin = ""

    var body: some View {
        if let a = pairAddress { pairing(a) } else { list }
    }

    private func send(_ tv: RemoteClient.Tv) {
        busy = tv.address; problem = nil
        Task {
            let hello = await client.hello(tv.address, token: tv.token)
            if hello.status == 0 { busy = nil; problem = hello.problem ?? "Non riesco a raggiungere \(tv.name)."; return }
            if (hello.json["v"].intOrNil ?? 1) < 2 { busy = nil; problem = "Aggiorna NexStream su \(tv.name) per usare “Riproduci su…”."; return }
            guard let body = app.castBody() else { busy = nil; problem = "Qui non c'è niente da inviare."; return }
            let r = await client.play(tv, body)
            busy = nil
            if r.status == 200 && r.json["ok"].bool {
                client.remember(tv)
                app.dismissAllSheets()
                app.say("In riproduzione su \(tv.name)")
                app.castSent(to: tv.address, name: tv.name)
            } else if r.status == 401 {
                connect(tv.address, name: tv.name)
            } else { problem = r.error ?? "La TV non ha avviato la riproduzione." }
        }
    }

    private func connect(_ address: String, name: String) {
        busy = address; problem = nil
        Task {
            let s = await client.pairStart(address)
            busy = nil
            if s.ok { pin = ""; pairName = name; pairAddress = address } else { problem = s.problem ?? "Non riesco a raggiungere \(name)." }
        }
    }

    private func sendPin() {
        guard let a = pairAddress, pin.count == 4, busy == nil else { return }
        busy = a; problem = nil
        Task {
            let r = await client.pair(a, pin: pin)
            busy = nil
            if let tok = r.json["token"].stringOrNil {
                let n = r.json["name"].stringOrNil?.substringAfter("· ") ?? pairName
                pairAddress = nil
                send(RemoteClient.Tv(name: n, address: a, token: tok))
            } else { problem = r.error ?? "Non riesco ad abbinare la TV."; pin = "" }
        }
    }

    private func pairing(_ address: String) -> some View {
        VStack(spacing: 14) {
            Text("Scrivi il codice che vedi su \(pairName)").font(NxFont.ui(15, .bold)).foregroundStyle(NxColor.text).multilineTextAlignment(.center)
            TextField("0000", text: $pin).keyboardType(.numberPad).font(NxFont.display(30, .bold)).multilineTextAlignment(.center).frame(maxWidth: 180)
                .foregroundStyle(.white).tint(.white).padding(10).background(NxColor.ink3, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .onChange(of: pin) { _, v in
                    let digits = String(v.filter { $0.isNumber }.prefix(4))
                    if digits != v { pin = digits }
                    if digits.count == 4 { sendPin() }
                }
            if let p = problem { Text(p).font(NxFont.caption).foregroundStyle(NxColor.ember).multilineTextAlignment(.center) }
            HStack(spacing: 10) {
                NxButton("Annulla", kind: .quiet) { pairAddress = nil; problem = nil }
                NxButton(busy != nil ? "Un momento…" : "Abbina", kind: .primary) { sendPin() }.disabled(pin.count != 4 || busy != nil)
            }
        }
        .padding(16).frame(maxWidth: .infinity)
    }

    private var list: some View {
        let fresh = found.filter { d in !saved.contains { $0.name == d.label } }
        return VStack(spacing: 0) {
            ForEach(saved) { t in
                OptionRow(title: t.name, sub: busy == t.address ? "Mi collego…" : "Abbinata", icon: "tv") { if busy == nil { send(t) } }
            }
            ForEach(fresh) { d in
                OptionRow(title: d.label, sub: busy == d.id ? "Mi collego…" : "La prima volta la TV mostra un codice", icon: "dot.radiowaves.left.and.right") {
                    if busy != nil { return }
                    busy = d.id
                    Task {
                        if let a = await RemoteClient.resolve(d.endpoint) { busy = nil; send(RemoteClient.Tv(name: d.label, address: a, token: nil)) }
                        else { busy = nil; problem = "Non riesco a raggiungere \(d.label)." }
                    }
                }
            }
            if saved.isEmpty && fresh.isEmpty {
                VStack(spacing: 10) {
                    NxSpinner()
                    Text("Cerco le TV di casa con NexStream aperto…").font(NxFont.meta).foregroundStyle(NxColor.textMuted).multilineTextAlignment(.center)
                }
                .padding(24)
            }
            if let p = problem { Text(p).font(NxFont.caption).foregroundStyle(NxColor.ember).padding(.horizontal, 16).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading) }
            Text("Apple TV, Fire TV e box Android con NexStream aperto, sulla stessa rete. Per le altre TV usa AirPlay.")
                .font(NxFont.caption).foregroundStyle(NxColor.textDim).padding(.horizontal, 16).padding(.top, 10).frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            saved = RemoteClient().saved()
            finder.start(type: RemoteClient.service, onProblem: { p in if let p = p { problem = p } }) { found = $0 }
        }
        .onDisappear { finder.stop() }
    }
}

extension AppModel {
    func presentCast() { present("Riproduci su…") { CastPanel() } }
}
#endif
