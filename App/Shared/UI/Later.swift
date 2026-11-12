import SwiftUI

/// Follows the downloads table for the views that show it.
@MainActor
final class DownloadsWatcher: ObservableObject {
    static let shared = DownloadsWatcher()
    @Published private(set) var items: [DownloadEntity] = []
    private var watch: Watch?
    private init() {
        items = NexCore.shared.downloads.all()
        watch = NexCore.shared.db.changes.observe { [weak self] t in
            if t == "downloads" { DispatchQueue.main.async { self?.items = NexCore.shared.downloads.all() } }
        }
    }
    func item(_ id: String) -> DownloadEntity? { items.first { $0.id == id } }
}

/// "Download": what is saved on this device. It plays with no network at all.
struct DownloadsView: View {
    /// Opened from the VPN gate: there is no stack of pages behind it.
    var offline = false
    @EnvironmentObject var app: AppModel
    @ObservedObject private var watcher = DownloadsWatcher.shared

    var body: some View {
        VStack(spacing: 0) {
            NxTopBar(title: "Download", back: !offline, large: offline) {
                if offline { NxButton("Chiudi", kind: .quiet) { app.offlineDownloads = false } }
            }
            if watcher.items.isEmpty {
                StateMessage(icon: "arrow.down.to.line", title: "Nessun download", text: "Nella pagina di un film o di un episodio tocca la freccia per salvarlo su questo dispositivo.")
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(watcher.items) { d in row(d) }
                        Text("Occupano \(ByteCountFormatter.string(fromByteCount: watcher.items.reduce(0) { $0 + $1.bytes }, countStyle: .file)) su questo dispositivo.")
                            .font(NxFont.caption).foregroundStyle(NxColor.textDim).padding(.top, 18)
                    }
                    .padding(.bottom, 20)
                }
            }
        }
        .nxPage()
    }

    private func play(_ d: DownloadEntity) {
        guard d.state == "done" else { return }
        let last = app.core.library.progressFor(app.pid, d.tmdbId, d.media, d.season, d.episode)
        if let r = app.core.downloads.playRequest(d, startMs: (last != nil && !last!.completed) ? last!.positionMs : 0) { app.play(r) }
        else { app.say("Il file non c'è più: scaricalo di nuovo.") }
    }

    private func menu(_ d: DownloadEntity) {
        var a = [NxAction]()
        if d.state == "done" { a.append(NxAction("Riproduci", icon: "play.fill") { play(d) }) }
        a.append(NxAction(d.state == "done" || d.state == "failed" ? "Elimina il download" : "Annulla il download", icon: "trash", destructive: true) { app.core.downloads.remove(d.id) })
        app.menu(d.title, a)
    }

    private func row(_ d: DownloadEntity) -> some View {
        HStack(spacing: 12) {
            CardButton(action: { play(d) }, onLong: { menu(d) }) {
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
                        switch d.state {
                        case "done": Text(ByteCountFormatter.string(fromByteCount: d.bytes, countStyle: .file)).font(NxFont.caption).foregroundStyle(NxColor.textDim)
                        case "running":
                            NxProgressBar(value: d.progress).frame(maxWidth: 160)
                            Text("Scarico… \(Int(d.progress * 100))%").font(NxFont.caption).foregroundStyle(NxColor.textDim)
                        case "queued": Text("In coda").font(NxFont.caption).foregroundStyle(NxColor.textDim)
                        default: Text(d.error ?? "Non riuscito").font(NxFont.caption).foregroundStyle(NxColor.accentBright).lineLimit(2)
                        }
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
/// The arrow on a title / episode: download, see how far it is, play or delete once done. `wide`: the grey button
/// under "Riproduci" on a film page.
struct DownloadButton: View {
    let request: PlayRequest
    var wide = false
    @EnvironmentObject var app: AppModel
    @ObservedObject private var watcher = DownloadsWatcher.shared

    var body: some View {
        let id = Downloads.id(request)
        let d = watcher.item(id)
        Button { tap(d, id) } label: {
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
        switch d?.state {
        case "done": return "Scaricato"
        case "running": return "Scarico… \(Int((d?.progress ?? 0) * 100))%"
        case "queued": return "In coda"
        case "failed": return "Riprova il download"
        default: return "Scarica"
        }
    }

    @ViewBuilder private func icon(_ d: DownloadEntity?) -> some View {
        switch d?.state {
        case "done": Image(systemName: "checkmark.circle.fill").font(.system(size: 20, weight: .semibold)).foregroundStyle(NxColor.kids)
        case "running":
            ZStack {
                Circle().stroke(NxColor.track, lineWidth: 2.5)
                Circle().trim(from: 0, to: max(0.03, d?.progress ?? 0)).stroke(Color.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round)).rotationEffect(.degrees(-90))
                RoundedRectangle(cornerRadius: 1.5).fill(Color.white).frame(width: 7, height: 7)
            }
            .frame(width: 20, height: 20)
        case "queued": Image(systemName: "clock").font(.system(size: 19, weight: .semibold)).foregroundStyle(NxColor.textMuted)
        case "failed": Image(systemName: "exclamationmark.arrow.circlepath").font(.system(size: 19, weight: .semibold)).foregroundStyle(NxColor.accentBright)
        default: Image(systemName: "arrow.down.to.line").font(.system(size: 19, weight: .semibold)).foregroundStyle(.white)
        }
    }

    private func tap(_ d: DownloadEntity?, _ id: String) {
        guard let d = d else { start(id, replace: false); return }
        switch d.state {
        case "failed": start(id, replace: true)
        case "done":
            app.menu(d.title, [
                NxAction("Riproduci dal dispositivo", icon: "play.fill") { if let r = app.core.downloads.playRequest(d) { app.play(r) } },
                NxAction("Elimina il download", icon: "trash", destructive: true) { app.core.downloads.remove(id) },
            ])
        default:
            app.menu(d.title, [NxAction("Annulla il download", icon: "xmark", destructive: true) { app.core.downloads.remove(id) }])
        }
    }

    private func start(_ id: String, replace: Bool) {
        if replace { app.core.downloads.remove(id) }
        app.core.downloads.enqueue(app.pid, request)
        app.say("Download avviato: resta nell'app finché finisce.")
    }
}
#endif
