import Foundation
#if canImport(Network)
import Network
#endif

/// What the device is connected through, under the VPN tunnel: Wi-Fi / cable, mobile data, or nothing. Downloads wait for
/// the Wi-Fi when asked to, and the players warn once before streaming on mobile data.
/// Launch arguments of the build pipeline: `-nxCellular` pretends to be on mobile data, `-nxOffline` on no network.
final class NetMonitor {
    static let shared = NetMonitor()
    /// Mobile data (or a hotspot the system marks as expensive).
    let expensive = Observable<Bool>(false)
    /// Some network is there at all.
    let online = Observable<Bool>(true)
    private let lock = NSLock()
    private var started = false
    #if canImport(Network)
    private var monitor: NWPathMonitor? = nil
    #endif

    func start() {
        lock.lock()
        if started { lock.unlock(); return }
        started = true
        lock.unlock()
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-nxCellular") { expensive.value = true; return }
        if args.contains("-nxOffline") { online.value = false; return }
        #if canImport(Network)
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] p in
            guard let self = self else { return }
            let exp = p.isExpensive || (p.usesInterfaceType(.cellular) && !p.usesInterfaceType(.wifi) && !p.usesInterfaceType(.wiredEthernet))
            let on = p.status == .satisfied
            if self.expensive.value != exp { NxLog.i("NxNet", exp ? "mobile data" : "not on mobile data"); self.expensive.value = exp }
            if self.online.value != on { NxLog.i("NxNet", on ? "online" : "offline"); self.online.value = on }
        }
        m.start(queue: DispatchQueue(label: "nx.netmonitor", qos: .utility))
        monitor = m
        #endif
    }
}
