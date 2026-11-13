import TVServices

/// The rows above NexStream's icon on the Apple TV home: what the app last wrote in the App Group folder
/// (`TopShelfFeed`). Select on a card opens the title page or the channel; Play carries on from where it was left.
/// No feed (first start, or a signature without the App Group) → nil, and tvOS shows the static Top Shelf image.
final class ContentProvider: TVTopShelfContentProvider {
    override func loadTopShelfContent(completionHandler: @escaping (TVTopShelfContent?) -> Void) {
        guard let feed = TopShelfFeed.load() else { completionHandler(nil); return }
        var sections = [TVTopShelfItemCollection<TVTopShelfSectionedItem>]()
        for s in feed.sections {
            let items = s.items.compactMap { ContentProvider.item($0) }
            if items.isEmpty { continue }
            let c = TVTopShelfItemCollection(items: items)
            c.title = s.title
            sections.append(c)
        }
        completionHandler(sections.isEmpty ? nil : TVTopShelfSectionedContent(sections: sections))
    }

    private static func item(_ i: TopShelfFeed.Item) -> TVTopShelfSectionedItem? {
        guard let open = URL(string: i.open) else { return nil }
        let it = TVTopShelfSectionedItem(identifier: i.id)
        it.title = i.title
        it.imageShape = i.shape == "square" ? .square : .hdtv
        if let s = i.image, let u = URL(string: s) { it.setImageURL(u, for: [.screenScale1x, .screenScale2x]) }
        it.displayAction = TVTopShelfAction(url: open)
        if let p = i.play.flatMap({ URL(string: $0) }) { it.playAction = TVTopShelfAction(url: p) }
        if let p = i.progress, p > 0 { it.playbackProgress = p }
        return it
    }
}
