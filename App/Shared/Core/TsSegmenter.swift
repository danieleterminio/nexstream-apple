import Foundation

/// Cuts a progressive MPEG-TS stream (what the line serves for a live channel) into HLS segments, so the system player
/// can play it: every segment starts on a key frame and carries the programme tables. Pure byte work, no decoding.
final class TsSegmenter {
    struct Segment {
        let seq: Int
        let data: Data
        let duration: Double
    }

    /// What the stream carries, read from its programme table.
    struct StreamInfo: Equatable {
        var video: UInt8 = 0
        var audio: [UInt8] = []
        /// True when the system player can decode it (H.264 / HEVC with AAC, AC-3 or E-AC-3). MPEG-2 video and MPEG
        /// layer II audio need the other engine.
        var systemPlayable: Bool {
            let videoOk = video == 0 || video == 0x1B || video == 0x24
            let audioOk = audio.isEmpty || audio.contains { $0 == 0x0F || $0 == 0x81 || $0 == 0x87 || $0 == 0x6A || $0 == 0x7A }
            return videoOk && audioOk && (video != 0 || !audio.isEmpty)
        }
        var summary: String { "video 0x" + String(video, radix: 16) + " audio " + audio.map { "0x" + String($0, radix: 16) }.joined(separator: ",") }
    }

    var onSegment: ((Segment) -> Void)?
    var onInfo: ((StreamInfo) -> Void)?
    /// Longest a segment may get before it is cut even without a key frame (set once the first segments are known).
    var maxDuration: Double = 8
    /// Shortest segment once playback has started.
    var minDuration: Double = 2

    private static let packet = 188
    private var buf = [UInt8]()
    private var patPacket = [UInt8]()
    private var pmtPackets = [UInt8]()
    private var pmtPid = -1
    private var pmtCollect = [UInt8]()
    private var pmtSection = [UInt8]()
    private var pmtExpected = 0
    private var videoPid = -1
    private var videoType: UInt8 = 0
    private var audioPids = Set<Int>()
    private var info: StreamInfo? = nil
    private var current = [UInt8]()
    private var started = false
    private var segStartPts: Int64 = -1
    private var segStartWall = Date()
    private var seq = 0
    private(set) var totalBytes = 0

    func feed(_ data: Data) {
        totalBytes += data.count
        buf.append(contentsOf: data)
        let n = TsSegmenter.packet
        var o = 0
        let count = buf.count
        while o + n <= count {
            if buf[o] != 0x47 {
                // lost sync: look for the next byte that starts two packets in a row
                var s = o + 1
                var found = -1
                while s + n < count {
                    if buf[s] == 0x47 && buf[s + n] == 0x47 { found = s; break }
                    s += 1
                }
                if found < 0 { o = max(o, count - 2 * n); break }
                o = found
                continue
            }
            handle(o)
            o += n
        }
        if o > 0 { buf.removeFirst(min(o, buf.count)) }
    }

    /// Emits what is left (the stream closed).
    func finish() {
        if started && current.count > patPacket.count + pmtPackets.count { emit(duration(-1)) }
    }

    private func handle(_ o: Int) {
        let n = TsSegmenter.packet
        let end = o + n
        let b1 = buf[o + 1], b3 = buf[o + 3]
        let pid = (Int(b1 & 0x1F) << 8) | Int(buf[o + 2])
        let pusi = (b1 & 0x40) != 0
        let afc = (b3 >> 4) & 0x3
        var payload = o + 4
        var rai = false
        if (afc & 2) != 0 {
            let afl = Int(buf[o + 4])
            if afl > 0 && o + 5 < end { rai = (buf[o + 5] & 0x40) != 0 }
            payload = o + 5 + afl
        }
        let hasPayload = (afc & 1) != 0 && payload < end

        if pid == 0 {
            if pusi && hasPayload { parsePat(payload, end, o) }
        } else if pid == pmtPid {
            if hasPayload { collectPmt(payload, end, o, pusi) }
        }

        if pid == videoPid && pusi && hasPayload {
            let pes = readPes(payload, end)
            let key = rai || pes.key
            if !started {
                if !patPacket.isEmpty && !pmtPackets.isEmpty && key { begin(pes.pts) }
            } else {
                let d = duration(pes.pts)
                let minD = seq < 2 ? 1.0 : minDuration
                if (key && d >= minD) || d >= maxDuration { emit(d); begin(pes.pts) }
            }
        } else if videoPid < 0 && info != nil && audioPids.contains(pid) && pusi && hasPayload {
            // radio: no video to cut on
            let pes = readPes(payload, end)
            if !started { begin(pes.pts) }
            else { let d = duration(pes.pts); if d >= 3 { emit(d); begin(pes.pts) } }
        }
        if started { current.append(contentsOf: buf[o..<end]) }
    }

    private func begin(_ pts: Int64) {
        started = true
        segStartPts = pts
        segStartWall = Date()
        current.removeAll(keepingCapacity: true)
        current.append(contentsOf: patPacket)
        current.append(contentsOf: pmtPackets)
    }

    private func emit(_ d: Double) {
        let seg = Segment(seq: seq, data: Data(current), duration: max(0.2, d))
        seq += 1
        onSegment?(seg)
    }

    private func duration(_ pts: Int64) -> Double {
        if pts >= 0 && segStartPts >= 0 {
            var d = pts - segStartPts
            if d < 0 { d += Int64(1) << 33 }
            let s = Double(d) / 90_000
            if s > 0 && s < 30 { return s }
        }
        return Date().timeIntervalSince(segStartWall)
    }

    private func parsePat(_ payload: Int, _ end: Int, _ o: Int) {
        let s = payload + 1 + Int(buf[payload])
        guard s + 8 < end, buf[s] == 0x00 else { return }
        let len = (Int(buf[s + 1] & 0x0F) << 8) | Int(buf[s + 2])
        let stop = min(end, s + 3 + len - 4)
        var i = s + 8
        while i + 4 <= stop {
            let program = (Int(buf[i]) << 8) | Int(buf[i + 1])
            let pid = (Int(buf[i + 2] & 0x1F) << 8) | Int(buf[i + 3])
            if program != 0 {
                if pid != pmtPid { pmtPid = pid; pmtPackets = []; pmtCollect = []; pmtSection = [] }
                break
            }
            i += 4
        }
        patPacket = Array(buf[o..<end])
    }

    private func collectPmt(_ payload: Int, _ end: Int, _ o: Int, _ pusi: Bool) {
        if pusi {
            let s = payload + 1 + Int(buf[payload])
            guard s + 3 < end, buf[s] == 0x02 else { return }
            pmtExpected = 3 + ((Int(buf[s + 1] & 0x0F) << 8) | Int(buf[s + 2]))
            pmtSection = Array(buf[s..<end])
            pmtCollect = Array(buf[o..<end])
        } else {
            if pmtSection.isEmpty || pmtSection.count >= pmtExpected { return }
            pmtSection.append(contentsOf: buf[payload..<end])
            pmtCollect.append(contentsOf: buf[o..<end])
        }
        if pmtExpected > 0 && pmtSection.count >= pmtExpected {
            parsePmt(pmtSection, pmtExpected)
            pmtPackets = pmtCollect
        }
    }

    private func parsePmt(_ sec: [UInt8], _ total: Int) {
        guard total >= 16, sec.count >= total else { return }
        let pil = (Int(sec[10] & 0x0F) << 8) | Int(sec[11])
        var i = 12 + pil
        let stop = total - 4
        var found = StreamInfo()
        var vPid = -1
        var aPids = Set<Int>()
        while i + 5 <= stop {
            let type = sec[i]
            let pid = (Int(sec[i + 1] & 0x1F) << 8) | Int(sec[i + 2])
            let esil = (Int(sec[i + 3] & 0x0F) << 8) | Int(sec[i + 4])
            switch type {
            case 0x01, 0x02, 0x10, 0x1B, 0x24:
                if vPid < 0 { vPid = pid; found.video = type }
            case 0x03, 0x04, 0x0F, 0x11, 0x81, 0x87:
                aPids.insert(pid); found.audio.append(type)
            case 0x06:
                // private data: AC-3 / E-AC-3 are told apart from subtitles and teletext by their descriptor
                var d = i + 5
                let dEnd = min(stop, i + 5 + esil)
                while d + 2 <= dEnd {
                    let tag = sec[d]
                    if tag == 0x6A || tag == 0x7A { aPids.insert(pid); found.audio.append(tag); break }
                    d += 2 + Int(sec[d + 1])
                }
            default: break
            }
            i += 5 + esil
        }
        videoPid = vPid
        videoType = found.video
        audioPids = aPids
        if info != found { info = found; onInfo?(found) }
    }

    /// Reads the start of a PES packet: its time stamp, and whether the picture that follows is a key frame.
    private func readPes(_ p: Int, _ end: Int) -> (pts: Int64, key: Bool) {
        guard p + 9 < end, buf[p] == 0, buf[p + 1] == 0, buf[p + 2] == 1 else { return (-1, false) }
        var pts: Int64 = -1
        if (buf[p + 7] & 0x80) != 0 && p + 14 <= end {
            let a = Int64(buf[p + 9] & 0x0E) << 29
            let b = Int64(buf[p + 10]) << 22
            let c = Int64(buf[p + 11] & 0xFE) << 14
            let d = Int64(buf[p + 12]) << 7
            let e = Int64(buf[p + 13]) >> 1
            pts = a | b | c | d | e
        }
        var i = p + 9 + Int(buf[p + 8])
        var key = false
        while i + 4 < end {
            if buf[i] == 0 && buf[i + 1] == 0 && buf[i + 2] == 1 {
                let h = buf[i + 3]
                if videoType == 0x24 {
                    let t = (h >> 1) & 0x3F
                    if (t >= 16 && t <= 21) || t == 32 || t == 33 { key = true; break }
                    if t <= 9 { break }
                } else if videoType == 0x1B {
                    let t = h & 0x1F
                    if t == 5 || t == 7 { key = true; break }
                    if t == 1 { break }
                } else {
                    // MPEG-2: a sequence header or a group of pictures opens on a key frame
                    if h == 0xB3 || h == 0xB8 { key = true; break }
                    if h == 0x00 { break }
                }
                i += 4
            } else { i += 1 }
        }
        return (pts, key)
    }
}
