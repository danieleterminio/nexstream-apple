import Foundation

/// The rolling live playlist the live proxy serves: the segments kept in memory, the part of them the playlist shows,
/// discontinuities after a reconnection. Pure bookkeeping (no network), so it can be checked on any machine.
///
/// Why the window is long (tens of seconds, not a handful of segments): every stall puts the system player a little
/// further behind the newest segment, and a player whose next segment has left the playlist has to jump or fail. A
/// long window keeps that from happening; memory is bounded by `keptBytes`.
struct HlsWindow {
    struct Entry {
        let seq: Int
        let duration: Double
        let discontinuity: Bool
        let data: Data
    }

    /// Seconds of video the playlist lists.
    var windowSeconds: Double = 40
    /// Seconds kept in memory (a little more than the window: a player that just read the playlist may still ask for
    /// the oldest segment).
    var keptSeconds: Double = 55
    /// Upper bound of memory, whatever the bit rate.
    var keptBytes: Int = 80_000_000
    /// At least this many segments stay listed even if they are longer than the window.
    var minSegments: Int = 4

    private(set) var entries = [Entry]()
    private var droppedDiscontinuities = 0
    private(set) var bytes = 0

    var isEmpty: Bool { entries.isEmpty }
    var count: Int { entries.count }
    var longest: Double { entries.map { $0.duration }.max() ?? 0 }

    mutating func append(_ e: Entry) {
        entries.append(e)
        bytes += e.data.count
        trim()
    }

    private mutating func trim() {
        while entries.count > minSegments + 1 {
            let total = entries.reduce(0.0) { $0 + $1.duration }
            if total - entries[0].duration < keptSeconds && bytes <= keptBytes { break }
            let first = entries.removeFirst()
            bytes -= first.data.count
            if first.discontinuity { droppedDiscontinuities += 1 }
        }
    }

    func segment(_ seq: Int) -> Entry? {
        // segments are in order: look from the end, where the player asks most of the time
        for e in entries.reversed() where e.seq == seq { return e }
        return nil
    }

    /// The listed segments: the newest ones up to `windowSeconds` (never fewer than `minSegments`).
    func window() -> ArraySlice<Entry> {
        var total = 0.0
        var from = entries.count
        while from > 0 {
            let d = entries[from - 1].duration
            if entries.count - from >= minSegments && total + d > windowSeconds { break }
            total += d
            from -= 1
        }
        return entries[from...]
    }

    /// The playlist text. `startAtBeginning` asks the player to start from the oldest listed segment (as much cushion as
    /// there is) instead of three target durations from the end.
    func playlist(target: Int, ended: Bool, startAtBeginning: Bool = true) -> String {
        let w = window()
        let firstSeq = w.first?.seq ?? 0
        var disc = droppedDiscontinuities
        for e in entries where e.seq < firstSeq && e.discontinuity { disc += 1 }
        var s = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:\(target)\n#EXT-X-MEDIA-SEQUENCE:\(firstSeq)\n"
        if disc > 0 { s += "#EXT-X-DISCONTINUITY-SEQUENCE:\(disc)\n" }
        // only when it can apply: AVPlayer refuses a start within three target durations of the end (CoreMedia -16831,
        // seen in the CI logs) and reads the tag only at the first load, i.e. it helps when the line sent a burst
        let listed = w.reduce(0.0) { $0 + $1.duration }
        if startAtBeginning && !ended && listed >= Double(3 * target) + 1 { s += "#EXT-X-START:TIME-OFFSET=0\n" }
        // every listed segment keeps its own tag; the sequence above counts only the tags that left the playlist, so
        // each segment's discontinuity number stays the same from one reload to the next
        for e in w {
            if e.discontinuity { s += "#EXT-X-DISCONTINUITY\n" }
            s += "#EXTINF:" + String(format: "%.3f", e.duration) + ",\nseg\(e.seq).ts\n"
        }
        if ended { s += "#EXT-X-ENDLIST\n" }
        return s
    }

    /// The pause before the line is read again after its download stopped. Short at first (a dropped connection on a
    /// live channel should be invisible), longer after repeated failures (the line allows one connection and answers
    /// 403 while it still counts the old one). `contentAhead` = seconds of video received beyond the wall clock since
    /// the first byte: a source that sends faster than real time (a file, a server burst) is not read again before the
    /// player has used most of it, so a short file cannot be re-read in a tight loop.
    static func reconnectDelay(attempt: Int, contentAhead: Double) -> Double {
        let steps: [Double] = [0.25, 0.5, 1.0, 1.5, 2.0, 3.0]
        let base = steps[max(0, min(attempt - 1, steps.count - 1))]
        return max(base, contentAhead - 15)
    }
}

/// When the system player, stalled, is told to play again with what it has (ExoPlayer's "buffer for playback after
/// rebuffer"). Left to itself AVPlayer waits until it predicts that it will never stall again, which on a live channel
/// or a slow file host can take 10-15 s; Android resumes after 2-3 s of buffer. The threshold grows when stalls come
/// close together, so a source that is really too slow does not play in one-second bursts.
struct StallPolicy {
    let live: Bool
    private(set) var stallTimes = [Double]()

    init(live: Bool) { self.live = live }

    /// Seconds of buffer needed to resume. `started` = it played before (a rebuffer, not the first start).
    func threshold(started: Bool, now: Double) -> Double {
        if !started { return live ? 1.0 : 2.0 }
        let recent = stallTimes.filter { now - $0 < 60 }.count
        let base = live ? 2.0 : 4.0
        let cap = live ? 8.0 : 16.0
        return min(cap, base * Double(1 + max(0, recent - 1)))
    }

    mutating func stalled(at now: Double) {
        stallTimes.append(now)
        stallTimes = stallTimes.filter { now - $0 < 120 }
    }
}
