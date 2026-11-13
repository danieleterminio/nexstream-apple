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
/// same point, and turns the phone into its remote.
struct CastPanel: View {
    @EnvironmentObject var app: AppModel
    @State private var saved: [RemoteClient.Tv] = []
    @State private var found: [Lan.Device] = []
    @State private var finder = Lan.Finder()
    @State private var problem: String? = nil
    @State private var busy: String? = nil

    var body: some View {
        let fresh = found.filter { d in !saved.contains { $0.name == d.label } }
        VStack(spacing: 0) {
            ForEach(saved) { t in
                OptionRow(title: t.name, sub: "Abbinata", icon: "tv") { app.cast(to: t.address, name: t.name) }
            }
            ForEach(fresh) { d in
                OptionRow(title: d.label, sub: busy == d.id ? "Mi collego…" : "La prima volta la TV mostra un codice", icon: "dot.radiowaves.left.and.right") {
                    busy = d.id
                    Task {
                        if let a = await RemoteClient.resolve(d.endpoint) { app.cast(to: a, name: d.label) }
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
