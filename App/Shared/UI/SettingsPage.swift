import SwiftUI

// Impostazioni, laid out per device the way Netflix does it (docs/settings-layout.md, same as Android):
// TV and wide iPad = categories on the left, the rows of the chosen one on the right, choices shown in place;
// iPhone (and narrow iPad) = one edge-to-edge list, a choice opens a page of its own.

enum SettingsCategory: String, CaseIterable, Identifiable {
    case profile, playback, live, home, line, help
    var id: String { rawValue }
    var title: String {
        switch self {
        case .profile: return "Profilo"
        case .playback: return "Riproduzione"
        case .live: return "Canali in diretta"
        case .home: return "In casa"
        case .line: return "Linea e dati"
        case .help: return "Assistenza"
        }
    }
    var icon: String {
        switch self {
        case .profile: return "person.crop.circle"
        case .playback: return "play.rectangle"
        case .live: return "tv"
        case .home: return "house"
        case .line: return "antenna.radiowaves.left.and.right"
        case .help: return "questionmark.circle"
        }
    }
}

/// A setting with a few values to pick from.
struct SettingsChoice: Identifiable {
    let id = UUID()
    let title: String
    var note: String? = nil
    let options: [(key: Int, label: String)]
    let current: Int
    let onPick: (Int) -> Void

    /// Any value type: the options are told apart by their position.
    static func of<T: Equatable>(_ title: String, note: String? = nil, _ options: [(T, String)], current: T, onPick: @escaping (T) -> Void) -> SettingsChoice {
        let values = options.map { $0.0 }
        let labels: [(key: Int, label: String)] = options.enumerated().map { (key: $0.offset, label: $0.element.1) }
        let now = values.firstIndex(of: current) ?? -1
        return SettingsChoice(title: title, note: note, options: labels, current: now) { i in if i >= 0 && i < values.count { onPick(values[i]) } }
    }
}

/// What the settings page shows, kept up to date with the stores it reads.
@MainActor
final class SettingsState: ObservableObject {
    @Published var prefs = Prefs.Values()
    @Published var rev = 0
    @Published var teams: [Teams.Team] = []
    @Published var updater: String? = nil
    @Published var engineVersion = ""
    @Published var compat = NxPlayer.forceVlc
    @Published var synced: Millis = 0
    @Published var cloud = SyncEngine.Status()
    private var watches = [Watch]()

    func start(_ core: NexCore) {
        teams = core.teams.followed()
        watches = [onMain(core.sync.lastSync) { [weak self] in self?.synced = $0 },
                   onMain(core.sync.status) { [weak self] in self?.cloud = $0 },
                   onMain(core.prefs.values) { [weak self] in self?.prefs = $0 },
                   onMain(core.settings.rev) { [weak self] in self?.rev = $0 },
                   onMain(core.teams.changed) { [weak self] _ in self?.teams = core.teams.followed() }]
        Task { engineVersion = await core.engine.version() }
    }
    func stop() { watches = [] }
}

struct SettingsView: View {
    @EnvironmentObject var app: AppModel
    @StateObject private var state = SettingsState()
    @State private var choice: SettingsChoice? = nil
    @State private var selected: SettingsCategory = .profile
    #if os(iOS)
    @State private var width: CGFloat = 400
    #endif

    var body: some View {
        content
            .onAppear {
                state.start(app.core)
                // build pipeline screenshots: "-nxSettingsCat playback", "-nxSettingsChoice" (the audio language)
                if let c = Demo.value("-nxSettingsCat").flatMap(SettingsCategory.init(rawValue:)) { selected = c }
                if Demo.args.contains("-nxSettingsChoice") {
                    choice = .of("Lingua dell'audio", note: "Quando un film o una serie ha più lingue.", Settings.audioOptions, current: app.core.settings.audioLang(app.pid)) { _ in }
                }
            }
            .onDisappear { state.stop() }
    }

    @ViewBuilder private var content: some View {
        #if os(tvOS)
        SettingsSplit(state: state, selected: $selected, choice: $choice).nxPage()
        #else
        ZStack {
            if width >= 700 {
                SettingsSplit(state: state, selected: $selected, choice: $choice)
            } else {
                SettingsList(state: state) { c in withAnimation(.easeOut(duration: 0.22)) { choice = c } }
            }
        }
        .background(GeometryReader { g in Color.clear.onAppear { width = g.size.width }.onChange(of: g.size.width) { _, w in width = w } })
        .nxScreen("Impostazioni")
        .overlay {
            // the phone: a choice is a page of its own, over the settings and their bar
            if width < 700, let c = choice {
                SettingsChoicePage(choice: c) { withAnimation(.easeOut(duration: 0.2)) { choice = nil } }
                    .transition(.move(edge: .trailing))
                    .zIndex(1)
            }
        }
        #endif
    }
}

// MARK: - phone: one list

#if os(iOS)
private struct SettingsList: View {
    @ObservedObject var state: SettingsState
    let choose: (SettingsChoice) -> Void

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(SettingsCategory.allCases) { c in
                    if c != .profile { OptionHeader(title: c.title).padding(.top, 10) }
                    SettingsRows(category: c, state: state, choose: choose)
                }
                Color.clear.frame(height: 24)
            }
            .id(state.rev)
        }
    }
}

/// A choice as a page: the setting's name in the bar, a line about it, the values with a tick on the current one.
private struct SettingsChoicePage: View {
    let choice: SettingsChoice
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button(action: onClose) {
                    Image(systemName: "chevron.left").font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 40, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(NxPlainStyle(scale: 0.9))
                .accessibilityLabel("Indietro")
                Text(choice.title).font(NxFont.ui(18, .heavy)).foregroundStyle(NxColor.text).lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(height: 48)
            ScrollView(.vertical, showsIndicators: false) {
                SettingsChoiceList(choice: choice, onDone: onClose).padding(.horizontal, Metrics.gutter - 16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(NxColor.bg.ignoresSafeArea())
        .gesture(DragGesture().onEnded { v in if v.startLocation.x < 40 && v.translation.width > 80 { onClose() } })
    }
}
#endif

// MARK: - TV and wide iPad: two panes

private struct SettingsSplit: View {
    @ObservedObject var state: SettingsState
    @Binding var selected: SettingsCategory
    @Binding var choice: SettingsChoice?
    @EnvironmentObject var app: AppModel
    @FocusState private var category: SettingsCategory?
    /// The current value of a choice list takes the focus when the list opens.
    @FocusState private var firstRow: Bool
    /// The row that opened the choice list: picking a value or BACK puts the focus back on it.
    @State private var returnKey: String? = nil

    private func backToRow() {
        FocusMemory.restore(returnKey ?? SettingsRows.firstKey, after: 0.12)
        returnKey = nil
    }

    private var leftWidth: CGFloat { Metrics.tv ? 470 : 300 }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            categories
                .frame(width: leftWidth, alignment: .topLeading)
                #if os(tvOS)
                .focusSection()
                #endif
            Rectangle().fill(NxColor.hairline).frame(width: 1).padding(.vertical, Metrics.tv ? 60 : 12)
            pane
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                #if os(tvOS)
                .focusSection()
                // BACK: a choice → its rows; the rows → the categories (from there the side menu)
                .onExitCommand {
                    if choice != nil { choice = nil; backToRow() } else { category = selected }
                }
                #endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        #if os(tvOS)
        .defaultFocus($category, selected)
        #endif
        .task {
            // build pipeline, with -nxSettingsChoice: the choice list closes as BACK does, the focus goes on its row
            guard Demo.args.contains("-nxChoiceClose") else { return }
            try? await Task.sleep(nanoseconds: 9_000_000_000)
            returnKey = "settings.Lingua dell'audio"
            choice = nil
            backToRow()
        }
        .onChange(of: category) { _, c in
            // on the TV the category under the focus is the one on the right, no click needed
            if let c = c, c != selected { selected = c; choice = nil }
        }
    }

    private var categories: some View {
        VStack(alignment: .leading, spacing: Metrics.tv ? 6 : 2) {
            Text("Impostazioni").font(Metrics.tv ? NxFont.titleXL : NxFont.titleL).foregroundStyle(NxColor.text)
                .padding(.leading, Metrics.tv ? 24 : 12).padding(.top, Metrics.tv ? 50 : 12).padding(.bottom, Metrics.tv ? 24 : 10)
            ForEach(SettingsCategory.allCases) { c in
                Button {
                    selected = c; choice = nil
                    // select (like RIGHT) goes into the rows, on the first one
                    FocusMemory.restore(SettingsRows.firstKey, after: 0.05)
                } label: {
                    Focusable { focused in
                        let on = c == selected
                        HStack(spacing: Metrics.u(14)) {
                            Image(systemName: c.icon).font(.system(size: 18 * Metrics.unit, weight: .semibold)).frame(width: Metrics.u(26))
                            Text(c.title).font(NxFont.ui(16, on ? .bold : .semibold)).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(focused ? Color.black : (on ? Color.white : NxColor.textMuted))
                        .padding(.horizontal, Metrics.u(14)).padding(.vertical, Metrics.u(12))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(focused ? Color.white : (on && !Metrics.tv ? NxColor.ink3 : Color.clear), in: RoundedRectangle(cornerRadius: Metrics.u(6), style: .continuous))
                        .overlay(alignment: .leading) {
                            if on && !focused && Metrics.tv { Capsule().fill(NxColor.accent).frame(width: 5, height: 30).offset(x: -10) }
                        }
                        .contentShape(Rectangle())
                    }
                }
                .buttonStyle(NxPlainStyle(scale: 1))
                .focused($category, equals: c)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Metrics.tv ? 20 : 8)
    }

    private var pane: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                if let c = choice {
                    HStack(spacing: Metrics.u(10)) {
                        #if os(iOS)
                        Button { choice = nil } label: {
                            Image(systemName: "chevron.left").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white).frame(width: 36, height: 40).contentShape(Rectangle())
                        }
                        .buttonStyle(NxPlainStyle(scale: 0.9))
                        .accessibilityLabel("Indietro")
                        #endif
                        Text(c.title).font(Metrics.tv ? NxFont.titleL : NxFont.titleM).foregroundStyle(NxColor.text).lineLimit(2)
                    }
                    .padding(.horizontal, Metrics.u(16)).padding(.bottom, Metrics.u(6))
                    SettingsChoiceList(choice: c, first: $firstRow) { choice = nil; backToRow() }
                } else {
                    Text(selected.title).font(Metrics.tv ? NxFont.titleL : NxFont.titleM).foregroundStyle(NxColor.text)
                        .padding(.horizontal, Metrics.u(16)).padding(.bottom, Metrics.u(10))
                    SettingsRows(category: selected, state: state) { c in returnKey = FocusMemory.last; choice = c; firstRow = true }
                        .id("\(selected.rawValue)-\(state.rev)")
                }
                Color.clear.frame(height: 60)
            }
            .padding(.top, Metrics.tv ? 62 : 14)
            .padding(.horizontal, Metrics.tv ? 40 : 16)
            .frame(maxWidth: Metrics.tv ? 1100 : 760, alignment: .leading)
        }
    }
}

/// The values of a choice; picking one applies it and goes back.
private struct SettingsChoiceList: View {
    let choice: SettingsChoice
    var first: FocusState<Bool>.Binding? = nil
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let n = choice.note {
                Text(n).font(NxFont.meta).foregroundStyle(NxColor.textMuted).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Metrics.u(16)).padding(.bottom, Metrics.u(10))
            }
            ForEach(Array(choice.options.enumerated()), id: \.offset) { i, o in
                OptionRow(title: o.label, selected: o.key == choice.current) { choice.onPick(o.key); onDone() }
                    .modifier(FirstFocus(binding: i == max(0, choice.options.firstIndex { $0.key == choice.current } ?? 0) ? first : nil))
            }
        }
    }
}

/// Puts the focus on one view of a list when the page asks for it.
private struct FirstFocus: ViewModifier {
    let binding: FocusState<Bool>.Binding?
    func body(content: Content) -> some View {
        if let b = binding { content.focused(b) } else { content }
    }
}

// MARK: - the rows of each category (same texts on every device and on Android)

private struct SettingsRows: View {
    /// Focus key of the first row of a category (Apple TV): where select / RIGHT on a category lands.
    static let firstKey = "settings.first"

    let category: SettingsCategory
    @ObservedObject var state: SettingsState
    let choose: (SettingsChoice) -> Void
    @EnvironmentObject var app: AppModel
    #if os(tvOS)
    @ObservedObject private var remoteHost = RemoteHost.shared
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.tv ? 4 : 0) {
            switch category {
            case .profile: profile
            case .playback: playback
            case .live: live
            case .home: home
            case .line: line
            case .help: help
            }
        }
    }

    private var core: NexCore { app.core }
    private var pid: Int64 { app.pid }

    @ViewBuilder private var profile: some View {
        if let p = app.profile {
            HStack(spacing: Metrics.u(14)) {
                p.face(56)
                VStack(alignment: .leading, spacing: 3) {
                    Text(p.name).font(NxFont.titleM).foregroundStyle(NxColor.text)
                    Text(p.kids ? "Profilo bambini" : "Contenuti: \(Avatars.maturityLabels[min(2, max(0, p.maturity))])").font(NxFont.caption).foregroundStyle(NxColor.textMuted)
                    if p.pin != nil { Text("Protetto da PIN").font(NxFont.caption).foregroundStyle(NxColor.textDim) }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Metrics.u(Metrics.tv ? 16 : 14)).padding(.vertical, Metrics.u(10))
            SettingRow(icon: "person.2.fill", title: "Cambia profilo") { app.changeProfile() }.nxFocusKey(SettingsRows.firstKey)
            // a kids profile cannot reach the profiles (and with them maturity and PINs)
            if !p.kids {
                SettingRow(icon: "person.crop.circle.badge.plus", title: "Gestisci profili", sub: "Nome, avatar, PIN e profili per bambini") { app.open(.manageProfiles) }
            }
            SettingRow(icon: "soccerball", title: "Le tue squadre", sub: state.teams.isEmpty ? "Partite in Home e un avviso 10 minuti prima" : state.teams.map { $0.name }.joined(separator: ", ")) { app.open(.teams) }
            SettingRow(icon: "arrow.left.arrow.right", title: "Copia o invia i profili", sub: "Tra questo dispositivo e un'altra app NexStream di casa") { app.open(.transfer) }
        }
    }

    @ViewBuilder private var playback: some View {
        SettingRow(icon: "forward.end.fill", title: "Episodio successivo automatico", sub: "Alla fine di un episodio parte il seguente.", on: core.settings.autoplay(pid)) {
            core.settings.setAutoplay(pid, !core.settings.autoplay(pid))
        }
        .nxFocusKey(SettingsRows.firstKey)
        SettingRow(icon: "text.line.last.and.arrowtriangle.forward", title: "Proponi il prossimo sui titoli di coda", sub: "Nell'ultimo minuto compare “Prossimo episodio”.", on: core.settings.creditsPrompt(pid)) {
            core.settings.setCreditsPrompt(pid, !core.settings.creditsPrompt(pid))
        }
        SettingRow(icon: "hourglass", title: "“Stai ancora guardando?”", sub: "Dopo quante ore senza toccare nulla te lo chiedo.", value: hours(core.settings.stillWatchingHours(pid)), chevron: !Metrics.tv) {
            choose(.of("“Stai ancora guardando?”", note: "Dopo quante ore senza toccare nulla te lo chiedo.", Settings.stillHoursOptions.map { ($0, hours($0)) }, current: core.settings.stillWatchingHours(pid)) { core.settings.setStillWatchingHours(pid, $0) })
        }
        SettingRow(icon: "repeat", title: "…e dopo quanti episodi", sub: "Episodi partiti da soli, uno dopo l'altro.", value: "\(core.settings.stillWatchingEpisodes(pid))", chevron: !Metrics.tv) {
            choose(.of("Dopo quanti episodi", note: "Episodi partiti da soli, uno dopo l'altro.", Settings.stillEpisodesOptions.map { ($0, "\($0) episodi") }, current: core.settings.stillWatchingEpisodes(pid)) { core.settings.setStillWatchingEpisodes(pid, $0) })
        }
        SettingRow(icon: "waveform", title: "Lingua dell'audio", sub: "Quando un film o una serie ha più lingue.", value: Settings.audioOptions.first { $0.0 == core.settings.audioLang(pid) }?.1, chevron: !Metrics.tv) {
            choose(.of("Lingua dell'audio", note: "Quando un film o una serie ha più lingue.", Settings.audioOptions, current: core.settings.audioLang(pid)) { core.settings.setAudioLang(pid, $0) })
        }
        #if os(iOS)
        SettingRow(icon: "arrow.down.to.line", title: "Download", sub: "Film ed episodi salvati su questo dispositivo") { app.open(.downloads) }
        #endif
        SettingRow(icon: "clock.arrow.circlepath", title: "Azzera “Continua a guardare”", sub: "Toglie i titoli lasciati a metà", chevron: false) {
            app.confirm("Azzerare “Continua a guardare”?", message: "I titoli lasciati a metà spariscono dalla Home.", confirm: "Azzera") { core.library.clearContinue(pid); app.say("Fatto") }
        }
    }

    @ViewBuilder private var live: some View {
        let prefs = state.prefs
        SettingRow(icon: "4k.tv", title: "Qualità video", sub: "La versione di ogni canale che parte per prima; se non risponde passo da solo a un'altra.", value: Prefs.qualities.first { $0.0 == prefs.quality }?.1, chevron: !Metrics.tv) {
            choose(.of("Qualità video", note: "La versione di ogni canale che parte per prima; se non risponde passo da solo a un'altra.", Prefs.qualities, current: prefs.quality) { v in core.prefs.update { $0.quality = v } })
        }
        .nxFocusKey(SettingsRows.firstKey)
        SettingRow(icon: "cpu", title: "Usa le versioni HEVC", sub: "Stessa immagine con meno dati. Spegnilo se qualche canale resta nero.", on: prefs.hevc) { core.prefs.update { $0.hevc.toggle() } }
        SettingRow(icon: "captions.bubble", title: "Sottotitoli", sub: "Quando il canale li trasmette.", value: prefs.preferredText.isEmpty ? "Spenti" : "Italiano", chevron: !Metrics.tv) {
            choose(.of("Sottotitoli", note: "Quando il canale li trasmette.", [("", "Spenti"), ("it", "Italiano")], current: prefs.preferredText) { v in core.prefs.update { $0.preferredText = v } })
        }
        SettingRow(icon: "wrench.and.screwdriver", title: "Player compatibile", sub: "Usa sempre il motore di riserva. Rinunci ad AirPlay e picture in picture: accendilo solo se i video non partono.", on: state.compat) {
            state.compat.toggle(); NxPlayer.forceVlc = state.compat
        }
    }

    @ViewBuilder private var home: some View {
        #if os(iOS)
        SettingRow(icon: "appletvremote.gen4.fill", title: "Telecomando della TV", sub: "Usa il telefono per comandare NexStream sulla TV di casa") { app.open(.remote) }
            .nxFocusKey(SettingsRows.firstKey)
        #else
        SettingRow(icon: "iphone.radiowaves.left.and.right", title: "Telecomando dal telefono",
                   sub: (remoteHost.pairedPhones.isEmpty ? "Sul telefono apri NexStream e “Telecomando della TV”." : "Abbinati: \(remoteHost.pairedPhones.joined(separator: ", ")).") + (Lan.address().map { " Indirizzo: \($0)" } ?? "")) {
            app.open(.remote)
        }
        .nxFocusKey(SettingsRows.firstKey)
        #endif
    }

    @ViewBuilder private var line: some View {
        if let s = app.session {
            SettingRow(icon: "antenna.radiowaves.left.and.right", title: "Linea \(s.username)", sub: SettingsRows.expiry(s), value: app.vpn ? "VPN attiva" : "VPN spenta", chevron: false) {}
                .nxFocusKey(SettingsRows.firstKey)
        }
        #if os(tvOS)
        SettingRow(icon: "iphone", title: "Cambia linea dal telefono", sub: "Inquadra un QR e scrivi nome utente e password con la tastiera del telefono.") {
            app.present("Cambia linea dal telefono", style: .page) {
                PhoneLoginPanel(onClose: { app.dismissSheet() }, closeLabel: "Chiudi", onDone: { app.dismissSheet(); app.say("Linea collegata") })
            }
        }
        #endif
        SettingRow(icon: "arrow.triangle.2.circlepath", title: "Sincronizzazione tra dispositivi", sub: syncLine, chevron: false) {
            core.sync.kick(after: 0); app.say("Sincronizzo…")
        }
        SettingRow(icon: "arrow.clockwise", title: app.syncStatus != nil ? "Aggiornamento in corso…" : "Aggiorna canali e guida TV",
                   sub: app.syncStatus ?? (core.epg.lastReport() ?? "Si aggiornano da soli; usalo se manca un canale o un programma."), chevron: false) {
            if app.syncStatus == nil { core.syncIfNeeded(force: true) }
        }
        SettingRow(icon: "shippingbox", title: "Aggiorna le sorgenti on demand", sub: state.updater ?? "Stream4Me \(state.engineVersion)", chevron: false) {
            state.updater = "Controllo…"
            let st = state
            Task {
                switch await core.updater.check(force: true) {
                case .upToDate: st.updater = "Sorgenti già aggiornate"
                case .updated(let sha): st.updater = "Aggiornate (\(sha.take(7)))"
                case .failed(let m): st.updater = m
                case .skipped: st.updater = "Controllate da poco"
                }
            }
        }
        SettingRow(icon: "rectangle.portrait.and.arrow.right", title: "Esci dalla linea", sub: "Dovrai inserire di nuovo nome utente e password.", destructive: true, chevron: false) {
            app.confirm("Uscire dalla linea?", message: "La linea verrà scollegata da questo dispositivo. Profili e preferiti restano.", confirm: "Esci", destructive: true) { core.logout() }
        }
    }

    @ViewBuilder private var help: some View {
        #if os(iOS)
        ShareLink(item: NxLog.url, preview: SharePreview("Registro di NexStream")) {
            HStack(spacing: Metrics.u(13)) {
                Image(systemName: "doc.text.magnifyingglass").font(.system(size: 17, weight: .medium)).frame(width: 26).foregroundStyle(NxColor.textMuted)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Invia il registro").font(NxFont.ui(15, .bold)).foregroundStyle(.white)
                    Text("Cosa ha fatto l'app nelle ultime ore: serve a capire un problema.").font(NxFont.caption).foregroundStyle(NxColor.textDim)
                }
                Spacer(minLength: 8)
                Image(systemName: "square.and.arrow.up").font(.system(size: 14, weight: .bold)).foregroundStyle(NxColor.textDim)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { Rectangle().fill(NxColor.hairline).frame(height: 0.5).padding(.leading, 53) }
            .contentShape(Rectangle())
        }
        .buttonStyle(NxPlainStyle(scale: 0.99))
        #endif
        SettingRow(icon: "info.circle", title: "NexStream \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")",
                   sub: "Stream4Me \(state.engineVersion)", chevron: false) {}
            .nxFocusKey(SettingsRows.firstKey)
    }

    private func hours(_ h: Int) -> String { h == 0 ? "Mai" : (h == 1 ? "1 ora" : "\(h) ore") }

    /// Same wording as Android's settings: running, the last error, or when it last went well.
    private var syncLine: String {
        let everywhere = "Profili, lista, preferiti e posizioni sono gli stessi su ogni dispositivo con questa linea."
        if state.cloud.running { return "Sincronizzo…" }
        if let e = state.cloud.error { return e }
        if state.synced > 0 { return "\(everywhere) Ultima: \(TimeText.time(state.synced))." }
        return everywhere
    }

    static func expiry(_ s: LineSession) -> String {
        guard let exp = s.expiringAt, !exp.isBlank else { return "Scadenza non disponibile" }
        var date: Date? = nil
        if let secs = Double(exp), secs > 1_000_000_000 { date = Date(timeIntervalSince1970: secs) }
        else {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
            for pattern in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSSZ", "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd"] {
                f.dateFormat = pattern
                if let d = f.date(from: exp) ?? f.date(from: String(exp.prefix(19))) { date = d; break }
            }
        }
        guard let d = date else { return "Scade il \(exp.take(10))" }
        let out = DateFormatter(); out.locale = Locale(identifier: "it_IT"); out.dateFormat = "d MMMM yyyy"
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()), to: Calendar.current.startOfDay(for: d)).day ?? 0
        if days < 0 { return "Scaduta il \(out.string(from: d))" }
        if days == 0 { return "Scade oggi" }
        return "Attiva fino al \(out.string(from: d)) · \(days) giorni"
    }
}
