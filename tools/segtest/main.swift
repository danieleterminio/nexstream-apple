import Foundation

// Local check of TsSegmenter: feeds a .ts file in odd-sized chunks, writes the segments and a playlist.
let args = CommandLine.arguments
let input = URL(fileURLWithPath: args[1])
let outDir = URL(fileURLWithPath: args[2])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let data = try! Data(contentsOf: input)
let seg = TsSegmenter()
var lines = [String]()
var maxD = 0.0
seg.onInfo = { print("info:", $0.summary, "systemPlayable:", $0.systemPlayable) }
seg.onSegment = { s in
    try! s.data.write(to: outDir.appendingPathComponent("seg\(s.seq).ts"))
    lines.append("#EXTINF:\(String(format: "%.3f", s.duration)),\nseg\(s.seq).ts")
    maxD = max(maxD, s.duration)
    print("segment \(s.seq): \(s.data.count) bytes, \(String(format: "%.2f", s.duration)) s")
}
var o = 0
var step = 1000
while o < data.count {
    let n = min(step, data.count - o)
    seg.feed(data.subdata(in: o..<(o + n)))
    o += n
    step = step == 1000 ? 7777 : (step == 7777 ? 188 * 50 + 3 : 1000)
}
seg.finish()
let m3u = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:\(Int(maxD.rounded(.up)))\n#EXT-X-MEDIA-SEQUENCE:0\n" + lines.joined(separator: "\n") + "\n#EXT-X-ENDLIST\n"
try! m3u.write(to: outDir.appendingPathComponent("live.m3u8"), atomically: true, encoding: .utf8)
print("total bytes in:", data.count)
