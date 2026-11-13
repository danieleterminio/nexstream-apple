import Foundation

/// Keeps the Apple TV Top Shelf feed (`TopShelfFeed`) in step with the profile in use: its "Continua a guardare" and its
/// favourite channels. Same rules as Android's TvChannels: republished 2 s after the last change; a cold start without a
/// profile keeps the rows of the last one (they stay as they were while the app was closed) and only leaving the profile
/// ("Cambia profilo") empties them; titles not cached yet are fetched only with the VPN on.
final class TopShelfPublisher {
    private let core: NexCore
    private var watches = [Watch]()
    private var pending: DispatchWorkItem?
    private let queue = DispatchQueue(label: "nx.topshelf")
    private var last: TopShelfFeed?
    /// Tells tvOS to ask the extension again (TVTopShelfContentProvider.topShelfContentDidChange, set by the TV app).
    var onChanged: (() -> Void)?

    init(core: NexCore) { self.core = core }

    func start() {
        if !watches.isEmpty { return }
        if TopShelfFeed.fileURL == nil { NxLog.i("NxTopShelf", "no App Group folder: the static Top Shelf image stays") ; return }
        last = TopShelfFeed.load()
        watches.append(core.profiles.current.observe { [weak self] _ in self?.schedule() })
        watches.append(Vpn.shared.active.observe(fire: false) { [weak self] on in if on { self?.schedule() } })
        let tables: Set<String> = ["progress", "favorites", "channels", "all"]
        watches.append(core.db.changes.observe { [weak self] t in if tables.contains(t) { self?.schedule() } })
    }

    private func schedule() {
        queue.async {
            self.pending?.cancel()
            let w = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                Task { await self.publish() }
            }
            self.pending = w
            self.queue.asyncAfter(deadline: .now() + 2, execute: w)
        }
    }

    private func publish() async {
        let pid = core.profiles.id
        if pid <= 0 && !core.profiles.pickRequested { return }
        let feed = pid > 0 ? await build(pid) : TopShelfFeed(profileId: 0, sections: [])
        if feed == last { return }
        if feed.save() {
            last = feed
            NxLog.i("NxTopShelf", "published: " + feed.sections.map { "\($0.title) \($0.items.count)" }.joined(separator: ", "))
            DispatchQueue.main.async { self.onChanged?() }
        }
    }

    private func build(_ pid: Int64) async -> TopShelfFeed {
        var sections = [TopShelfFeed.Section]()
        // same selection as the Home row: latest position per title, finished films left out, 12 cards
        var cont = [TopShelfFeed.Item]()
        for p in core.library.continueWatching(pid).prefix(20) {
            if p.media == "movie" && p.completed { continue }
            var t = core.catalog.cachedTitle(p.tmdbId, p.media)
            if t == nil && Vpn.shared.active.value { t = await core.catalog.ensureTitle(p.tmdbId, p.media) }
            guard let title = t else { continue }
            let tv = title.media == "tv"
            let progress: Double? = (!p.completed && p.durationMs > 0) ? min(1, Double(p.positionMs) / Double(p.durationMs)) : nil
            cont.append(TopShelfFeed.Item(
                id: "vod-\(title.media)-\(title.tmdbId)",
                title: tv ? "\(title.title) · S\(p.season) E\(p.episode)" : title.title,
                image: Img.tmdb(title.backdropPath ?? title.posterPath, "w780"),
                shape: "hdtv",
                open: "nexstream://open/vod/\(title.media)/\(title.tmdbId)?profile=\(pid)",
                play: "nexstream://open/resume/\(title.media)/\(title.tmdbId)?profile=\(pid)",
                progress: progress))
            if cont.count >= 12 { break }
        }
        if !cont.isEmpty { sections.append(TopShelfFeed.Section(title: "Continua a guardare", items: cont)) }
        let favs = core.channels.favorites().prefix(20).map { c -> TopShelfFeed.Item in
            let link = "nexstream://open/live/\(c.streamId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? c.streamId)?profile=\(pid)"
            let art = [c.logo, c.icon].compactMap { $0 }.first { $0.hasPrefix("http") }
            return TopShelfFeed.Item(id: "live-\(c.streamId)", title: c.name, image: art, shape: "square", open: link, play: link, progress: nil)
        }
        if !favs.isEmpty { sections.append(TopShelfFeed.Section(title: "I tuoi canali preferiti", items: Array(favs))) }
        return TopShelfFeed(profileId: pid, sections: sections)
    }
}
