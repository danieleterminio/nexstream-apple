import SwiftUI

/// Backdrop of the gate screens: ink with a soft glow of the brand colours, so the glass panels have something to bend.
struct GateBackground: View {
    var body: some View {
        ZStack {
            NxColor.bg
            RadialGradient(colors: [NxColor.accent.opacity(0.38), .clear], center: .topLeading, startRadius: 0, endRadius: Metrics.u(520))
            RadialGradient(colors: [NxColor.ember.opacity(0.22), .clear], center: .bottomTrailing, startRadius: 0, endRadius: Metrics.u(480))
        }
        .ignoresSafeArea()
    }
}

// ---------------------------------------------------------------------------------------------------------------- VPN

/// Nothing leaves the device without the VPN: this screen stays until one is up, then goes away by itself.
struct VpnGateView: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        ZStack {
            GateBackground()
            VStack(spacing: Metrics.u(16)) {
                Image(systemName: "lock.shield.fill").font(.system(size: 52 * Metrics.unit, weight: .regular)).foregroundStyle(NxColor.brand)
                Text("Accendi la VPN").font(NxFont.titleXL).foregroundStyle(NxColor.text)
                Text("Apri l'app della VPN, collegati e torna qui: la schermata sparisce da sola.")
                    .font(NxFont.body).foregroundStyle(NxColor.textMuted).multilineTextAlignment(.center)
                #if os(iOS)
                NxButton("Apri NordVPN", icon: "arrow.up.forward.app", kind: .primary) {
                    if let u = URL(string: "nordvpn://") { openURL(u) { ok in if !ok, let s = URL(string: "App-prefs:") { openURL(s) } } }
                }
                .padding(.top, Metrics.u(4))
                if app.core.db.downloads().contains(where: { $0.state == "done" }) {
                    NxButton("Guarda i download", icon: "arrow.down.circle") { app.offlineDownloads = true }
                }
                #endif
                HStack(spacing: 6) {
                    Circle().fill(NxColor.accent).frame(width: Metrics.u(8), height: Metrics.u(8))
                    Text("Stato: VPN non rilevata").font(NxFont.caption).foregroundStyle(NxColor.textDim)
                }
                .padding(.top, Metrics.u(6))
            }
            .padding(Metrics.u(28))
            .frame(maxWidth: Metrics.u(440))
            .nxGlassPanel()
            .padding(Metrics.u(20))
        }
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
    @FocusState private var focus: Field?
    private enum Field { case user, pass, go }

    var body: some View {
        ZStack {
            GateBackground()
            VStack(alignment: .leading, spacing: Metrics.u(14)) {
                Image("BrandLockup").resizable().scaledToFit().frame(height: Metrics.u(40))
                Text("Accedi alla tua linea").font(NxFont.titleL).foregroundStyle(NxColor.text)
                Text("L'indirizzo del server è automatico: bastano nome utente e password.").font(NxFont.meta).foregroundStyle(NxColor.textDim)
                field("NOME UTENTE") {
                    TextField("Nome utente", text: $username)
                        .textContentType(.username).autocorrectionDisabled().textInputAutocapitalization(.never)
                        .focused($focus, equals: .user).submitLabel(.next).onSubmit { focus = .pass }
                }
                field("PASSWORD") {
                    HStack {
                        Group {
                            if showPassword { TextField("Password", text: $password) } else { SecureField("Password", text: $password) }
                        }
                        .textContentType(.password).autocorrectionDisabled().textInputAutocapitalization(.never)
                        .focused($focus, equals: .pass).submitLabel(.go).onSubmit { submit() }
                        #if os(iOS)
                        Button { showPassword.toggle() } label: { Image(systemName: showPassword ? "eye.slash" : "eye").foregroundStyle(NxColor.textDim) }.buttonStyle(.plain)
                        #endif
                    }
                }
                if let e = error {
                    Label(e, systemImage: "exclamationmark.triangle.fill").font(NxFont.meta).foregroundStyle(NxColor.accentBright)
                } else if busy {
                    HStack(spacing: 8) { ProgressView(); Text("Accesso in corso…").font(NxFont.meta).foregroundStyle(NxColor.textMuted) }
                }
                NxButton("Accedi", icon: "arrow.right", kind: .primary, wide: true) { submit() }
                    .disabled(busy || username.trimmed.isEmpty || password.isEmpty)
                    .focused($focus, equals: .go)
                    .padding(.top, Metrics.u(4))
            }
            .padding(Metrics.u(26))
            .frame(maxWidth: Metrics.u(460))
            .nxGlassPanel()
            .padding(Metrics.u(18))
        }
        .onAppear {
            if let u = ProcessInfo.processInfo.environment["NX_USER"], let p = ProcessInfo.processInfo.environment["NX_PASS"] { username = u; password = p; submit() }
        }
    }

    @ViewBuilder private func field<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Metrics.u(6)) {
            Text(label).font(NxFont.label).tracking(1).foregroundStyle(NxColor.textDim)
            #if os(tvOS)
            content()
            #else
            content()
                .font(NxFont.ui(17))
                .padding(.horizontal, 14).padding(.vertical, 13)
                .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(NxColor.hairline, lineWidth: 1))
            #endif
        }
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
    @State private var editing: ProfileEntity? = nil
    @State private var creating = false
    @State private var pinFor: ProfileEntity? = nil
    @State private var loaded = false

    private let columns = [GridItem(.adaptive(minimum: Metrics.u(104), maximum: Metrics.u(150)), spacing: Metrics.u(18))]

    var body: some View {
        ZStack {
            GateBackground()
            ScrollView {
                VStack(spacing: Metrics.u(22)) {
                    if !manage { Image("BrandLockup").resizable().scaledToFit().frame(height: Metrics.u(34)).padding(.top, Metrics.u(30)) }
                    Text(manage ? "Gestisci i profili" : "Chi guarda?").font(NxFont.titleXL).foregroundStyle(NxColor.text)
                    LazyVGrid(columns: columns, spacing: Metrics.u(20)) {
                        ForEach(profiles) { p in
                            tile(name: p.name, sub: manage ? "Modifica" : (p.pin != nil ? "PIN" : (p.kids ? "Bambini" : nil))) { p.face(84) } action: {
                                if manage { editing = p } else if p.pin != nil { pinFor = p } else { app.core.profiles.select(p) }
                            }
                        }
                        if profiles.count < 8 {
                            tile(name: "Nuovo profilo", sub: nil) {
                                ZStack { RoundedRectangle(cornerRadius: Metrics.u(22), style: .continuous).fill(Color.white.opacity(0.08)); Image(systemName: "plus").font(.system(size: 30 * Metrics.unit, weight: .medium)).foregroundStyle(NxColor.textMuted) }
                                    .frame(width: Metrics.u(84), height: Metrics.u(84))
                            } action: { creating = true }
                        }
                    }
                    .frame(maxWidth: Metrics.u(640))
                    if manage { NxButton("Fine", kind: .primary) { onDone?() } }
                    else if !profiles.isEmpty { NxButton("Gestisci i profili", icon: "pencil") { editing = nil; app.manageProfilesGate = true } }
                }
                .padding(Metrics.u(24))
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear { reload(); if !manage { app.autoSelectProfile() } }
        .sheet(isPresented: $creating, onDismiss: reload) {
            ProfileEditor(profile: nil, taken: profiles) { created in
                creating = false
                if let c = created, !manage { app.onboardingFor = c.id; app.core.profiles.select(c) }
            }
        }
        .sheet(item: $editing, onDismiss: reload) { p in ProfileEditor(profile: p, taken: profiles) { _ in editing = nil } }
        .sheet(item: $pinFor) { p in
            PinPad(title: "PIN di \(p.name)") { pin in
                if pin == p.pin { pinFor = nil; app.core.profiles.select(p); return true }
                return false
            } onCancel: { pinFor = nil }
        }
    }

    private func reload() { profiles = app.core.profiles.all(); loaded = true }

    private func tile<Face: View>(name: String, sub: String?, @ViewBuilder face: () -> Face, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: Metrics.u(8)) {
                face()
                Text(name).font(NxFont.bodyStrong).foregroundStyle(NxColor.text).lineLimit(1)
                Text(sub ?? " ").font(NxFont.caption).foregroundStyle(NxColor.textDim).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Metrics.u(8))
        }
        #if os(tvOS)
        .buttonStyle(.card)
        #else
        .buttonStyle(PressScaleStyle())
        #endif
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
    @State private var askPin = false
    @State private var confirmDelete = false
    @State private var error: String? = nil

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.u(18)) {
                    HStack(spacing: Metrics.u(16)) {
                        AvatarFace(name: name.isEmpty ? "?" : name, color: color, kids: maturity == 0, icon: icon, size: 72)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("NOME").font(NxFont.label).tracking(1).foregroundStyle(NxColor.textDim)
                            TextField("Nome del profilo", text: $name).font(NxFont.ui(18, .semibold))
                                .onChange(of: name) { _, v in if v.count > 16 { name = String(v.prefix(16)) } }
                        }
                    }
                    group("COLORE") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: Metrics.u(44)), spacing: Metrics.u(10))], spacing: Metrics.u(10)) {
                            ForEach(0..<Avatars.colors.count, id: \.self) { i in
                                Button { color = i } label: {
                                    Circle().fill(Avatars.gradient(i)).frame(width: Metrics.u(40), height: Metrics.u(40))
                                        .overlay(Circle().stroke(Color.white, lineWidth: color == i ? 3 : 0))
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                    group("ICONA") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: Metrics.u(44)), spacing: Metrics.u(10))], spacing: Metrics.u(10)) {
                            ForEach(0..<Avatars.icons.count, id: \.self) { i in
                                Button { icon = i } label: {
                                    ZStack {
                                        Circle().fill(icon == i ? AnyShapeStyle(Avatars.gradient(color)) : AnyShapeStyle(Color.white.opacity(0.08)))
                                        if let s = Avatars.icons[i] { Image(systemName: s).font(.system(size: 17 * Metrics.unit, weight: .semibold)).foregroundStyle(.white) }
                                        else { Text(String(name.prefix(1)).uppercased().isEmpty ? "A" : String(name.prefix(1)).uppercased()).font(NxFont.display(16, .bold)).foregroundStyle(.white) }
                                    }.frame(width: Metrics.u(40), height: Metrics.u(40))
                                }.buttonStyle(.plain)
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
                            NxButton(pin == nil ? "Imposta un PIN" : "Cambia PIN", icon: "lock") { askPin = true }
                            if pin != nil { NxButton("Togli", kind: .quiet) { pin = nil } }
                        }
                        Text(pin == nil ? "Senza PIN chiunque può entrare in questo profilo." : "Serve il PIN di 4 cifre per entrare.").font(NxFont.caption).foregroundStyle(NxColor.textDim)
                    }
                    if let e = error { Text(e).font(NxFont.meta).foregroundStyle(NxColor.accentBright) }
                    if profile != nil {
                        NxButton("Elimina il profilo", icon: "trash", kind: .danger) { confirmDelete = true }.padding(.top, Metrics.u(6))
                    }
                }
                .padding(Metrics.u(20))
            }
            .nxPage()
            .navigationTitle(profile == nil ? "Nuovo profilo" : "Modifica profilo")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annulla") { onClose(nil) } }
                ToolbarItem(placement: .confirmationAction) { Button("Salva") { save() }.disabled(name.trimmed.isEmpty) }
            }
        }
        .onAppear {
            if let p = profile { name = p.name; color = p.avatarColor; icon = p.avatarIcon; maturity = p.level; pin = p.pin }
            else { color = (0..<Avatars.colors.count).first { i in !taken.contains { $0.avatarColor == i } } ?? 0 }
        }
        .sheet(isPresented: $askPin) {
            PinPad(title: "Scegli un PIN di 4 cifre") { p in pin = p; askPin = false; return true } onCancel: { askPin = false }
        }
        .confirmationDialog("Eliminare questo profilo?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Elimina profilo e dati", role: .destructive) { if let p = profile { app.core.profiles.delete(p) }; onClose(nil) }
            Button("Annulla", role: .cancel) {}
        } message: { Text("Preferiti, Da guardare e cronologia di questo profilo vanno persi.") }
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
        VStack(spacing: Metrics.u(22)) {
            Text(title).font(NxFont.titleM).foregroundStyle(NxColor.text)
            HStack(spacing: Metrics.u(14)) {
                ForEach(0..<4, id: \.self) { i in
                    Circle().fill(i < digits.count ? Color.white : Color.white.opacity(0.18)).frame(width: Metrics.u(14), height: Metrics.u(14))
                }
            }
            .offset(x: wrong ? -8 : 0)
            .animation(wrong ? .default.repeatCount(3, autoreverses: true).speed(4) : .default, value: wrong)
            if wrong { Text("PIN sbagliato").font(NxFont.caption).foregroundStyle(NxColor.accentBright) }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(Metrics.u(72)), spacing: Metrics.u(14)), count: 3), spacing: Metrics.u(14)) {
                ForEach(["1", "2", "3", "4", "5", "6", "7", "8", "9", "", "0", "<"], id: \.self) { k in
                    if k.isEmpty { Color.clear.frame(width: Metrics.u(72), height: Metrics.u(60)) }
                    else {
                        Button { press(k) } label: {
                            Group { if k == "<" { Image(systemName: "delete.left") } else { Text(k) } }
                                .font(NxFont.display(22, .semibold)).foregroundStyle(NxColor.text)
                                .frame(width: Metrics.u(72), height: Metrics.u(60))
                        }
                        #if os(tvOS)
                        .buttonStyle(.glass)
                        #else
                        .buttonStyle(.plain)
                        .glassEffect(Glass.regular.interactive(), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        #endif
                    }
                }
            }
            NxButton("Annulla", kind: .quiet, action: onCancel)
        }
        .padding(Metrics.u(26))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NxColor.bg.ignoresSafeArea())
        .presentationDetents([.medium, .large])
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
        VStack(spacing: Metrics.u(14)) {
            VStack(spacing: Metrics.u(6)) {
                Text("Cosa ti piace guardare?").font(NxFont.titleL).foregroundStyle(NxColor.text)
                Text("Scegline almeno 3: ti proponiamo subito titoli giusti per te.").font(NxFont.meta).foregroundStyle(NxColor.textDim).multilineTextAlignment(.center)
            }
            .padding(.top, Metrics.u(22)).padding(.horizontal, Metrics.u(20))
            if let list = titles {
                if list.isEmpty { StateMessage(icon: "film", title: "Nessun titolo disponibile al momento", text: "Puoi saltare questo passaggio.") }
                else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: Metrics.posterW * 0.86), spacing: Metrics.cardGap)], spacing: Metrics.cardGap) {
                            ForEach(list) { t in
                                let on = picked.contains(t.key)
                                PosterCard(title: t, width: Metrics.posterW * 0.86) { if on { picked.remove(t.key) } else { picked.insert(t.key) } }
                                    .overlay(alignment: .topTrailing) {
                                        if on { Image(systemName: "checkmark.circle.fill").font(.system(size: 26 * Metrics.unit)).foregroundStyle(.white, NxColor.accent).padding(6) }
                                    }
                                    .opacity(picked.isEmpty || on ? 1 : 0.72)
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
