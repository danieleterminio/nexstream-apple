import SwiftUI

/// Follows the downloads table (and why the queue waits) for the views that show it.
@MainActor
final class DownloadsWatcher: ObservableObject {
    static let shared = DownloadsWatcher()
    @Published private(set) var items: [DownloadEntity] = []
    @Published private(set) var blocked: Downloads.Block? = nil
    private var watches = [Watch]()
    private init() {
        items = NexCore.shared.downloads.all()
        watches.append(NexCore.shared.db.changes.observe { [weak self] t in
            if t == "downloads" { DispatchQueue.main.async { self?.items = NexCore.shared.downloads.all() } }
        })
        watches.append(onMain(NexCore.shared.downloads.blocked) { [weak self] b in self?.blocked = b })
    }
    func item(_ id: String) -> DownloadEntity? { items.first { $0.id == id } }
}

/// "Download": what is saved on this device, what is coming, how much room it takes, and the options for the next
/// ones. It opens without VPN and without network (also from the "Accendi la VPN" screen); a finished title plays at once.
struct DownloadsView: View {
    /// Opened from the VPN gate: there is no stack of pages behind it.
    var offline = false
    @EnvironmentObject var app: AppModel
    @ObservedObject private var watcher = DownloadsWatcher.shared
    @State private var wifiOnly = NexCore.shared.downloads.wifiOnly
    @State private var quality = NexCore.shared.downloads.quality

    private var dl: Downloads { app.core.downloads }

    var body: some View {
        let items = watcher.items
        let space = dl.space()
        VStack(spacing: 0) {
            NxTopBar(title: "Download", back: !offline, large: offline) {
                if offline { NxButton("Chiudi", kind: .quiet) { app.offlineDownloads = false } }
            }
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    if let why = why(items) {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "pause.circle.fill").font(.system(size: 16, weight: .semibold)).foregroundStyle(NxColor.warning)
                            Text(why).font(NxFont.meta).foregroundStyle(NxColor.warning).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(12)
                        .background(NxColor.ink2, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .padding(.horizontal, Metrics.gutter).padding(.vertical, 6)
                    }
                    if items.isEmpty {
                        StateMessage(icon: "arrow.down.to.line", title: "Nessun download", text: "Nella pagina di un film o di un episodio tocca la freccia per salvarlo su questo dispositivo.")
                            .frame(height: 300)
                    }
                    ForEach(items) { d in row(d) }
                    if !items.isEmpty {
                        Text("Occupano \(Downloads.size(space.used)) su questo dispositivo · liberi \(Downloads.size(space.free)).")
                            .font(NxFont.caption).foregroundStyle(NxColor.textDim).multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity).padding(.top, 18).padding(.horizontal, Metrics.gutter)
                    }
                    options(items, used: space.used)
                }
                .padding(.bottom, 20)
            }
        }
        .nxPage()
    }

    /// Why nothing moves.
    private func why(_ items: [DownloadEntity]) -> String? {
        guard items.contains(where: { $0.state == "queued" || $0.state == "running" }), let b = watcher.blocked else { return nil }
        switch b {
        case .vpn: return "In pausa: la VPN è spenta. Riprendono da soli quando la riaccendi."
        case .storage: return "In pausa: lo spazio sul telefono sta finendo. Libera spazio o elimina qualche download."
        case .wifi: return "In attesa del Wi-Fi (puoi permettere i dati mobili qui sotto)."
        case .network: return "In attesa della rete."
        }
    }

    @ViewBuilder private func options(_ items: [DownloadEntity], used: Int64) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            OptionHeader(title: "Prossimi download").padding(.horizontal, -Metrics.u(16))
            SettingRow(icon: "wifi", title: "Rete", sub: "Con i dati mobili un film consuma da 0,5 a 3 GB.", value: wifiOnly ? "Solo Wi-Fi" : "Anche dati mobili", chevron: false) {
                app.choose("Rete", [(true, "Solo Wi-Fi"), (false, "Anche dati mobili")], current: wifiOnly) { v in wifiOnly = v; dl.wifiOnly = v }
            }
            SettingRow(icon: "sparkles.tv", title: "Qualità", sub: "Risparmio ≈ 0,5 GB l'ora · Standard (720p) ≈ 1 GB · Alta (1080p) ≈ 2–3 GB, se la fonte offre più versioni.",
                       value: Downloads.qualities[max(0, min(2, quality))], chevron: false) {
                app.choose("Qualità", Downloads.qualities.enumerated().map { ($0.offset, $0.element) }, current: quality) { v in quality = v; dl.quality = v }
            }
            if !items.isEmpty {
                NxButton("Elimina tutti i download", icon: "trash", kind: .danger, wide: true) {
                    app.confirm("Eliminare tutti i download?", message: "Liberi \(Downloads.size(used)) su questo dispositivo.", confirm: "Elimina tutto", destructive: true) { dl.removeAll() }
                }
                .padding(.top, 8)
            }
        }
        .frame(maxWidth: 600)
        .padding(.horizontal, Metrics.gutter)
    }

    private func play(_ d: DownloadEntity) {
        guard d.state == "done" else { return }
        let last = app.core.library.progressFor(app.pid, d.tmdbId, d.media, d.season, d.episode)
        if let r = dl.playRequest(d, startMs: (last != nil && !last!.completed) ? last!.positionMs : 0) { app.play(r) }
        else { app.say("Il file non c'è più: scaricalo di nuovo.") }
    }

    private func menu(_ d: DownloadEntity) { app.menu(d.title, DownloadsView.actions(app, d) { play(d) }) }

    /// What can be done with a download (the three dots, a long press, the arrow on a title).
    static func actions(_ app: AppModel, _ d: DownloadEntity, play: @escaping () -> Void) -> [NxAction] {
        let dl = app.core.downloads
        var a = [NxAction]()
        switch d.state {
        case "done": a.append(NxAction("Riproduci", icon: "play.fill", action: play))
        case "failed": a.append(NxAction("Riprova il download", icon: "arrow.clockwise") { dl.retry(d.id) })
        case "paused": a.append(NxAction("Riprendi", icon: "play.fill") { dl.resume(d.id) })
        default: a.append(NxAction("Metti in pausa", icon: "pause.fill") { dl.pause(d.id) })
        }
        a.append(NxAction(d.state == "done" || d.state == "failed" ? "Elimina il download" : "Annulla il download", icon: d.state == "done" || d.state == "failed" ? "trash" : "xmark", destructive: true) { dl.remove(d.id) })
        return a
    }

    private func status(_ d: DownloadEntity) -> String {
        let pct = Int(d.progress * 100)
        switch d.state {
        case "done": return [Downloads.size(d.bytes), dl.info(d.id)?.quality ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
        case "running": return watcher.blocked != nil ? "In attesa · \(pct)%" : "Scarico… \(pct)%"
        case "paused": return "In pausa · \(pct)%"
        case "queued": return pct > 0 ? "In attesa · \(pct)%" : "In coda"
        default: return d.error.map { "Non riuscito: \($0)" } ?? "Non riuscito: riprova o elimina"
        }
    }

    private func row(_ d: DownloadEntity) -> some View {
        HStack(spacing: 12) {
            CardButton(action: { if d.state == "done" { play(d) } else { menu(d) } }, onLong: { menu(d) }) {
                HStack(spacing: 12) {
                    ZStack {
                        NxImage(url: Img.tmdb(d.poster, "w154"), maxPixel: 200) { NxColor.ink3 }
                        if d.state == "done" {
                            Image(systemName: "play.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                                .frame(width: 28, height: 28).background(Color.black.opacity(0.55), in: Circle()).overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 1))
                        }
                    }
                    .frame(width: 56, height: 84).clipShape(RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(d.title).font(NxFont.ui(15, .bold)).foregroundStyle(NxColor.text).lineLimit(1)
                        if let s = d.sub { Text(s).font(NxFont.caption).foregroundStyle(NxColor.textMuted).lineLimit(1) }
                        if d.state != "done" && d.state != "failed" { NxProgressBar(value: d.progress).frame(maxWidth: 160) }
                        Text(status(d)).font(NxFont.caption).foregroundStyle(d.state == "failed" ? NxColor.accentBright : NxColor.textDim).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            BarIcon(icon: "ellipsis", label: "Altro") { menu(d) }
        }
        .padding(.leading, Metrics.gutter).padding(.trailing, 4).padding(.vertical, 7)
    }
}

#if os(iOS)
/// The arrow on a title / episode: download, see how far it is, pause, play or delete once done. `wide`: the grey button
/// under "Riproduci" on a film page.
struct DownloadButton: View {
    let request: PlayRequest
    var wide = false
    @EnvironmentObject var app: AppModel
    @ObservedObject private var watcher = DownloadsWatcher.shared

    var body: some View {
        let id = Downloads.id(request)
        let d = watcher.item(id)
        Button { tap(d) } label: {
            if wide {
                HStack(spacing: 8) {
                    icon(d)
                    Text(label(d)).font(NxFont.button).foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity).frame(height: 42)
                .background(NxColor.button, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            } else {
                icon(d).frame(width: 40, height: 44).contentShape(Rectangle())
            }
        }
        .buttonStyle(NxPlainStyle(scale: wide ? 0.97 : 0.9))
        .accessibilityLabel("Download")
    }

    private func label(_ d: DownloadEntity?) -> String {
        let pct = Int((d?.progress ?? 0) * 100)
        switch d?.state {
        case "done": return "Scaricato"
        case "running": return watcher.blocked != nil ? "In attesa · \(pct)%" : "Scarico… \(pct)%"
        case "queued": return pct > 0 ? "In attesa · \(pct)%" : "In coda"
        case "paused": return "In pausa · \(pct)%"
        case "failed": return "Riprova il download"
        default: return "Scarica"
        }
    }

    @ViewBuilder private func icon(_ d: DownloadEntity?) -> some View {
        switch d?.state {
        case "done": Image(systemName: "checkmark.circle.fill").font(.system(size: 20, weight: .semibold)).foregroundStyle(NxColor.kids)
        case "running", "paused":
            ZStack {
                Circle().stroke(NxColor.track, lineWidth: 2.5)
                Circle().trim(from: 0, to: max(0.03, d?.progress ?? 0)).stroke(d?.state == "paused" ? NxColor.textMuted : Color.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round)).rotationEffect(.degrees(-90))
                if d?.state == "paused" { Image(systemName: "pause.fill").font(.system(size: 8, weight: .bold)).foregroundStyle(NxColor.textMuted) }
                else { RoundedRectangle(cornerRadius: 1.5).fill(Color.white).frame(width: 7, height: 7) }
            }
            .frame(width: 20, height: 20)
        case "queued": Image(systemName: "clock").font(.system(size: 19, weight: .semibold)).foregroundStyle(NxColor.textMuted)
        case "failed": Image(systemName: "exclamationmark.arrow.circlepath").font(.system(size: 19, weight: .semibold)).foregroundStyle(NxColor.accentBright)
        default: Image(systemName: "arrow.down.to.line").font(.system(size: 19, weight: .semibold)).foregroundStyle(.white)
        }
    }

    private func tap(_ d: DownloadEntity?) {
        guard let d = d else { start(); return }
        if d.state == "failed" { app.core.downloads.retry(d.id); return }
        let title = d.sub.map { "\(d.title) · \($0)" } ?? d.title
        app.menu(title, DownloadsView.actions(app, d) {
            if let r = app.core.downloads.playRequest(d) { app.play(r) }
        })
    }

    private func start() {
        PlatformServices.shared.requestPermission()
        app.core.downloads.enqueue(app.pid, request)
        let dl = app.core.downloads
        if let b = dl.blockReason() {
            switch b {
            case .wifi: app.say("Download in coda: parte appena sei sul Wi-Fi.")
            case .storage: app.say("Download in coda: lo spazio sul telefono sta finendo.")
            default: app.say("Download in coda: parte appena c'è la rete.")
            }
        } else {
            app.say("Download avviato.")
        }
    }
}
#endif
