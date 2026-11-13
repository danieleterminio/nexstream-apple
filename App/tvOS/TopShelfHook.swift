import TVServices

/// Starts the Top Shelf feed and tells tvOS to reload the extension's rows whenever the feed changes.
enum TopShelfHook {
    @MainActor static func start() {
        let p = NexCore.shared.topShelf
        p.onChanged = { TVTopShelfContentProvider.topShelfContentDidChange() }
        p.start()
    }
}
