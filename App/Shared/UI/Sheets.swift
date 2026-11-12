import SwiftUI

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
    var action: () -> Void
    init(_ title: String, sub: String? = nil, icon: String? = nil, selected: Bool = false, destructive: Bool = false, action: @escaping () -> Void) {
        self.title = title; self.sub = sub; self.icon = icon; self.selected = selected; self.destructive = destructive; self.action = action
    }
}

extension AppModel {
    /// Shows a panel with any content. `page`: a full-height one (editors).
    func present<C: View>(_ title: String? = nil, style: NxSheetItem.Style = .panel, @ViewBuilder _ content: () -> C) {
        let v = AnyView(content().environmentObject(self).environmentObject(store))
        withAnimation(.easeOut(duration: 0.22)) { sheets.append(NxSheetItem(style: style, title: title, content: v)) }
    }
    func dismissSheet() {
        if sheets.isEmpty { return }
        withAnimation(.easeOut(duration: 0.2)) { _ = sheets.removeLast() }
    }
    func dismissAllSheets() { withAnimation(.easeOut(duration: 0.2)) { sheets = [] } }

    /// A list of things to do with something (what a long press opens).
    func menu(_ title: String?, _ actions: [NxAction]) {
        present(title) {
            VStack(spacing: 0) {
                ForEach(actions) { a in
                    OptionRow(title: a.title, sub: a.sub, icon: a.icon, selected: a.selected, destructive: a.destructive) { self.dismissSheet(); a.action() }
                }
            }
        }
    }

    /// Pick one of a few values.
    func choose<T: Equatable>(_ title: String, _ options: [(T, String)], current: T, onPick: @escaping (T) -> Void) {
        menu(title, options.map { o in NxAction(o.1, selected: o.0 == current) { onPick(o.0) } })
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
