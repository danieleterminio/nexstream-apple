import Foundation

// Local check of the live proxy's pure logic (bash scripts/local_check.sh proxy):
// - TsSegmenter on a synthetic MPEG-TS (H.264, key frame every second, 25 fps) fed in odd-sized chunks, then a
//   reconnection (`restart`) where the time stamps start over: segments must start on key frames, last about the
//   minimum length, and the first one after the reconnection must be marked as a discontinuity;
// - HlsWindow: playlist window by duration, memory bound, media and discontinuity sequence numbers across reloads;
// - HlsWindow.reconnectDelay and StallPolicy (the forced-resume thresholds);
// - optionally a real capture: `proxytest.exe file.ts` runs it through the segmenter twice with a reconnection between.

var failures = 0
func check(_ ok: Bool, _ what: String) {
    print((ok ? "ok   " : "FAIL ") + what)
    if !ok { failures += 1 }
}

// MARK: synthetic transport stream

struct TsWriter {
    var cc = [Int: UInt8]()
    var out = [UInt8]()

    mutating func packet(pid: Int, pusi: Bool, payload: [UInt8], rai: Bool = false) {
        precondition(payload.count <= 184)
        var p = [UInt8]()
        p.append(0x47)
        p.append((pusi ? 0x40 : 0) | UInt8((pid >> 8) & 0x1F))
        p.append(UInt8(pid & 0xFF))
        let c = cc[pid, default: 0]
        cc[pid] = (c + 1) & 0x0F
        if payload.count == 184 && !rai {
            p.append(0x10 | c)
        } else {
            p.append(0x30 | c)
            let afl = 183 - payload.count
            p.append(UInt8(afl))
            if afl > 0 {
                p.append(rai ? 0x40 : 0x00)
                if afl > 1 { p.append(contentsOf: [UInt8](repeating: 0xFF, count: afl - 1)) }
            }
        }
        p.append(contentsOf: payload)
        precondition(p.count == 188, "packet \(p.count)")
        out.append(contentsOf: p)
    }

    mutating func tables() {
        // PAT: program 1 -> PMT on PID 0x100
        packet(pid: 0, pusi: true, payload: [0x00, 0x00, 0xB0, 0x0D, 0x00, 0x01, 0xC1, 0x00, 0x00, 0x00, 0x01, 0xE1, 0x00, 0, 0, 0, 0])
        // PMT: H.264 on 0x101, AAC on 0x102
        packet(pid: 0x100, pusi: true, payload: [0x00, 0x02, 0xB0, 0x17, 0x00, 0x01, 0xC1, 0x00, 0x00, 0xE1, 0x01, 0xF0, 0x00,
                                                 0x1B, 0xE1, 0x01, 0xF0, 0x00, 0x0F, 0xE1, 0x02, 0xF0, 0x00, 0, 0, 0, 0])
    }

    mutating func frame(pts: Int64, key: Bool) {
        var pes: [UInt8] = [0x00, 0x00, 0x01, 0xE0, 0x00, 0x00, 0x80, 0x80, 0x05]
        pes.append(UInt8(0x21 | ((pts >> 29) & 0x0E)))
        pes.append(UInt8((pts >> 22) & 0xFF))
        pes.append(UInt8(0x01 | ((pts >> 14) & 0xFE)))
        pes.append(UInt8((pts >> 7) & 0xFF))
        pes.append(UInt8(0x01 | ((pts << 1) & 0xFE)))
        pes.append(contentsOf: [0x00, 0x00, 0x00, 0x01, 0x09, 0xF0])            // access unit delimiter
        pes.append(contentsOf: [0x00, 0x00, 0x00, 0x01, key ? 0x65 : 0x41])    // IDR or ordinary slice
        pes.append(contentsOf: [UInt8](repeating: 0xAB, count: 40))
        packet(pid: 0x101, pusi: true, payload: pes, rai: key)
        // the rest of the picture
        for _ in 0..<3 { packet(pid: 0x101, pusi: false, payload: [UInt8](repeating: 0xCD, count: 184)) }
    }

    /// `seconds` of 25 fps video from `ptsStart`, a key frame every `gop` frames.
    mutating func video(seconds: Double, ptsStart: Int64, gop: Int = 25) {
        let frames = Int(seconds * 25)
        for f in 0..<frames {
            if f % gop == 0 { tables() }
            frame(pts: ptsStart + Int64(f) * 3600, key: f % gop == 0)
        }
    }
}

func feedOdd(_ seg: TsSegmenter, _ bytes: [UInt8]) {
    var o = 0
    var step = 1000
    while o < bytes.count {
        let n = min(step, bytes.count - o)
        seg.feed(Data(bytes[o..<(o + n)]))
        o += n
        step = step == 1000 ? 7777 : (step == 7777 ? 188 * 50 + 3 : 1000)
    }
}

/// True when the segment's first video PES (after the copied tables) is an IDR picture.
func startsOnKey(_ d: Data) -> Bool {
    let b = [UInt8](d)
    var o = 0
    while o + 188 <= b.count {
        let pid = (Int(b[o + 1] & 0x1F) << 8) | Int(b[o + 2])
        if pid == 0x101 && (b[o + 1] & 0x40) != 0 {
            let seg = b[o..<(o + 188)]
            if let i = seg.indices.first(where: { $0 + 4 < o + 188 && b[$0] == 0 && b[$0 + 1] == 0 && b[$0 + 2] == 1 && b[$0 + 3] == 0x65 }) { _ = i; return true }
            return false
        }
        o += 188
    }
    return false
}

// MARK: segmenter + reconnection

do {
    let seg = TsSegmenter()
    var segs = [TsSegmenter.Segment]()
    var info: TsSegmenter.StreamInfo? = nil
    seg.onInfo = { info = $0 }
    seg.onSegment = { segs.append($0) }
    seg.minDuration = 2
    seg.maxDuration = 3.8

    var w = TsWriter()
    w.video(seconds: 12, ptsStart: 900_000)
    feedOdd(seg, w.out)
    // the line drops; the new connection starts mid-way through a picture and with new time stamps. `restart` first
    // emits the tail of the old connection (a whole segment: it began on a key frame)
    seg.restart()
    let before = segs.count
    var w2 = TsWriter()
    w2.out.append(contentsOf: [UInt8](repeating: 0x00, count: 100))   // garbage before sync
    w2.video(seconds: 12, ptsStart: 12_345)
    feedOdd(seg, w2.out)
    seg.finish()

    check(info?.video == 0x1B && info?.audio == [0x0F], "PMT read: \(info?.summary ?? "none")")
    check(info?.systemPlayable == true, "H.264 + AAC is playable by the system player")
    check(before >= 4, "segments before the reconnection: \(before)")
    check(segs.count >= 9, "segments in all: \(segs.count)")
    check(segs.map { $0.seq } == Array(0..<segs.count), "sequence numbers continue across the reconnection")
    let disc = segs.filter { $0.discontinuity }.map { $0.seq }
    check(disc == [before], "only the first segment after the reconnection is a discontinuity: \(disc), expected [\(before)]")
    check(segs.allSatisfy { startsOnKey($0.data) }, "every segment starts on a key frame")
    let inner = segs.dropFirst(2).dropLast()
    check(inner.allSatisfy { abs($0.duration - 2.0) < 0.05 }, "segments last 2 s: \(segs.map { String(format: "%.2f", $0.duration) }.joined(separator: " "))")
    let total = segs.reduce(0) { $0 + $1.duration }
    check(abs(total - 24) < 0.3, "total length \(String(format: "%.2f", total)) s for 24 s of video")
    check(segs.allSatisfy { $0.data.count % 188 == 0 }, "segments are whole packets")
}

// MARK: playlist window

do {
    var h = HlsWindow()
    h.windowSeconds = 40; h.keptSeconds = 55; h.keptBytes = 1_000_000
    for i in 0..<30 { h.append(.init(seq: i, duration: 2, discontinuity: i == 10 || i == 20, data: Data(count: 1000))) }
    let w = h.window()
    check(w.first?.seq == 10 && w.last?.seq == 29, "window = newest 40 s (\(w.first?.seq ?? -1)…\(w.last?.seq ?? -1))")
    check(h.entries.reduce(0) { $0 + $1.duration } <= 56, "memory keeps about 55 s (\(h.count) segments)")
    var p = h.playlist(target: 4, ended: false)
    check(p.contains("#EXT-X-MEDIA-SEQUENCE:10\n"), "media sequence 10")
    check(!p.contains("DISCONTINUITY-SEQUENCE"), "no discontinuity left the playlist yet")
    check(p.components(separatedBy: "#EXT-X-DISCONTINUITY\n").count - 1 == 2, "two discontinuity tags listed")
    check(p.contains("#EXT-X-START:TIME-OFFSET=0\n"), "the player starts at the oldest segment")
    var short = HlsWindow()
    for i in 0..<3 { short.append(.init(seq: i, duration: 2, discontinuity: false, data: Data(count: 10))) }
    check(!short.playlist(target: 4, ended: false).contains("EXT-X-START"), "no start offset in a playlist shorter than 3 targets")
    check(p.contains("#EXT-X-TARGETDURATION:4\n") && !p.contains("ENDLIST"), "target and no end while live")
    for i in 30..<36 { h.append(.init(seq: i, duration: 2, discontinuity: false, data: Data(count: 1000))) }
    p = h.playlist(target: 4, ended: false)
    check(p.contains("#EXT-X-MEDIA-SEQUENCE:16\n") && p.contains("#EXT-X-DISCONTINUITY-SEQUENCE:1\n"), "after seg 10 left: sequence 16, discontinuity sequence 1")
    check(p.components(separatedBy: "#EXT-X-DISCONTINUITY\n").count - 1 == 1, "one discontinuity tag left")
    p = h.playlist(target: 4, ended: true)
    check(p.hasSuffix("#EXT-X-ENDLIST\n") && !p.contains("EXT-X-START"), "ended playlist closes")
    check(h.segment(35) != nil && h.segment(0) == nil, "old segments are gone, new ones served")

    var big = HlsWindow()
    big.keptBytes = 10_000
    for i in 0..<20 { big.append(.init(seq: i, duration: 2, discontinuity: false, data: Data(count: 2000))) }
    check(big.bytes <= 12_000 && big.count == 5, "memory bound by bytes (\(big.count) segments, \(big.bytes) B), never under the minimum + 1")
    var long = HlsWindow()
    for i in 0..<10 { long.append(.init(seq: i, duration: 20, discontinuity: false, data: Data(count: 10))) }
    check(long.window().count == 4, "long segments: at least 4 listed (\(long.window().count))")
}

// MARK: reconnect pause and stall thresholds

do {
    check(HlsWindow.reconnectDelay(attempt: 1, contentAhead: 3) == 0.25, "first reconnection after 0.25 s")
    check(HlsWindow.reconnectDelay(attempt: 9, contentAhead: 0) == 3.0, "repeated failures wait 3 s")
    check(abs(HlsWindow.reconnectDelay(attempt: 1, contentAhead: 25) - 10) < 0.01, "a source 25 s ahead of the clock waits 10 s")
    var live = StallPolicy(live: true)
    check(live.threshold(started: false, now: 0) == 1.0, "live starts with 1 s")
    check(live.threshold(started: true, now: 0) == 2.0, "live resumes with 2 s")
    live.stalled(at: 100); live.stalled(at: 110); live.stalled(at: 120)
    check(live.threshold(started: true, now: 121) == 6.0, "three stalls in a minute: 6 s")
    check(live.threshold(started: true, now: 300) == 2.0, "back to 2 s a few minutes later")
    var vod = StallPolicy(live: false)
    check(vod.threshold(started: false, now: 0) == 2.0 && vod.threshold(started: true, now: 0) == 4.0, "film: 2 s to start, 4 s to resume")
    for t in 0..<10 { vod.stalled(at: Double(t)) }
    check(vod.threshold(started: true, now: 10) == 16.0, "film threshold capped at 16 s")
}

// MARK: a real capture, if given

if CommandLine.arguments.count > 1 {
    let url = URL(fileURLWithPath: CommandLine.arguments[1])
    if let data = try? Data(contentsOf: url) {
        let seg = TsSegmenter()
        var segs = [TsSegmenter.Segment]()
        seg.onInfo = { print("     capture:", $0.summary, "playable:", $0.systemPlayable) }
        seg.onSegment = { segs.append($0) }
        feedOdd(seg, [UInt8](data))
        seg.restart()
        let first = segs.count
        feedOdd(seg, [UInt8](data))
        seg.finish()
        print("     capture segments: " + segs.map { String(format: "%.2f", $0.duration) + ($0.discontinuity ? "D" : "") }.joined(separator: " "))
        check(segs.filter { $0.discontinuity }.map { $0.seq } == [first], "capture: discontinuity on segment \(first) only")
    } else { print("cannot read \(url.path)") }
}

print(failures == 0 ? "all checks passed" : "\(failures) checks FAILED")
exit(failures == 0 ? 0 : 1)
