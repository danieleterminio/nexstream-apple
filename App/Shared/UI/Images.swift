import SwiftUI
import UIKit
import ImageIO

/// Remote images: disk cache through URLCache, decoded bitmaps in memory, pictures decoded at the size they are shown
/// (a 1920 px still for a 250 pt card would waste both time and memory). Requests obey the VPN filter like everything else.
final class ImageLoader {
    static let shared = ImageLoader()
    private let memory = NSCache<NSString, UIImage>()
    private let session: URLSession
    private let lock = NSLock()
    private var failures = [String: Date]()

    private init() {
        let c = URLSessionConfiguration.default
        let low = ProcessInfo.processInfo.physicalMemory < 3_000_000_000
        c.urlCache = URLCache(memoryCapacity: 8 * 1024 * 1024, diskCapacity: (low ? 100 : 200) * 1024 * 1024, diskPath: "nx-images")
        c.requestCachePolicy = .returnCacheDataElseLoad
        c.timeoutIntervalForRequest = 20
        c.httpMaximumConnectionsPerHost = 6
        c.httpAdditionalHeaders = ["User-Agent": Http.browserUA]
        session = URLSession(configuration: c)
        memory.totalCostLimit = (low ? 40 : 90) * 1024 * 1024
    }

    func cached(_ url: String, _ maxPixel: CGFloat) -> UIImage? { memory.object(forKey: "\(Int(maxPixel))|\(url)" as NSString) }

    func load(_ url: String, maxPixel: CGFloat) async -> UIImage? {
        let key = "\(Int(maxPixel))|\(url)" as NSString
        if let hit = memory.object(forKey: key) { return hit }
        if !Vpn.shared.active.value { return nil }
        lock.lock()
        if let failed = failures[url], Date().timeIntervalSince(failed) < 300 { lock.unlock(); return nil }
        lock.unlock()
        guard let u = URL(string: url) ?? URL(string: url.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? "") else { return nil }
        let data: Data? = await withCheckedContinuation { (c: CheckedContinuation<Data?, Never>) in
            session.dataTask(with: URLRequest(url: u)) { d, r, _ in
                let status = (r as? HTTPURLResponse)?.statusCode ?? 0
                c.resume(returning: (status >= 200 && status < 300) ? d : nil)
            }.resume()
        }
        guard let d = data, let img = ImageLoader.decode(d, maxPixel: maxPixel) else {
            lock.lock(); failures[url] = Date(); if failures.count > 500 { failures.removeAll() }; lock.unlock()
            return nil
        }
        memory.setObject(img, forKey: key, cost: Int(img.size.width * img.size.height * img.scale * img.scale * 4))
        return img
    }

    static func decode(_ data: Data, maxPixel: CGFloat) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceShouldCacheImmediately: true, kCGImageSourceThumbnailMaxPixelSize: max(64, maxPixel)]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// Mean luminance (0…1) of the opaque pixels: tells a white title logo from a black one.
    static func luminance(_ data: Data) -> Double? {
        guard let img = decode(data, maxPixel: 96)?.cgImage else { return nil }
        let w = img.width, h = img.height
        guard w > 0, h > 0 else { return nil }
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        var sum = 0.0, n = 0
        var i = 0
        while i < px.count {
            let a = Double(px[i + 3])
            if a > 128 {
                // un-premultiply
                let r = Double(px[i]) * 255 / a, g = Double(px[i + 1]) * 255 / a, b = Double(px[i + 2]) * 255 / a
                sum += 0.2126 * r + 0.7152 * g + 0.0722 * b; n += 1
            }
            i += 12
        }
        return n < 30 ? nil : sum / Double(n) / 255.0
    }
}

/// An image from the network. `fit` keeps logos whole; otherwise the picture fills its frame.
struct NxImage<Placeholder: View>: View {
    let url: String?
    var fit: Bool = false
    var maxPixel: CGFloat = 800
    var alignment: Alignment = .center
    @ViewBuilder var placeholder: () -> Placeholder
    @State private var image: UIImage? = nil
    @State private var loadedUrl: String? = nil

    var body: some View {
        ZStack(alignment: alignment) {
            if let img = image, loadedUrl == url {
                if fit { Image(uiImage: img).resizable().aspectRatio(contentMode: .fit) }
                else {
                    Color.clear.overlay(alignment: alignment) { Image(uiImage: img).resizable().aspectRatio(contentMode: .fill) }.clipped()
                }
            } else { placeholder() }
        }
        .task(id: url) {
            guard let u = url, !u.isEmpty else { image = nil; loadedUrl = nil; return }
            if let hit = ImageLoader.shared.cached(u, maxPixel) { image = hit; loadedUrl = u; return }
            let img = await ImageLoader.shared.load(u, maxPixel: maxPixel)
            if !Task.isCancelled { withAnimation(.easeOut(duration: 0.2)) { image = img; loadedUrl = u } }
        }
    }
}

extension NxImage where Placeholder == Color {
    init(_ url: String?, fit: Bool = false, maxPixel: CGFloat = 800, alignment: Alignment = .center) {
        self.init(url: url, fit: fit, maxPixel: maxPixel, alignment: alignment, placeholder: { Color.clear })
    }
}

/// Channel brand over artwork: the broadcaster's white logo when we have it, else the provider logo on a dark chip, else the name.
struct ChannelLogo: View {
    let channel: ChannelEntity
    var height: CGFloat = 22
    var body: some View {
        let h = Metrics.u(height)
        if let logo = channel.logo {
            NxImage(logo, fit: true, maxPixel: 320, alignment: .leading).frame(maxWidth: h * 3.2, maxHeight: h, alignment: .leading)
        } else if let icon = channel.icon {
            NxImage(icon, fit: true, maxPixel: 320, alignment: .leading).frame(maxWidth: h * 3, maxHeight: h - Metrics.u(4), alignment: .leading)
                .padding(.horizontal, Metrics.u(6)).padding(.vertical, Metrics.u(3))
                .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: Metrics.u(6), style: .continuous))
        } else {
            Text(channel.name.uppercased()).font(NxFont.label).tracking(0.8).foregroundStyle(NxColor.text).lineLimit(1)
        }
    }
}
