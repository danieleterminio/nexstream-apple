import SwiftUI
#if os(tvOS)
import Combine
#endif

// "Cambia fonte" (Android: SourcePicker.kt): every source of the film / episode at once — site, server, the site's own
// quality tag — and the one playing. Each line then gets what its link really carries (720p / 1080p / 4K, HEVC) as the
// engine checks it in the background; a source that gives no link or does not answer is greyed "Non disponibile" and
// cannot be chosen. The list itself lives in the engine (nxbridge.sources_*), kept 20 minutes per title, so a reopened
// panel is full at once. Picking one plays it from where the viewer is.

/// The list for one playback: started without checks once the title plays, checked while the panel is open.
@MainActor
final class SourcePickerModel: ObservableObject {
    @Published private(set) var snap: SourcesSnapshot? = nil
    @Published private(set) var failed = false
    private let request: PlayRequest
    private var watching = false
    init(request: PlayRequest) { self.request = request }

    var job: String? { (snap?.job ?? "").isEmpty ? nil : snap?.job }

    /// Lists the sources in the background (no link opened), so the panel opens full.
    func prefetch() async {
        if snap != nil { return }
        if let s = await NexCore.shared.resolver.sources(request, probe: false) { snap = s }
    }

    /// While the panel is open: start the checks and follow them until every line has its answer.
    func watch() async {
        if watching { return }
        watching = true
        defer { watching = false }
        let resolver = NexCore.shared.resolver
        guard let s = await resolver.sources(request, probe: true) else { failed = snap == nil; return }
        snap = s; failed = false
        while !(snap?.finished ?? true) && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard let j = job else { return }
            if let n = await resolver.pollSources(j) {
                if n.state == "gone" { snap = await resolver.sources(request, probe: true) ?? snap } else { snap = n }
            }
        }
    }

    /// What the panel is doing, in a word, under its title.
    var status: String {
        if failed { return "Non riesco a leggere le fonti adesso" }
        guard let s = snap, s.state != "searching" else { return "Cerco le fonti…" }
        let rows = s.rows
        let checked = rows.filter { $0.checked }.count
        let ok = rows.filter { $0.status == "ok" }.count
        if s.state == "listing" { return rows.isEmpty ? "Cerco i server…" : "\(rows.count) trovate, cerco le altre…" }
        if !s.finished { return "Verifico la qualità… \(checked) di \(rows.count)" }
        if rows.isEmpty { return "Nessun'altra fonte trovata per questo titolo" }
        return "\(rows.count) " + (rows.count == 1 ? "fonte" : "fonti") + " · \(ok) " + (ok == 1 ? "disponibile" : "disponibili")
    }
    var busy: Bool { !failed && !(snap?.finished ?? false) }
}

extension SourceRow {
    /// Is this the source playing? By id, or by site + server for a stream that came without one.
    func isPlaying(_ s: ResolvedStream?) -> Bool {
        guard let s = s else { return false }
        if !s.sourceId.isEmpty { return s.sourceId == id }
        return channel == s.channel && (server ?? "").lowercased() == s.server.lowercased()
    }
    /// The second line: its server, the site's own tag, the language when the site says it.
    var subtitle: String {
        var a = [hostName]
        if let l = label, !l.isEmpty { a.append("il sito dice \(l)") }
        if let l = language, !l.isEmpty, l.uppercased() != "ITA" { a.append(l) }
        return a.joined(separator: " · ")
    }
    var refusal: String {
        "\(siteName) · \(hostName): non disponibile" + ((note ?? "").isEmpty ? "" : " (\(note ?? ""))")
    }
}

/// One source: a tick on the one playing, site and server, its marks; white under the TV focus, greyed when dead.
struct SourceLine: View {
    let row: SourceRow
    let current: Bool
    let focused: Bool
    var body: some View {
        let fg: Color = focused ? .black : .white
        HStack(spacing: Metrics.u(10)) {
            Image(systemName: "checkmark").font(.system(size: 14 * Metrics.unit, weight: .bold)).opacity(current ? 1 : 0).frame(width: Metrics.u(20))
            VStack(alignment: .leading, spacing: Metrics.u(2)) {
                HStack(spacing: Metrics.u(8)) {
                    Text(row.siteName).font(NxFont.ui(15, .bold)).lineLimit(1)
                    if current {
                        Text("IN RIPRODUZIONE").font(NxFont.ui(10, .heavy)).tracking(1).lineLimit(1)
                            .foregroundStyle(focused ? NxColor.accentDeep : NxColor.accentBright)
                    }
                }
                Text(row.subtitle).font(NxFont.caption).foregroundStyle(focused ? Color.black.opacity(0.65) : NxColor.textDim).lineLimit(1)
            }
            Spacer(minLength: 8)
            tail
        }
        .foregroundStyle(fg)
        .padding(.horizontal, Metrics.u(16)).padding(.vertical, Metrics.u(12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(focused ? Color.white : Color.clear, in: RoundedRectangle(cornerRadius: Metrics.u(5), style: .continuous))
        .opacity(row.dead && !focused ? 0.45 : 1)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var tail: some View {
        HStack(spacing: Metrics.u(6)) {
            switch row.status ?? "" {
            case "ok":
                if let q = row.quality, !q.isEmpty { badge(q) }
                if row.codec == "HEVC" { badge("HEVC") }
                if (row.quality ?? "").isEmpty { Text("Disponibile").font(NxFont.ui(12, .semibold)).foregroundStyle(focused ? Color.black : NxColor.textMuted) }
            case "dead":
                Text("Non disponibile").font(NxFont.ui(12, .semibold)).foregroundStyle(focused ? Color.black : NxColor.textMuted)
            case "checking":
                NxSpinner(size: 14).colorMultiply(focused ? .black : .white)
            default:
                Text("In attesa").font(NxFont.ui(12, .medium)).foregroundStyle((focused ? Color.black : NxColor.textMuted).opacity(0.6))
            }
        }
    }

    /// The same mark as QualityBadge, drawn dark under the TV focus.
    private func badge(_ q: String) -> some View {
        Text(q).font(NxFont.label).lineLimit(1).foregroundStyle(focused ? Color.black : NxColor.textMuted)
            .padding(.horizontal, Metrics.u(5)).padding(.vertical, Metrics.u(1.5))
            .overlay(RoundedRectangle(cornerRadius: Metrics.u(3)).stroke(focused ? Color.black.opacity(0.55) : NxColor.textDim, lineWidth: 1))
    }
}

/// iPhone / iPad (and any panel host): the content of `app.present("Cambia fonte")`.
struct SourcePickerList: View {
    @ObservedObject var picker: SourcePickerModel
    @ObservedObject var model: VodPlayerModel
    @EnvironmentObject var app: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Metrics.u(8)) {
                if picker.busy { NxSpinner(size: 12) }
                Text(picker.status).font(NxFont.caption).foregroundStyle(NxColor.textDim).lineLimit(1)
            }
            .padding(.horizontal, Metrics.u(16)).padding(.bottom, Metrics.u(6))
            LazyVStack(spacing: 0) {
                ForEach(picker.snap?.rows ?? []) { row in
                    let current = row.isPlaying(model.stream)
                    Button {
                        if row.dead { app.say(row.refusal); return }
                        app.dismissSheet()
                        if !current { model.pickSource(row, job: picker.job) }
                    } label: {
                        Focusable { f in SourceLine(row: row, current: current, focused: f) }
                    }
                    .buttonStyle(NxPlainStyle(scale: 0.99))
                    .accessibilityIdentifier("source-\(row.id)")
                }
            }
        }
        .task { await picker.watch() }
    }
}

#if os(tvOS)
/// Apple TV: the list over the darkened picture, in the player's own panel layer (like TvListOverlay). Focus starts on
/// the source playing and stays on a line by its id while lines are added; select picks; BACK closes.
struct TvSourceOverlay: View {
    @ObservedObject var picker: SourcePickerModel
    @ObservedObject var model: VodPlayerModel
    @EnvironmentObject var app: AppModel
    var keys: PassthroughSubject<String, Never>? = nil
    let onPick: (SourceRow) -> Void
    let onClose: () -> Void
    @FocusState private var focus: String?

    private var rows: [SourceRow] { picker.snap?.rows ?? [] }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.86).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                Text("Cambia fonte").font(NxFont.display(24, .bold)).foregroundStyle(.white)
                HStack(spacing: 12) {
                    if picker.busy { NxSpinner(size: 12) }
                    Text(picker.status).font(NxFont.ui(12, .medium)).foregroundStyle(NxColor.textDim)
                }
                .padding(.top, 6)
                list.padding(.top, 26)
            }
            .frame(width: 1000, alignment: .leading)
            .padding(.leading, 140).padding(.top, 80)
        }
        .onExitCommand(perform: onClose)
        .onReceive(keys ?? PassthroughSubject<String, Never>()) { k in key(k) }
        .task { await picker.watch() }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(rows) { row in
                        Button { choose(row) } label: {
                            Focusable { f in SourceLine(row: row, current: row.isPlaying(model.stream), focused: f).scaleEffect(f ? 1.02 : 1).animation(.easeOut(duration: 0.12), value: f) }
                        }
                        .buttonStyle(NxPlainStyle(scale: 0.98))
                        .focused($focus, equals: row.id).id(row.id)
                        .accessibilityIdentifier("source-\(row.id)")
                    }
                }
                .padding(.vertical, 20).padding(.horizontal, 12)
            }
            .focusSection()
            .onChange(of: rows.map { $0.id }) { _, ids in
                // the first lines arrived (or the panel opened empty): the focus goes to the one playing
                if focus == nil || !(ids.contains(focus ?? "")) { placeFocus(proxy) }
            }
            .onAppear { placeFocus(proxy) }
            .onChange(of: focus) { _, f in if let f = f { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(f, anchor: .center) } } }
        }
    }

    private func placeFocus(_ proxy: ScrollViewProxy) {
        let start = rows.first(where: { $0.isPlaying(model.stream) })?.id ?? rows.first?.id
        guard let s = start else { return }
        proxy.scrollTo(s, anchor: .center)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focus = s }
    }

    private func choose(_ row: SourceRow) {
        if row.dead { app.say(row.refusal); return }
        if row.isPlaying(model.stream) { onClose() } else { onPick(row) }
    }

    private func key(_ k: String) {
        let i = rows.firstIndex(where: { $0.id == focus }) ?? 0
        switch k {
        case "up": if i > 0 { focus = rows[i - 1].id }
        case "down": if i + 1 < rows.count { focus = rows[i + 1].id }
        case "ok": if i < rows.count { choose(rows[i]) }
        case "back": onClose()
        default: break
        }
    }
}
#endif
