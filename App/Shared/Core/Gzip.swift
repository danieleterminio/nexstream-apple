import Foundation
#if canImport(zlib)
import zlib
#endif

enum Gzip {
    struct Failure: Error, CustomStringConvertible { let description: String }

    /// True when the file starts with the gzip magic bytes.
    static func isGzip(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        let d = h.readData(ofLength: 2)
        return d.count == 2 && d[0] == 0x1f && d[1] == 0x8b
    }

    /// Expands a gzip file into `dest`, a chunk at a time (the XMLTV guides are ~100 MB once expanded).
    static func expand(_ src: URL, to dest: URL) throws {
        #if canImport(zlib)
        guard let input = InputStream(url: src) else { throw Failure(description: "cannot open \(src.lastPathComponent)") }
        FileManager.default.createFile(atPath: dest.path, contents: nil)
        guard let out = try? FileHandle(forWritingTo: dest) else { throw Failure(description: "cannot write \(dest.lastPathComponent)") }
        defer { try? out.close() }
        input.open(); defer { input.close() }

        var stream = z_stream()
        // 15 window bits + 16 = gzip wrapper
        guard inflateInit2_(&stream, 15 + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw Failure(description: "inflateInit") }
        defer { inflateEnd(&stream) }

        let inSize = 64 * 1024, outSize = 256 * 1024
        let inBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: inSize); defer { inBuf.deallocate() }
        let outBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: outSize); defer { outBuf.deallocate() }
        var done = false
        while !done {
            let n = input.read(inBuf, maxLength: inSize)
            if n < 0 { throw Failure(description: "read error") }
            if n == 0 { break }
            stream.next_in = inBuf
            stream.avail_in = UInt32(n)
            repeat {
                stream.next_out = outBuf
                stream.avail_out = UInt32(outSize)
                let rc = inflate(&stream, Z_NO_FLUSH)
                if rc != Z_OK && rc != Z_STREAM_END && rc != Z_BUF_ERROR { throw Failure(description: "inflate \(rc)") }
                let have = outSize - Int(stream.avail_out)
                if have > 0 { out.write(Data(bytes: outBuf, count: have)) }
                if rc == Z_STREAM_END {
                    // concatenated members: start over on what is left
                    if stream.avail_in > 0 { inflateReset(&stream) } else { done = true }
                }
                if done { break }
                if rc == Z_BUF_ERROR && stream.avail_in == 0 { break }
            } while stream.avail_in > 0 || stream.avail_out == 0
        }
        #else
        throw Failure(description: "gzip not available on this platform")
        #endif
    }
}
