import SwiftUI

/// "Nuova versione disponibile": the Apple side of app updates (Android blocks and installs by itself). A panel of our
/// own (SheetHost), shown once per version, never a system alert; Settings → Informazioni keeps a line for it.
extension AppModel {
    /// Reads the manifest if due, then offers a new release once it can be seen (an open app, no player, no panel).
    func checkForUpdate(force: Bool = false) {
        Task { @MainActor in
            await AppUpdates.shared.checkIfDue(force: force)
            offerUpdateWhenFree(tries: 20)
        }
    }

    private func offerUpdateWhenFree(tries: Int) {
        let u = AppUpdates.shared
        guard let r = u.available, !u.seen(r) else { return }
        // the opening plays first: the notice comes right after it, never under or over it
        if !NxIntro.done {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 500_000_000)
                self.offerUpdateWhenFree(tries: tries)
            }
            return
        }
        if vpn, session != nil, profile != nil, onboardingFor == nil, playing == nil, sheets.isEmpty {
            u.markSeen(r)
            presentUpdate(r)
            return
        }
        guard tries > 0 else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            self.offerUpdateWhenFree(tries: tries - 1)
        }
    }

    func presentUpdate(_ r: AppleRelease) {
        present(nil, style: .dialog) { UpdateNoticePanel(release: r) }
    }
}

struct UpdateNoticePanel: View {
    @EnvironmentObject var app: AppModel
    let release: AppleRelease
    #if os(tvOS)
    @FocusState private var ok: Bool
    #endif

    private var how: String {
        #if os(tvOS)
        return "Si installa dal PC come sempre (atvloadly): basta mettere il nuovo file al posto di quello vecchio."
        #else
        return "Si installa come sempre, firmando il nuovo file per questo iPhone."
        #endif
    }

    var body: some View {
        VStack(spacing: Metrics.u(12)) {
            Text(AppUpdates.shared.required(release) ? "AGGIORNAMENTO CONSIGLIATO" : "NUOVA VERSIONE")
                .font(NxFont.label).tracking(1).foregroundStyle(.white)
                .padding(.horizontal, Metrics.u(8)).padding(.vertical, Metrics.u(3))
                .background(NxColor.accent, in: RoundedRectangle(cornerRadius: Metrics.u(3), style: .continuous))
            Text("Nuova versione disponibile \(release.versionName)").font(NxFont.titleM).foregroundStyle(NxColor.text).multilineTextAlignment(.center)
            Text("Hai la \(AppUpdates.installedName). \(how)").font(NxFont.meta).foregroundStyle(NxColor.textMuted).multilineTextAlignment(.center)
            if !release.notes.isEmpty {
                VStack(alignment: .leading, spacing: Metrics.u(6)) {
                    Text("Novità").font(NxFont.bodyStrong).foregroundStyle(NxColor.text)
                    ForEach(Array(release.notes.enumerated()), id: \.offset) { _, n in
                        HStack(alignment: .top, spacing: Metrics.u(8)) {
                            Circle().fill(NxColor.accent).frame(width: Metrics.u(5), height: Metrics.u(5)).padding(.top, Metrics.u(7))
                            Text(n).font(NxFont.body).foregroundStyle(NxColor.textMuted).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Metrics.u(14)).padding(.vertical, Metrics.u(12))
                .background(NxColor.ink3, in: RoundedRectangle(cornerRadius: Metrics.u(6), style: .continuous))
            }
            NxButton("OK", kind: .primary, wide: true) { app.dismissSheet() }
                #if os(tvOS)
                .focused($ok)
                #endif
                .accessibilityIdentifier("update.ok")
                .padding(.top, Metrics.u(4))
        }
        .accessibilityIdentifier("update.notice")
        #if os(tvOS)
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { ok = true } }
        #endif
    }
}
