import SwiftUI
import UIKit
#if os(tvOS)
import TVVLCKit
#else
import MobileVLCKit
#endif

@main
struct NexStreamApp: App {
    var body: some Scene {
        WindowGroup { SpikeView().preferredColorScheme(.dark) }
    }
}

/// Build spike: proves the three risky pieces work on this platform — embedded Python running Stream4Me, VLCKit, Liquid Glass.
struct SpikeView: View {
    @State private var lines: [String] = ["Avvio…"]

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.90, green: 0.09, blue: 0.25), Color(red: 0.05, green: 0.05, blue: 0.07)], startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
            VStack(spacing: 14) {
                Image("BrandLockup")
                ForEach(lines, id: \.self) { l in
                    Text(l).font(.custom("Manrope", size: 15)).multilineTextAlignment(.center)
                }
                Button("Liquid Glass") {}.buttonStyle(.glass)
                Text("Vetro").padding(.horizontal, 24).padding(.vertical, 12).glassEffect()
            }
            .padding(24)
        }
        .task { await run() }
    }

    private func run() async {
        var out = [String]()
        out.append("VLCKit \(VLCLibrary.shared().version)")
        let families = UIFont.familyNames.filter { $0.hasPrefix("Manrope") || $0.hasPrefix("Sora") }
        out.append("font: " + families.flatMap { UIFont.fontNames(forFamilyName: $0) }.joined(separator: ", "))
        do {
            try await Engine.shared.ensureReady()
            out.append("init: \(Engine.shared.initInfo)")
            out.append("Stream4Me \(await Engine.shared.version())")
            let ch = try await Engine.shared.channels()
            out.append("canali: \(ch.count)")
            let r = try await Engine.shared.search("Breaking Bad", type: "tvshow", year: 2008)
            out.append("ricerca: \(r.hits.count) risultati in \(r.elapsed ?? 0) s; primo: \(r.hits.first.map { "\($0.channel) · \($0.title)" } ?? "-")")
            if let first = r.hits.first {
                let eps = try await Engine.shared.episodes(first.item)
                out.append("episodi: \(eps.count)")
                if let e = eps.first {
                    let p = try await Engine.shared.play(e.item)
                    out.append("play: \(p.kind ?? "?") \(p.server ?? "?") \(p.url ?? "nessun url")")
                }
            }
        } catch {
            out.append("ERRORE: \(error)")
        }
        lines = out
        out.forEach { NxLog.i("Spike", $0) }
    }
}
