import Foundation
#if canImport(CFNetwork)
import CFNetwork
#endif

/// Watches the system VPN. `active` drives the gate screen, the HTTP filter and the players, as on Android.
///
/// iOS / tvOS do not tell an app "a VPN is on"; what they do expose is the list of network interfaces the proxy settings
/// are scoped to, and a tunnel shows up there as `utun*` / `ipsec*` / `ppp*` / `tap*` / `tun*`. That list is polled.
/// In the simulator there is no VPN (the Mac's covers it): it counts as protected, and the launch argument
/// `-nxVpnOff` simulates the VPN being off so both paths can be seen.
final class Vpn {
    static let shared = Vpn()
    let active = Observable<Bool>(false)
    private var timer: DispatchSourceTimer?
    private var simulated: Bool?

    func start() {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-nxVpnOff") { simulated = false }
        else if args.contains("-nxVpnOn") { simulated = true }
        else {
            #if targetEnvironment(simulator)
            simulated = true
            #endif
        }
        publish()
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        t.schedule(deadline: .now() + 2, repeating: 2)
        t.setEventHandler { [weak self] in self?.publish() }
        t.resume()
        timer = t
    }

    /// Re-read now (the app came back to the foreground).
    func refresh() { publish() }

    private func publish() {
        let now = simulated ?? Vpn.systemVpnActive()
        if active.value != now {
            NxLog.i("NxVpn", "vpn \(now ? "on" : "off")")
            active.value = now
        }
    }

    static func systemVpnActive() -> Bool {
        #if os(iOS) || os(tvOS)
        guard let cf = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any],
              let scoped = cf["__SCOPED__"] as? [String: Any] else { return false }
        for name in scoped.keys {
            let n = name.lowercased()
            if n.hasPrefix("utun") || n.hasPrefix("ipsec") || n.hasPrefix("ppp") || n.hasPrefix("tap") || n.hasPrefix("tun") { return true }
        }
        return false
        #else
        return true
        #endif
    }
}
