import SwiftUI

/// The frame of the screens before the app: black, the brand on top.
struct GateFrame<Content: View>: View {
    var brand = true
    @ViewBuilder var content: () -> Content
    var body: some View {
        ZStack(alignment: .top) {
            NxColor.bg.ignoresSafeArea()
            content().frame(maxWidth: .infinity, maxHeight: .infinity)
            if brand {
                HStack {
                    Image("BrandLockup").resizable().scaledToFit().frame(height: Metrics.u(26))
                    Spacer()
                }
                .padding(.horizontal, Metrics.u(Metrics.tv ? 40 : 18)).padding(.top, Metrics.u(Metrics.tv ? 30 : 10))
            }
        }
    }
}

// ---------------------------------------------------------------------------------------------------------------- VPN

/// Nothing leaves the device without the VPN: this screen stays until one is up, then goes away by itself. "Riprova" reads
/// the state again at once. On iPhone / iPad what does not need the internet stays reachable: the downloads (they play
/// from the device) and the remote of the TV (it only talks to the home network). Same buttons as Android's VpnGateScreen.
struct VpnGateView: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.openURL) private var openURL
    @State private var checking = false
    @State private var vpnApp: VpnApps.Link? = nil

    var body: some View {
        GateFrame {
            GeometryReader { g in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: Metrics.u(14)) {
                    Image(systemName: "lock.shield.fill").font(.system(size: 54 * Metrics.unit, weight: .regular)).foregroundStyle(.white)
                    Text("Accendi la VPN").font(NxFont.titleXL).foregroundStyle(NxColor.text).multilineTextAlignment(.center)
                    Text("Apri l'app della VPN, collegati e torna qui: la schermata sparisce da sola.")
                        .font(NxFont.body).foregroundStyle(NxColor.textMuted).multilineTextAlignment(.center)
                    HStack(spacing: 6) {
                        Circle().fill(NxColor.accent).frame(width: Metrics.u(8), height: Metrics.u(8))
                        Text(checking ? "Controllo…" : "VPN non rilevata").font(NxFont.caption).foregroundStyle(NxColor.textDim)
                    }
                    VStack(spacing: Metrics.u(10)) {
                        if let v = vpnApp {
                            NxButton("Apri \(v.name)", icon: "arrow.up.forward.app", kind: .primary, wide: true) { openURL(v.url) }
                        } else {
                            // no known VPN app found: the system settings (VPN lives there), NordVPN's link first just in case
                            NxButton("Apri l'app della VPN", icon: "arrow.up.forward.app", kind: .primary, wide: true) {
                                if let u = URL(string: "nordvpn://") {
                                    openURL(u) { ok in if !ok, let s = URL(string: UIApplication.openSettingsURLString) { openURL(s) } }
                                }
                            }
                        }
                        NxButton("Riprova", icon: "arrow.clockwise", wide: true) { retry() }
                        #if os(iOS)
                        // what is downloaded plays without the VPN; the remote never leaves the home network
                        NxButton("Guarda i download", icon: "arrow.down.to.line", wide: true) { app.offlineDownloads = true }
                        NxButton("Telecomando della TV", icon: "appletvremote.gen4", wide: true) { app.gateRemote = true }
                        #endif
                    }
                    .padding(.top, Metrics.u(10))
                    #if os(tvOS)
                    .focusSection()
                    #endif
                }
                .padding(Metrics.u(28))
                .frame(maxWidth: Metrics.u(400))
                .padding(.top, Metrics.u(Metrics.tv ? 60 : 40))
                .frame(maxWidth: .infinity, minHeight: g.size.height)
            }
            }
        }
        .onAppear { vpnApp = VpnApps.installed() }
    }

    private func retry() {
        checking = true
        Vpn.shared.refresh()
        Task { try? await Task.sleep(nanoseconds: 1_200_000_000); checking = false }
    }
}

/// The VPN apps whose link we know, first installed one wins (Android: Vpn.VPN_APPS). The schemes are listed in
/// LSApplicationQueriesSchemes, otherwise the system always says "not installed".
enum VpnApps {
    struct Link { let name: String; let url: URL }
    private static let known: [(String, String)] = [
        ("NordVPN", "nordvpn://"), ("ExpressVPN", "expressvpn://"), ("Surfshark", "surfshark://"), ("Proton VPN", "protonvpn://"),
        ("PIA VPN", "piavpn://"), ("Mullvad VPN", "mullvadvpn://"), ("WireGuard", "wireguard://"),
    ]
    static let schemes = known.map { $0.1.replacingOccurrences(of: "://", with: "") }
    @MainActor static func installed() -> Link? {
        for (name, link) in known { if let u = URL(string: link), UIApplication.shared.canOpenURL(u) { return Link(name: name, url: u) } }
        return nil
    }
}

// ---------------------------------------------------------------------------------------------------------------- login

struct LoginView: View {
    @EnvironmentObject var app: AppModel
    @State private var username = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String? = nil
    @State private var showPassword = false
    @State private var phone = false
    @FocusState private var focus: Field?
    private enum Field { case user, pass }

    var body: some View {
        GateFrame {
            #if os(tvOS)
            if phone { PhoneLoginPanel { phone = false } } else { form }
            #else
            form
            #endif
        }
        .onAppear {
            if let u = ProcessInfo.processInfo.environment["NX_USER"], let p = ProcessInfo.processInfo.environment["NX_PASS"] { username = u; password = p; submit() }
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: Metrics.u(14)) {
            Text("Accedi").font(NxFont.display(30, .bold)).foregroundStyle(NxColor.text)
            Text("L'indirizzo del server è automatico: bastano nome utente e password della tua linea.").font(NxFont.meta).foregroundStyle(NxColor.textDim)
            NxField {
                TextField("", text: $username, prompt: Text("Nome utente").foregroundColor(NxColor.textDim))
                    .textContentType(.username).autocorrectionDisabled().textInputAutocapitalization(.never)
                    .focused($focus, equals: .user).submitLabel(.next).onSubmit { focus = .pass }
            }
            NxField {
                Group {
                    if showPassword { TextField("", text: $password, prompt: Text("Password").foregroundColor(NxColor.textDim)) }
                    else { SecureField("", text: $password, prompt: Text("Password").foregroundColor(NxColor.textDim)) }
                }
                .textContentType(.password).autocorrectionDisabled().textInputAutocapitalization(.never)
                .focused($focus, equals: .pass).submitLabel(.go).onSubmit { submit() }
                #if os(iOS)
                Button { showPassword.toggle() } label: {
                    Text(showPassword ? "NASCONDI" : "MOSTRA").font(NxFont.ui(11, .heavy)).foregroundStyle(NxColor.textMuted)
                }
                .buttonStyle(NxPlainStyle(scale: 0.95))
                #endif
            }
            if let e = error {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(e)
                }
                .font(NxFont.meta).foregroundStyle(NxColor.ember)
            }
            NxButton(busy ? "Accesso in corso…" : "Accedi", kind: .primary, wide: true) { submit() }
                .disabled(busy || username.trimmed.isEmpty || password.isEmpty)
                .padding(.top, Metrics.u(4))
            #if os(tvOS)
            NxButton("Accedi dal telefono", icon: "qrcode", wide: true) { phone = true }
            #endif
        }
        .padding(Metrics.u(24))
        .frame(maxWidth: Metrics.u(440))
        #if os(tvOS)
        .focusSection()
        #endif
    }

    private func submit() {
        let u = username.trimmed, p = password.trimmed
        guard !busy, !u.isEmpty, !p.isEmpty else { return }
        busy = true; error = nil
        Task {
            let r = await app.core.loginRepo.login(username: u, password: p)
            busy = false
            switch r {
            case .success: app.core.syncIfNeeded(force: true)
            case .notFound: error = "Nome utente non trovato. Controlla di averlo scritto giusto."
            case .authFailed: error = "Password sbagliata."
            case .expired: error = "La linea è scaduta o sospesa."
            case .error(let m): error = m
            }
        }
    }
}

// ---------------------------------------------------------------------------------------------------------------- profiles

/// "Chi guarda?": pick a profile (PIN if it has one), create one, or manage them all.
struct ProfilesView: View {
    var manage = false
    var onDone: (() -> Void)? = nil
    @EnvironmentObject var app: AppModel
    @State private var profiles: [ProfileEntity] = []
    @State private var editing = false

    private var editMode: Bool { manage || editing }
    private let columns = [GridItem(.adaptive(minimum: Metrics.u(100), maximum: Metrics.u(130)), spacing: Metrics.u(22))]

    var body: some View {
        GateFrame(brand: !manage) {
            VStack(spacing: Metrics.u(26)) {
                Text(editMode ? "Gestisci i profili" : "Chi guarda?").font(NxFont.display(24, .bold)).foregroundStyle(NxColor.text)
                LazyVGrid(columns: columns, spacing: Metrics.u(22)) {
                    ForEach(profiles) { p in
                        tile(name: p.name, action: {
                            if editMode { edit(p) } else if p.pin != nil { askPin(p) } else { app.core.profiles.select(p) }
                        }) {
                            ZStack {
                                p.face(96).opacity(editMode ? 0.5 : 1)
                                if editMode { Image(systemName: "pencil").font(.system(size: 30 * Metrics.unit, weight: .semibold)).foregroundStyle(.white) }
                                else if p.pin != nil {
                                    Image(systemName: "lock.fill").font(.system(size: 12 * Metrics.unit, weight: .bold)).foregroundStyle(.white)
                                        .padding(Metrics.u(5)).background(Color.black.opacity(0.55), in: Circle())
                                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(Metrics.u(5))
                                }
                            }
                            .frame(width: Metrics.u(96), height: Metrics.u(96))
                        }
                    }
                    if profiles.count < 5 {
                        tile(name: "Aggiungi", action: { edit(nil) }) {
                            ZStack {
                                RoundedRectangle(cornerRadius: Metrics.u(96) * 0.26, style: .continuous).stroke(NxColor.ink5, lineWidth: Metrics.u(1.5))
                                Image(systemName: "plus").font(.system(size: 34 * Metrics.unit, weight: .light)).foregroundStyle(NxColor.textMuted)
                            }
                            .frame(width: Metrics.u(96), height: Metrics.u(96))
                        }
                    }
                }
                .frame(maxWidth: Metrics.u(Metrics.tv ? 560 : 300))
                if manage { NxButton("Fine", kind: .primary) { onDone?() } }
                else if editing { NxButton("Fine", kind: .primary) { editing = false } }
                else if !profiles.isEmpty { NxButton("Gestisci i profili", icon: "pencil", kind: .quiet) { editing = true } }
            }
            .padding(Metrics.u(24))
        }
        .onAppear { reload(); if !manage { app.autoSelectProfile() } }
    }

    private func reload() { profiles = app.core.profiles.all() }

    private func edit(_ p: ProfileEntity?) {
        let taken = profiles
        let select = !manage && !editing
        app.present(p == nil ? "Nuovo profilo" : "Modifica profilo", style: .page) {
            ProfileEditor(profile: p, taken: taken) { created in
                app.dismissSheet()
                reload()
                if let c = created, p == nil, select { app.onboardingFor = c.id; app.core.profiles.select(c) }
            }
        }
    }

    private func askPin(_ p: ProfileEntity) {
        app.present(nil, style: .dialog) {
            PinPad(title: "PIN di \(p.name)") { pin in
                if pin == p.pin { app.dismissSheet(); app.core.profiles.select(p); return true }
                return false
            } onCancel: { app.dismissSheet() }
        }
    }

    private func tile<Face: View>(name: String, action: @escaping () -> Void, @ViewBuilder face: () -> Face) -> some View {
        let f = face()
        return VStack(spacing: Metrics.u(8)) {
            CardButton(action: action, radius: Metrics.u(96) * 0.26) { f }
            Text(name).font(NxFont.ui(14, .semibold)).foregroundStyle(NxColor.textMuted).lineLimit(1)
        }
    }
}

/// Create or edit a profile: name, colour, icon, who it is for, PIN.
struct ProfileEditor: View {
    let profile: ProfileEntity?
    let taken: [ProfileEntity]
    let onClose: (ProfileEntity?) -> Void
    @EnvironmentObject var app: AppModel
    @State private var name = ""
    @State private var color = 0
    @State private var icon = 0
    @State private var maturity = 2
    @State private var pin: String? = nil
    @State private var error: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.u(18)) {
            HStack(spacing: Metrics.u(16)) {
                AvatarFace(name: name.isEmpty ? "?" : name, color: color, kids: maturity == 0, icon: icon, size: 72)
                NxField {
                    TextField("", text: $name, prompt: Text("Nome del profilo").foregroundColor(NxColor.textDim))
                        .autocorrectionDisabled()
                        .onChange(of: name) { _, v in if v.count > 16 { name = String(v.prefix(16)) } }
                }
            }
            group("COLORE") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: Metrics.u(44)), spacing: Metrics.u(10))], spacing: Metrics.u(10)) {
                    ForEach(0..<Avatars.colors.count, id: \.self) { i in
                        swatch(selected: color == i, action: { color = i }) { Circle().fill(Avatars.gradient(i)) }
                    }
                }
            }
            group("ICONA") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: Metrics.u(44)), spacing: Metrics.u(10))], spacing: Metrics.u(10)) {
                    ForEach(0..<Avatars.icons.count, id: \.self) { i in
                        swatch(selected: icon == i, action: { icon = i }) {
                            ZStack {
                                Circle().fill(icon == i ? AnyShapeStyle(Avatars.gradient(color)) : AnyShapeStyle(NxColor.ink4))
                                if let s = Avatars.icons[i] { Image(systemName: s).font(.system(size: 17 * Metrics.unit, weight: .semibold)).foregroundStyle(.white) }
                                else { Text(String(name.prefix(1)).uppercased().isEmpty ? "A" : String(name.prefix(1)).uppercased()).font(NxFont.display(16, .bold)).foregroundStyle(.white) }
                            }
                        }
                    }
                }
            }
            group("PER CHI È") {
                HStack(spacing: Metrics.u(8)) {
                    ForEach(0..<3, id: \.self) { i in NxChip(title: Avatars.maturityLabels[i], selected: maturity == i) { maturity = i } }
                }
                Text(maturity == 0 ? "Solo canali e titoli per bambini." : (maturity == 1 ? "Niente horror tra i titoli on demand." : "Nessun filtro."))
                    .font(NxFont.caption).foregroundStyle(NxColor.textDim)
            }
            group("PIN") {
                HStack(spacing: Metrics.u(10)) {
                    NxButton(pin == nil ? "Imposta un PIN" : "Cambia PIN", icon: "lock") {
                        app.present(nil, style: .dialog) {
                            PinPad(title: "Scegli un PIN di 4 cifre") { p in pin = p; app.dismissSheet(); return true } onCancel: { app.dismissSheet() }
                        }
                    }
                    if pin != nil { NxButton("Togli", kind: .quiet) { pin = nil } }
                }
                Text(pin == nil ? "Senza PIN chiunque può entrare in questo profilo." : "Serve il PIN di 4 cifre per entrare.").font(NxFont.caption).foregroundStyle(NxColor.textDim)
            }
            if let e = error { Text(e).font(NxFont.meta).foregroundStyle(NxColor.ember) }
            VStack(spacing: Metrics.u(8)) {
                NxButton("Salva", kind: .primary, wide: true) { save() }.disabled(name.trimmed.isEmpty)
                if let p = profile {
                    NxButton("Elimina il profilo", icon: "trash", kind: .danger, wide: true) {
                        app.confirm("Eliminare \(p.name)?", message: "Preferiti, lista e cronologia di questo profilo vanno persi.", confirm: "Elimina profilo e dati", destructive: true) {
                            app.core.profiles.delete(p)
                            onClose(nil)
                        }
                    }
                }
            }
            .padding(.top, Metrics.u(6))
        }
        .padding(.horizontal, Metrics.u(18)).padding(.top, Metrics.u(6))
        .onAppear {
            if let p = profile { name = p.name; color = p.avatarColor; icon = p.avatarIcon; maturity = p.level; pin = p.pin }
            else { color = (0..<Avatars.colors.count).first { i in !taken.contains { $0.avatarColor == i } } ?? 0 }
        }
    }

    private func swatch<C: View>(selected: Bool, action: @escaping () -> Void, @ViewBuilder _ content: () -> C) -> some View {
        let c = content()
        return Button(action: action) {
            Focusable { focused in
                c.frame(width: Metrics.u(40), height: Metrics.u(40))
                    .overlay(Circle().stroke(Color.white, lineWidth: selected || focused ? Metrics.u(2.5) : 0))
                    .scaleEffect(focused ? 1.15 : 1)
            }
        }
        .buttonStyle(NxPlainStyle(scale: 0.92))
    }

    private func group<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Metrics.u(8)) {
            Text(label).font(NxFont.label).tracking(1).foregroundStyle(NxColor.textDim)
            content()
        }
    }

    private func save() {
        let n = name.trimmed
        if taken.contains(where: { $0.name.equalsIgnoringCase(n) && $0.id != profile?.id }) { error = "Esiste già un profilo con questo nome."; return }
        if var p = profile {
            p.name = n; p.avatarColor = color; p.avatarIcon = icon; p.kids = maturity == 0; p.maturity = maturity; p.pin = pin
            app.core.profiles.update(p)
            onClose(p)
        } else {
            let id = app.core.profiles.add(name: n, color: color, kids: maturity == 0, icon: icon, maturity: maturity, pin: pin)
            onClose(app.core.profiles.all().first { $0.id == id })
        }
    }
}

/// Four digits, big keys. `onEntered` says whether the PIN was right (a wrong one shakes and clears).
struct PinPad: View {
    let title: String
    let onEntered: (String) -> Bool
    let onCancel: () -> Void
    @State private var digits = ""
    @State private var wrong = false

    var body: some View {
        VStack(spacing: Metrics.u(18)) {
            Text(title).font(NxFont.titleM).foregroundStyle(NxColor.text).multilineTextAlignment(.center)
            HStack(spacing: Metrics.u(12)) {
                ForEach(0..<4, id: \.self) { i in
                    RoundedRectangle(cornerRadius: Metrics.u(4), style: .continuous)
                        .stroke(i == digits.count ? Color.white : NxColor.ink5, lineWidth: Metrics.u(1.5))
                        .frame(width: Metrics.u(40), height: Metrics.u(48))
                        .overlay { if i < digits.count { Circle().fill(Color.white).frame(width: Metrics.u(11), height: Metrics.u(11)) } }
                }
            }
            .offset(x: wrong ? -8 : 0)
            .animation(wrong ? .default.repeatCount(3, autoreverses: true).speed(4) : .default, value: wrong)
            Text(wrong ? "PIN sbagliato" : " ").font(NxFont.caption).foregroundStyle(NxColor.ember)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(Metrics.u(68)), spacing: Metrics.u(12)), count: 3), spacing: Metrics.u(10)) {
                ForEach(["1", "2", "3", "4", "5", "6", "7", "8", "9", "", "0", "<"], id: \.self) { k in
                    if k.isEmpty { Color.clear.frame(width: Metrics.u(68), height: Metrics.u(52)) }
                    else {
                        Button { press(k) } label: {
                            Focusable { focused in
                                Group { if k == "<" { Image(systemName: "delete.left") } else { Text(k) } }
                                    .font(NxFont.display(21, .semibold)).foregroundStyle(focused ? Color.black : Color.white)
                                    .frame(width: Metrics.u(68), height: Metrics.u(52))
                                    .background(focused ? Color.white : (k == "<" ? Color.clear : NxColor.ink5), in: RoundedRectangle(cornerRadius: Metrics.u(6), style: .continuous))
                            }
                        }
                        .buttonStyle(NxPlainStyle(scale: 0.93))
                    }
                }
            }
            NxButton("Annulla", kind: .quiet, action: onCancel)
        }
    }

    private func press(_ k: String) {
        wrong = false
        if k == "<" { if !digits.isEmpty { digits.removeLast() }; return }
        if digits.count >= 4 { return }
        digits += k
        if digits.count == 4 {
            let entered = digits
            if !onEntered(entered) { wrong = true; digits = "" }
        }
    }
}

// ---------------------------------------------------------------------------------------------------------------- onboarding

/// Taste picker shown once after a profile is created: three titles are enough for the first "Scelti per te".
struct OnboardingView: View {
    let profileId: Int64
    let onDone: () -> Void
    @EnvironmentObject var app: AppModel
    @State private var titles: [TmdbTitle]? = nil
    @State private var picked = Set<String>()

    var body: some View {
        VStack(spacing: Metrics.u(12)) {
            VStack(spacing: Metrics.u(6)) {
                Text("Cosa ti piace guardare?").font(NxFont.titleL).foregroundStyle(NxColor.text)
                Text("Scegline almeno 3: ti proponiamo subito titoli giusti per te.").font(NxFont.meta).foregroundStyle(NxColor.textDim).multilineTextAlignment(.center)
            }
            .padding(.top, Metrics.u(22)).padding(.horizontal, Metrics.u(20))
            if let list = titles {
                if list.isEmpty { StateMessage(icon: "film", title: "Nessun titolo disponibile al momento", text: "Puoi saltare questo passaggio.") }
                else {
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: Metrics.posterW * 0.9), spacing: Metrics.cardGap)], spacing: Metrics.u(10)) {
                            ForEach(list) { t in
                                let on = picked.contains(t.key)
                                PosterCard(title: t, width: Metrics.posterW * 0.9, menu: false) { if on { picked.remove(t.key) } else { picked.insert(t.key) } }
                                    .overlay(alignment: .topTrailing) {
                                        if on { Image(systemName: "checkmark.circle.fill").font(.system(size: 26 * Metrics.unit)).foregroundStyle(.white, NxColor.accent).padding(6).allowsHitTesting(false) }
                                    }
                                    .opacity(picked.isEmpty || on ? 1 : 0.6)
                            }
                        }
                        .padding(.horizontal, Metrics.gutter).padding(.vertical, Metrics.u(12))
                    }
                }
            } else { BrandLoader(label: "Preparo una selezione…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            HStack(spacing: Metrics.u(12)) {
                NxButton("Salta", kind: .quiet) { onDone() }
                NxButton(picked.count >= 3 ? "Continua" : "Scegline ancora \(3 - picked.count)", kind: .primary) { finish() }.disabled(picked.count < 3)
            }
            .padding(.bottom, Metrics.u(18))
        }
        .nxPage()
        .task { titles = await app.core.catalog.onboardingPicks(app.core.profiles.all().first { $0.id == profileId }?.kids ?? false) }
    }

    private func finish() {
        let chosen = (titles ?? []).filter { picked.contains($0.key) }
        Task {
            for t in chosen {
                _ = await app.core.catalog.ensureTitle(t.tmdbId, t.media)   // the recommender needs the title facts
                app.core.library.like(profileId, t.tmdbId, t.media)
                if !app.core.library.isInList(profileId, t.tmdbId, t.media) { app.core.library.toggleList(profileId, t.tmdbId, t.media, currently: false) }
            }
            onDone()
        }
    }
}
