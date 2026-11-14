import UIKit

/// BACK when nothing on screen has the focus (a page that filled in after the focus engine looked for something to
/// focus, a view that went away under the focus). SwiftUI's `onExitCommand` handlers only see BACK through the focused
/// view, so with no focus the press reaches the system, which leaves the app — docs/tv-experience.md: BACK must never
/// drop the user out of the app by surprise. This recognizer on the window takes BACK only in that state and lets the
/// app answer it (the side menu on the section in view, or the "Vuoi uscire?" question on a gate).
final class BackGuard: NSObject, UIGestureRecognizerDelegate {
    static let shared = BackGuard()
    private weak var window: UIWindow? = nil

    /// Puts the recognizer on the app's window (again when the window changed); called when the app shows.
    static func install() {
        let windows: [UIWindow] = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap { $0.windows }
        guard let w = windows.first(where: { $0.isKeyWindow }) ?? windows.first else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { install() }
            return
        }
        if shared.window === w { return }
        let g = UITapGestureRecognizer(target: shared, action: #selector(BackGuard.fire))
        g.allowedPressTypes = [NSNumber(value: UIPress.PressType.menu.rawValue)]
        g.delegate = shared
        w.addGestureRecognizer(g)
        shared.window = w
    }

    /// Only when no view has the focus: every other BACK goes through the app's own handlers as before.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive press: UIPress) -> Bool {
        guard let w = gestureRecognizer.view as? UIWindow else { return false }
        let focused: UIFocusItem? = w.windowScene?.focusSystem?.focusedItem
        return focused == nil
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { false }

    @objc private func fire() {
        MainActor.assumeIsolated { AppModel.shared.backWithoutFocus() }
    }
}
