import SwiftUI

/// The app opening (variant A "Titoli di testa", same timing as Android's BrandIntro.kt):
///  - pure black; "If buying isn't owning, piracy isn't stealing." comes in word by word (blur → sharp, opacity 0 → 1,
///    0.6 s each, one every 0.28 s from 0.15 s) — Sora Bold, centred, balanced lines;
///  - 3.0 s: the quote fades out (0.5 s);
///  - 3.4 s: the symbol + "NexStream" fade in, the symbol breathes (0.86 → 1.06 → 1, 1.6 s) over a red glow (0 → 1 → 0.35);
///  - 4.75 s: the whole thing fades (0.4 s) into what the app has ready behind it (VPN gate, profiles, Home).
/// At every cold start, never skippable: RootView disables the pages under it, it swallows taps, and on the Apple TV it
/// holds the focus and eats BACK / play / moves. The app keeps starting underneath (AppModel is already working), so
/// nothing waits for the animation. Reduce Motion: plain fades, same duration. A stalled start pauses it (never skips).
enum NxIntro {
    static let quote = "If buying isn't owning, piracy isn't stealing."
    static let end: Double = 5.15
    /// True while the opening is on screen (BackGuard ignores BACK meanwhile).
    nonisolated(unsafe) static var running = false
    /// True once the opening has ended (the update notice waits for it).
    nonisolated(unsafe) static var done = false
}

private let introInk = Color(hex: 0xF4F4F6)

/// CSS-like timing: 0...1 progress of a step that starts at `start` and lasts `dur`, through `ease`.
private func seg(_ t: Double, _ start: Double, _ dur: Double, _ ease: (Double) -> Double) -> Double {
    ease(min(1, max(0, (t - start) / dur)))
}
/// cubic-bezier(x1, 0, x2, 1) like CSS ease-in / ease-out / ease-in-out, solved for x.
private func bezier(_ x1: Double, _ x2: Double) -> (Double) -> Double {
    { x in
        if x <= 0 { return 0 }; if x >= 1 { return 1 }
        var lo = 0.0, hi = 1.0, s = x
        for _ in 0..<24 {
            s = (lo + hi) / 2
            let bx = 3 * (1 - s) * (1 - s) * s * x1 + 3 * (1 - s) * s * s * x2 + s * s * s
            if bx < x { lo = s } else { hi = s }
        }
        return 3 * (1 - s) * s * s + s * s * s   // y1 = 0, y2 = 1
    }
}
private let easeOut = bezier(0, 0.58)
private let easeIn = bezier(0.42, 1)
private let easeInOut = bezier(0.42, 0.58)
private func mix(_ a: Double, _ b: Double, _ p: Double) -> Double { a + (b - a) * p }

struct BrandIntro: View {
    let onDone: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduce
    /// Seconds of the opening shown so far: frame-paced, a tick moves it by at most 50 ms, so a stall of the main
    /// thread while the app starts underneath pauses the opening instead of skipping the quote.
    @State private var t: Double = 0
    #if os(tvOS)
    @FocusState private var focused: Bool
    #endif

    var body: some View {
        frame(t)
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture {}
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(NxIntro.quote)
        .accessibilityIdentifier("brand.intro")
        #if os(tvOS)
        .focusable(true)
        .focusEffectDisabled()
        .focused($focused)
        .onExitCommand {}
        .onPlayPauseCommand {}
        .onMoveCommand { _ in }
        #endif
        .onAppear {
            NxIntro.running = true
            NxLog.i("NxIntro", "opening starts (reduce motion: \(reduce))")
            #if os(tvOS)
            focused = true
            #endif
        }
        .task {
            let start = Date()
            var last = start
            while t < NxIntro.end {
                try? await Task.sleep(nanoseconds: 16_000_000)
                if Task.isCancelled { NxIntro.running = false; return }
                let now = Date()
                t += min(max(0, now.timeIntervalSince(last)), 0.05)
                last = now
            }
            NxIntro.running = false
            NxIntro.done = true
            NxLog.i("NxIntro", String(format: "opening done after %.2f s", Date().timeIntervalSince(start)))
            onDone()
        }
        .onDisappear { NxIntro.running = false; NxIntro.done = true }
    }

    private func frame(_ t: Double) -> some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            // the quote's size is the unit of everything (reference: TV 4.6 % of the width, phone 8.6 %)
            let u: CGFloat = w > h ? min(w * 0.046, h * 0.082) : min(w * 0.086, h * 0.045)
            let sym = u * 3.48
            let glow = min(sym * 2.5, w * 0.4)
            let quoteAlpha = 1 - seg(t, 3.0, 0.5, easeIn)
            let logoAlpha = seg(t, 3.4, 0.5, easeOut)
            let b = min(1, max(0, (t - 3.4) / 1.6))
            let breathe = reduce ? 1 : (b <= 0.55 ? mix(0.86, 1.06, easeInOut(b / 0.55)) : mix(1.06, 1, easeInOut((b - 0.55) / 0.45)))
            let glowA = b <= 0.5 ? easeInOut(b / 0.5) : mix(1, 0.35, easeInOut((b - 0.5) / 0.5))
            let glowS = reduce ? 1 : mix(0.6, 1.1, easeInOut(b))
            ZStack {
                Color.black
                if quoteAlpha > 0 {
                    BalancedLines(space: u * 0.26, lineHeight: u * 1.15) {
                        ForEach(Array(NxIntro.quote.split(separator: " ").enumerated()), id: \.offset) { i, word in
                            let p = reduce ? seg(t, 0.15, 0.6, easeOut) : seg(t, 0.15 + Double(i) * 0.28, 0.6, easeOut)
                            Text(String(word))
                                .font(.custom("Sora-Regular_Bold", fixedSize: u))
                                .kerning(-0.01 * u)
                                .foregroundStyle(introInk)
                                .fixedSize()
                                .blur(radius: reduce ? 0 : u * 0.33 * (1 - p))
                                .opacity(p)
                        }
                    }
                    .padding(.horizontal, w * 0.08)
                    // Apple TV: inside the title-safe area
                    .padding(.vertical, Metrics.tv ? h * 0.05 : 0)
                    .opacity(quoteAlpha)
                }
                if t >= 3.4 {
                    Circle()
                        .fill(RadialGradient(stops: [.init(color: NxColor.accent.opacity(0.45), location: 0), .init(color: .clear, location: 0.65)],
                                             center: .center, startRadius: 0, endRadius: glow * 0.7071))
                        .frame(width: glow, height: glow)
                        .scaleEffect(glowS)
                        .opacity(glowA * logoAlpha)
                    VStack(spacing: u * 0.32) {
                        NxSymbolMark().frame(width: sym, height: sym).scaleEffect(breathe)
                        HStack(spacing: 0) {
                            Text("Nex").foregroundStyle(Color.white)
                            Text("Stream").foregroundStyle(NxColor.accentBright)
                        }
                        .font(.custom("Sora-Regular_ExtraBold", fixedSize: u * 1.17))
                        .kerning(-0.02 * u * 1.17)
                        .fixedSize()
                    }
                    .opacity(logoAlpha)
                }
            }
            .frame(width: w, height: h)
            .opacity(1 - seg(t, 4.75, 0.4, easeIn))
        }
    }
}

/// The brand symbol drawn as vectors (same geometry as Android's BrandMark.kt, 100×100 box): two white broadcast waves
/// and the rounded play in the crimson → coral → amber gradient — sharp at any size, unlike the PNG.
struct NxSymbolMark: View {
    var body: some View {
        Canvas { ctx, size in
            let k = min(size.width, size.height) / 100
            ctx.scaleBy(x: k, y: k)
            var w1 = Path(); w1.addRelativeArc(center: CGPoint(x: 39.23, y: 50), radius: 20, startAngle: .degrees(228.6), delta: .degrees(-97.2))
            var w2 = Path(); w2.addRelativeArc(center: CGPoint(x: 37.84, y: 50), radius: 31, startAngle: .degrees(225.2), delta: .degrees(-90.4))
            var play = Path(); play.move(to: CGPoint(x: 40, y: 24)); play.addLine(to: CGPoint(x: 79, y: 50)); play.addLine(to: CGPoint(x: 40, y: 76)); play.closeSubpath()
            let wave = StrokeStyle(lineWidth: 7, lineCap: .round)
            ctx.stroke(w2, with: .color(.white), style: wave)
            ctx.stroke(w1, with: .color(.white), style: wave)
            let grad = GraphicsContext.Shading.linearGradient(
                Gradient(stops: [.init(color: NxColor.accent, location: 0), .init(color: NxColor.accentBright, location: 0.55), .init(color: NxColor.ember, location: 1)]),
                startPoint: CGPoint(x: 35, y: 19), endPoint: CGPoint(x: 84, y: 81))
            ctx.fill(play, with: grad)
            ctx.stroke(play, with: grad, style: StrokeStyle(lineWidth: 10, lineCap: .round, lineJoin: .round))
        }
    }
}

/// Words on centred lines, balanced like CSS `text-wrap: balance`: the narrowest width that keeps the line count a
/// plain wrap would give, so the two halves of the quote come out even.
private struct BalancedLines: Layout {
    var space: CGFloat
    var lineHeight: CGFloat

    private func rows(_ widths: [CGFloat], _ maxW: CGFloat) -> [[Int]] {
        var out: [[Int]] = []; var cur: CGFloat = 0
        for (i, w) in widths.enumerated() {
            if out.isEmpty || (cur + space + w > maxW && !(out.last ?? []).isEmpty) { out.append([i]); cur = w }
            else { out[out.count - 1].append(i); cur += space + w }
        }
        return out
    }
    private func balanced(_ widths: [CGFloat], _ avail: CGFloat) -> [[Int]] {
        let n = rows(widths, avail).count
        var lo = widths.max() ?? 0, hi = max(avail, lo)
        for _ in 0..<30 { let mid = (lo + hi) / 2; if rows(widths, mid).count <= n { hi = mid } else { lo = mid } }
        return rows(widths, hi)
    }
    private func widthOf(_ row: [Int], _ widths: [CGFloat]) -> CGFloat {
        row.reduce(0) { $0 + widths[$1] } + space * CGFloat(max(0, row.count - 1))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let widths: [CGFloat] = subviews.map { $0.sizeThatFits(.unspecified).width }
        let avail = proposal.width ?? .infinity
        let r = balanced(widths, avail)
        let maxRow: CGFloat = r.map { widthOf($0, widths) }.max() ?? 0
        return CGSize(width: proposal.width ?? maxRow, height: CGFloat(r.count) * lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let widths: [CGFloat] = subviews.map { $0.sizeThatFits(.unspecified).width }
        let r = balanced(widths, bounds.width)
        for (ri, row) in r.enumerated() {
            var x = bounds.minX + (bounds.width - widthOf(row, widths)) / 2
            let y = bounds.minY + CGFloat(ri) * lineHeight + lineHeight / 2
            for i in row {
                subviews[i].place(at: CGPoint(x: x, y: y), anchor: .leading, proposal: .unspecified)
                x += widths[i] + space
            }
        }
    }
}
