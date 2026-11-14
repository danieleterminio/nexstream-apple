import SwiftUI
import UIKit

/// Our own panels instead of the system's sheets, menus and alerts: a panel that rises from the bottom on the phone,
/// one that slides in from the right on the TV, and a dialog in the middle for questions.
struct NxSheetItem: Identifiable {
    enum Style { case panel, dialog, page }
    let id = UUID()
    var style: Style
    var title: String?
    var content: AnyView
}

/// One line of a menu.
struct NxAction: Identifiable {
    let id = UUID()
    var title: String
    var sub: String? = nil
    var icon: String? = nil
    var selected: Bool = false
    var destructive: Bool = false
    /// A small outlined label at the end of the line ("FHD", "4K").
    var badge: String? = nil
    var action: () -> Void
    init(_ title: String, sub: String? = nil, icon: String? = nil, selected: Bool = false, destructive: Bool = false, badge: String? = nil, action: @escaping () -> Void) {
        self.title = title; self.sub = sub; self.icon = icon; self.selected = selected; self.destructive = destructive; self.badge = badge; self.action = action
    }
}

/// Where the focus was when a panel opened (Apple TV): it goes back there when the panel closes, as long as the viewer is
/// still on the same page (a menu line may have opened another page or the player).
struct FocusOrigin {
    var key: String?
    var rail: Bool
    var section: AppSection
    var depth: Int
}

extension AppModel {
    /// Shows a panel with any content. `page`: a full-height one (editors).
    func present<C: View>(_ title: String? = nil, style: NxSheetItem.Style = .panel, @ViewBuilder _ content: () -> C) {
        let v = AnyView(content().environmentObject(self).environmentObject(store))
        noteOrigin()
        withAnimation(.easeOut(duration: 0.22)) { sheets.append(NxSheetItem(style: style, title: title, content: v)) }
    }
    func dismissSheet() {
        if sheets.isEmpty { return }
        let o = sheetOrigins.popLast()
        withAnimation(.easeOut(duration: 0.2)) { _ = sheets.removeLast() }
        restoreFocus(o)
    }
    func dismissAllSheets() {
        if sheets.isEmpty { return }
        let o = sheetOrigins.first
        sheetOrigins = []
        withAnimation(.easeOut(duration: 0.2)) { sheets = [] }
        restoreFocus(o)
    }

    private func noteOrigin() {
        // one origin per panel, also when the list got out of step
        if sheetOrigins.count > sheets.count { sheetOrigins.removeLast(sheetOrigins.count - sheets.count) }
        while sheetOrigins.count < sheets.count { sheetOrigins.append(FocusOrigin(key: nil, rail: false, section: section, depth: -1)) }
        sheetOrigins.append(FocusOrigin(key: FocusMemory.last, rail: FocusMemory.inRail, section: section, depth: (paths[section] ?? []).count))
    }

    /// Back to where the focus was before the panel (docs/tv-experience.md §2: "closes it, focus back where it was").
    private func restoreFocus(_ origin: FocusOrigin?) {
        #if os(tvOS)
        guard let o = origin, o.depth >= 0 else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard self.playing == nil, self.section == o.section, (self.paths[o.section] ?? []).count == o.depth else { return }
            if o.rail { self.railRestore.send(()) } else if let k = o.key { FocusMemory.restore.send(k) }
        }
        #endif
    }

    /// A list of things to do with something (what a long press opens).
    func menu(_ title: String?, _ actions: [NxAction]) {
        if let cap = menuCapture { cap(title, actions); return }
        present(title) {
            VStack(spacing: 0) {
                ForEach(actions) { a in
                    OptionRow(title: a.title, sub: a.sub, icon: a.icon, selected: a.selected, destructive: a.destructive, badge: a.badge) { self.dismissSheet(); a.action() }
                }
            }
        }
    }

    /// Runs a menu builder (a card's long press) and returns what it would show instead of showing it: the Apple TV
    /// turns it into the system's long-press menu, which is what the focus engine offers on a held select.
    func captureMenu(_ build: () -> Void) -> (title: String?, actions: [NxAction]) {
        var out: (title: String?, actions: [NxAction]) = (nil, [])
        menuCapture = { t, a in out = (t, a) }
        build()
        menuCapture = nil
        return out
    }

    /// Pick one of a few values.
    func choose<T: Equatable>(_ title: String, _ options: [(T, String)], current: T, onPick: @escaping (T) -> Void) {
        menu(title, options.map { o in NxAction(o.1, selected: o.0 == current) { onPick(o.0) } })
    }

    /// "Vuoi uscire da NexStream?" — BACK on the TV's side menu or on a gate (Android: askExit in MainActivity).
    /// "Resta" is the first choice, so a second BACK or a quick select never leaves by mistake.
    func askExit() {
        if sheets.contains(where: { $0.title == "nx.exit" }) { return }
        noteOrigin()
        withAnimation(.easeOut(duration: 0.22)) {
            sheets.append(NxSheetItem(style: .dialog, title: "nx.exit", content: AnyView(ExitQuestion().environmentObject(self))))
        }
    }

    /// A question with one thing to confirm.
    func confirm(_ title: String, message: String? = nil, confirm: String, destructive: Bool = false, action: @escaping () -> Void) {
        present(nil, style: .dialog) {
            VStack(spacing: Metrics.u(12)) {
                Text(title).font(NxFont.titleM).foregroundStyle(NxColor.text).multilineTextAlignment(.center)
                if let m = message { Text(m).font(NxFont.meta).foregroundStyle(NxColor.textMuted).multilineTextAlignment(.center) }
                VStack(spacing: Metrics.u(8)) {
                    NxButton(confirm, kind: destructive ? .danger : .primary, wide: true) { self.dismissSheet(); action() }
                    NxButton("Annulla", kind: .quiet, wide: true) { self.dismissSheet() }
                }
                .padding(.top, Metrics.u(6))
            }
        }
    }
}

/// The question before leaving the app.
private struct ExitQuestion: View {
    @EnvironmentObject var app: AppModel
    #if os(tvOS)
    @FocusState private var stay: Bool
    #endif
    var body: some View {
        VStack(spacing: Metrics.u(12)) {
            Text("Vuoi uscire da NexStream?").font(NxFont.titleM).foregroundStyle(NxColor.text).multilineTextAlignment(.center)
            VStack(spacing: Metrics.u(8)) {
                NxButton("Resta", kind: .primary, wide: true) { app.dismissSheet() }
                    #if os(tvOS)
                    .focused($stay)
                    #endif
                NxButton("Esci", kind: .quiet, wide: true) { app.dismissSheet(); AppExit.leave() }
            }
            .padding(.top, Metrics.u(6))
        }
        #if os(tvOS)
        .onAppear { stay = true }
        #endif
    }
}

/// Back to the system's home screen, the way the system's own BACK on a root screen does it.
enum AppExit {
    static func leave() {
        #if os(tvOS)
        UIControl().sendAction(#selector(URLSessionTask.suspend), to: UIApplication.shared, for: nil)
        #endif
    }
}

/// Draws the panels on top of everything.
struct SheetHost: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        ZStack {
            if !app.sheets.isEmpty {
                Color.black.opacity(0.62).ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { app.dismissSheet() }
                    .transition(.opacity)
            }
            ForEach(app.sheets) { s in
                let top = s.id == app.sheets.last?.id
                SheetPanel(item: s)
                    .opacity(top ? 1 : 0)
                    .allowsHitTesting(top)
                    .disabled(!top)
                    .zIndex(top ? 2 : 1)
                    #if os(tvOS)
                    .transition(s.style == .dialog ? .opacity : .move(edge: .trailing))
                    #else
                    .transition(s.style == .dialog ? .opacity.combined(with: .scale(scale: 0.94)) : .move(edge: .bottom))
                    #endif
            }
        }
    }
}

private struct SheetPanel: View {
    let item: NxSheetItem
    @EnvironmentObject var app: AppModel
    @State private var drag: CGFloat = 0

    var body: some View {
        switch item.style {
        case .dialog:
            item.content
                .padding(Metrics.u(22))
                .frame(maxWidth: Metrics.u(340))
                .background(NxColor.ink3, in: RoundedRectangle(cornerRadius: Metrics.u(10), style: .continuous))
                .padding(Metrics.u(24))
                #if os(tvOS)
                .focusSection()
                .onExitCommand { app.dismissSheet() }
                #endif
        case .panel, .page:
            #if os(tvOS)
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 0) {
                    if let t = item.title { Text(t).font(NxFont.titleL).foregroundStyle(NxColor.text).lineLimit(2).padding(.horizontal, 40).padding(.top, 70).padding(.bottom, 20) }
                    else { Color.clear.frame(height: 60) }
                    ScrollView(.vertical, showsIndicators: false) { item.content.padding(.horizontal, 24).padding(.bottom, 60) }
                }
                .frame(width: item.style == .page ? 1000 : 720)
                .frame(maxHeight: .infinity)
                .background(NxColor.ink2.ignoresSafeArea())
                .focusSection()
            }
            .ignoresSafeArea()
            .onExitCommand { app.dismissSheet() }
            #else
            GeometryReader { g in
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    VStack(spacing: 0) {
                        VStack(spacing: 0) {
                            Capsule().fill(Color.white.opacity(0.28)).frame(width: 38, height: 4).padding(.top, 8).padding(.bottom, 6)
                            HStack(alignment: .center) {
                                Text(item.title ?? "").font(NxFont.titleM).foregroundStyle(NxColor.text).lineLimit(2)
                                Spacer(minLength: 8)
                                Button { app.dismissSheet() } label: {
                                    Image(systemName: "xmark").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                                        .frame(width: 30, height: 30).background(NxColor.ink5, in: Circle())
                                }
                                .buttonStyle(NxPlainStyle(scale: 0.9))
                                .accessibilityLabel("Chiudi")
                            }
                            .padding(.horizontal, 16).padding(.bottom, 8)
                        }
                        .contentShape(Rectangle())
                        .gesture(DragGesture().onChanged { v in drag = max(0, v.translation.height) }.onEnded { v in
                            if v.translation.height > 90 { app.dismissSheet() }
                            withAnimation(.easeOut(duration: 0.2)) { drag = 0 }
                        })
                        ScrollView(.vertical, showsIndicators: false) { item.content.padding(.bottom, 14) }
                            .frame(maxHeight: item.style == .page ? .infinity : nil)
                            .scrollBounceBehavior(.basedOnSize)
                    }
                    .frame(maxWidth: 560)
                    .frame(maxHeight: item.style == .page ? .infinity : g.size.height * 0.78, alignment: .top)
                    .fixedSize(horizontal: false, vertical: item.style != .page)
                    .background { UnevenRoundedRectangle(topLeadingRadius: 14, topTrailingRadius: 14, style: .continuous).fill(NxColor.ink2).ignoresSafeArea(edges: .bottom) }
                    .offset(y: drag)
                    .padding(.top, item.style == .page ? 50 : 0)
                }
                .frame(maxWidth: .infinity)
            }
            #endif
        }
    }
}

/// One line of a panel, with a tick on the current choice.
struct OptionRow: View {
    let title: String
    var sub: String? = nil
    var icon: String? = nil
    var selected: Bool = false
    var destructive: Bool = false
    var badge: String? = nil
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Focusable { focused in
                HStack(spacing: Metrics.u(12)) {
                    if let i = icon { Image(systemName: i).font(.system(size: 17 * Metrics.unit, weight: .medium)).frame(width: Metrics.u(26)) }
                    VStack(alignment: .leading, spacing: Metrics.u(2)) {
                        Text(title).font(NxFont.ui(15, selected ? .bold : .semibold)).multilineTextAlignment(.leading)
                        if let s = sub { Text(s).font(NxFont.caption).foregroundStyle(focused ? Color.black.opacity(0.6) : NxColor.textDim).multilineTextAlignment(.leading).lineLimit(2) }
                    }
                    Spacer(minLength: 8)
                    if let b = badge {
                        Text(b).font(NxFont.label).lineLimit(1)
                            .padding(.horizontal, Metrics.u(5)).padding(.vertical, Metrics.u(1.5))
                            .overlay(RoundedRectangle(cornerRadius: Metrics.u(3)).stroke(focused ? Color.black.opacity(0.5) : NxColor.textDim, lineWidth: 1))
                    }
                    if selected { Image(systemName: "checkmark").font(.system(size: 14 * Metrics.unit, weight: .bold)) }
                }
                .foregroundStyle(focused ? Color.black : (destructive ? NxColor.accentBright : Color.white))
                .padding(.horizontal, Metrics.u(16)).padding(.vertical, Metrics.u(13))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(focused ? Color.white : Color.clear, in: RoundedRectangle(cornerRadius: Metrics.u(5), style: .continuous))
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(NxPlainStyle(scale: 0.99))
    }
}

/// A small heading between groups of lines in a panel or in a settings page.
struct OptionHeader: View {
    let title: String
    var body: some View {
        Text(title.uppercased()).font(NxFont.label).tracking(1).foregroundStyle(NxColor.textDim)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Metrics.u(16)).padding(.top, Metrics.u(16)).padding(.bottom, Metrics.u(4))
    }
}
