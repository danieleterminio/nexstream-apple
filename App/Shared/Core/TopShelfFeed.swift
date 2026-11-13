import Foundation

/// What the Apple TV home shows above NexStream's icon (Top Shelf): written by the app, read by the Top Shelf extension
/// through the App Group's shared folder. Same two rows as the Android TV home channels (data/TvChannels.kt):
/// "Continua a guardare" and "I tuoi canali preferiti". Every card is a link the app already understands
/// (nexstream://open/vod|resume|live/…).
///
/// The shared folder exists only when the app and the extension are signed with a profile that has the App Group
/// `group.app.nexstream.one`. Without it (a wildcard profile, a signing tool that drops it) `fileURL` is nil: the app
/// writes nothing and the system shows the static Top Shelf image of the asset catalogue instead.
struct TopShelfFeed: Codable, Equatable {
    struct Item: Codable, Equatable {
        var id: String
        var title: String
        /// http(s) artwork; the system loads it.
        var image: String?
        /// "hdtv" (16:9) or "square".
        var shape: String
        /// Select on the card: the title page / the channel.
        var open: String
        /// Play/pause on the card: carries on from where it was left.
        var play: String?
        /// 0…1 for the progress bar under the card.
        var progress: Double?
    }
    struct Section: Codable, Equatable {
        var title: String
        var items: [Item]
    }
    var profileId: Int64
    var sections: [Section]

    static let appGroup = "group.app.nexstream.one"

    static var fileURL: URL? {
        #if os(iOS) || os(tvOS)
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?.appendingPathComponent("topshelf.json")
        #else
        return nil
        #endif
    }

    static func load() -> TopShelfFeed? {
        guard let u = fileURL, let d = try? Data(contentsOf: u) else { return nil }
        return try? JSONDecoder().decode(TopShelfFeed.self, from: d)
    }

    /// Writes the feed; false when there is no shared folder (no App Group in the signature).
    @discardableResult
    func save() -> Bool {
        guard let u = TopShelfFeed.fileURL, let d = try? JSONEncoder().encode(self) else { return false }
        do { try d.write(to: u, options: .atomic); return true } catch { return false }
    }
}
