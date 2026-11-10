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
    var offline = false
    @EnvironmentObject var app: AppModel
    @ObservedObject private var watcher = DownloadsWatcher.shared

    var body: some View {
        Group {
            if watcher.items.isEmpty {
                StateMessage(icon: "arrow.down.circle", title: "Nessun download", text: "Nella pagina di un film o di un episodio tocca la freccia per salvarlo su questo dispositivo.")
            } else {
                List {
                    ForEach(watcher.items) { d in row(d) }
                        .onDelete { idx in for i in idx { app.core.downloads.remove(watcher.items[i].id) } }
                    SwiftUI.Section { } footer: { Text("Occupano \(ByteCountFormatter.string(fromByteCount: watcher.items.reduce(0) { $0 + $1.bytes }, countStyle: .file)) su questo dispositivo.").font(NxFont.caption) }
                }
                .nxClearList()
            }
        }
        .nxPage()
        .navigationTitle("Download")
    }

    private func row(_ d: DownloadEntity) -> some View {
        Button {
            guard d.state == "done" else { return }
            let last = app.core.library.progressFor(app.pid, d.tmdbId, d.media, d.season, d.episode)
            if let r = app.core.downloads.playRequest(d, startMs: (last != nil && !last!.completed) ? last!.positionMs : 0) {
                if offline { app.offlinePlaying = r } else { app.play(r) }
            } else { app.say("Il file non c'è più: scaricalo di nuovo.") }
        } label: {
            HStack(spacing: 12) {
                NxImage(url: Img.tmdb(d.poster, "w154"), maxPixel: 200) { NxColor.ink3 }.frame(width: 46, height: 69).clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(d.title).font(NxFont.bodyStrong).foregroundStyle(NxColor.text).lineLimit(1)
                    if let s = d.sub { Text(s).font(NxFont.caption).foregroundStyle(NxColor.textMuted).lineLimit(1) }
                    switch d.state {
                    case "done": Text(ByteCountFormatter.string(fromByteCount: d.bytes, countStyle: .file)).font(NxFont.caption).foregroundStyle(NxColor.textDim)
                    case "running": NxProgressBar(value: d.progress).frame(maxWidth: 160); Text("Scarico… \(Int(d.progress * 100))%").font(NxFont.caption).foregroundStyle(NxColor.textDim)
                    case "queued": Text("In coda").font(NxFont.caption).foregroundStyle(NxColor.textDim)
                    default: Text(d.error ?? "Non riuscito").font(NxFont.caption).foregroundStyle(NxColor.accentBright).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                if d.state == "done" { Image(systemName: "play.circle.fill").font(.system(size: 26)).foregroundStyle(NxColor.text) }
                else if d.state == "failed" { Button { app.core.downloads.remove(d.id) } label: { Image(systemName: "xmark.circle").font(.system(size: 22)).foregroundStyle(NxColor.textDim) }.buttonStyle(.plain) }
            }
        }
        .contextMenu { Button(role: .destructive) { app.core.downloads.remove(d.id) } label: { Label("Elimina il download", systemImage: "trash") } }
    }
}

#if os(iOS)
/// The arrow on a title / episode: download, see how far it is, play or delete once done.
struct DownloadButton: View {
    let request: PlayRequest
    var compact = false
    @EnvironmentObject var app: AppModel
    @ObservedObject private var watcher = DownloadsWatcher.shared

    var body: some View {
        let id = Downloads.id(request)
        let d = watcher.item(id)
        Menu {
            if let d = d {
                if d.state == "done" { Button { if let r = app.core.downloads.playRequest(d) { app.play(r) } } label: { Label("Riproduci dal dispositivo", systemImage: "play.fill") } }
                Button(role: .destructive) { app.core.downloads.remove(id) } label: { Label(d.state == "done" ? "Elimina il download" : "Annulla il download", systemImage: "trash") }
            }
        } label: {
            ZStack {
                switch d?.state {
                case "done": Image(systemName: "checkmark.circle.fill").foregroundStyle(NxColor.success)
                case "running":
                    Circle().stroke(NxColor.track, lineWidth: 3).frame(width: 22, height: 22)
                    Circle().trim(from: 0, to: max(0.03, d?.progress ?? 0)).stroke(NxColor.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-90)).frame(width: 22, height: 22)
                case "queued": Image(systemName: "clock").foregroundStyle(NxColor.textMuted)
                case "failed": Image(systemName: "exclamationmark.arrow.circlepath").foregroundStyle(NxColor.accentBright)
                default: Image(systemName: "arrow.down.circle").foregroundStyle(NxColor.text)
                }
            }
            .font(.system(size: compact ? 22 : 19, weight: .semibold))
            .frame(width: compact ? 36 : 44, height: compact ? 36 : 44)
        } primaryAction: {
            if d == nil || d?.state == "failed" {
                if d != nil { app.core.downloads.remove(id) }
                app.core.downloads.enqueue(app.pid, request)
                app.say("Download avviato: resta nell'app finché finisce.")
            }
        }
        .if(!compact) { $0.glassEffect(Glass.regular.interactive(), in: Circle()) }
        .accessibilityLabel("Download")
    }
}

/// The downloads page reached from the VPN gate: what is saved plays without VPN and without network.
struct OfflineDownloadsGate: View {
    @EnvironmentObject var app: AppModel
    var body: some View {
        NavigationStack {
            DownloadsView(offline: true)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Indietro") { app.offlineDownloads = false } } }
        }
        .fullScreenCover(item: $app.offlinePlaying) { r in
            VodPlayerView(request: r)
                .background(Color.black.ignoresSafeArea())
                .onAppear { PlatformServices.shared.playerOpened() }
                .onDisappear { PlatformServices.shared.playerClosed() }
                .environmentObject(app).environmentObject(app.store)
        }
    }
}
#endif
