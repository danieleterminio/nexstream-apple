import Foundation

/// Keeps an observation alive; cancelling (or dropping) it stops the callbacks.
final class Subscription {
    private var onCancel: (() -> Void)?
    init(_ onCancel: @escaping () -> Void) { self.onCancel = onCancel }
    func cancel() { onCancel?(); onCancel = nil }
    deinit { onCancel?() }
}

/// A value that tells its observers when it changes (the role StateFlow plays in the Android app).
/// Callbacks run on the thread that set the value; the UI layer hops to the main thread itself.
final class Observable<T> {
    private let lock = NSLock()
    private var current: T
    private var subs = [Int: (T) -> Void]()
    private var nextId = 0

    init(_ value: T) { current = value }

    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return current }
        set {
            lock.lock()
            current = newValue
            let handlers = Array(subs.values)
            lock.unlock()
            for h in handlers { h(newValue) }
        }
    }

    /// Observes changes; with `fire` the current value is delivered at once.
    func observe(fire: Bool = true, _ handler: @escaping (T) -> Void) -> Subscription {
        lock.lock()
        let id = nextId; nextId += 1
        subs[id] = handler
        let now = current
        lock.unlock()
        if fire { handler(now) }
        return Subscription { [weak self] in
            guard let self = self else { return }
            self.lock.lock(); self.subs[id] = nil; self.lock.unlock()
        }
    }
}

/// Events without a current value (SharedFlow).
final class Signal<T> {
    private let lock = NSLock()
    private var subs = [Int: (T) -> Void]()
    private var nextId = 0

    func send(_ value: T) {
        lock.lock(); let handlers = Array(subs.values); lock.unlock()
        for h in handlers { h(value) }
    }

    func observe(_ handler: @escaping (T) -> Void) -> Subscription {
        lock.lock()
        let id = nextId; nextId += 1
        subs[id] = handler
        lock.unlock()
        return Subscription { [weak self] in
            guard let self = self else { return }
            self.lock.lock(); self.subs[id] = nil; self.lock.unlock()
        }
    }
}

/// A mutual-exclusion lock for async code (kotlinx `Mutex`): waiters queue up and resume in order.
actor AsyncLock {
    private var locked = false
    private var waiters = [CheckedContinuation<Void, Never>]()

    func lock() async {
        if !locked { locked = true; return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in waiters.append(c) }
    }
    /// Takes the lock only if it is free.
    func tryLock() -> Bool {
        if locked { return false }
        locked = true
        return true
    }
    func unlock() {
        if waiters.isEmpty { locked = false } else { waiters.removeFirst().resume() }
    }
    func withLock<T>(_ body: () async throws -> T) async rethrows -> T {
        await lock()
        do { let r = try await body(); unlock(); return r } catch { unlock(); throw error }
    }
}

/// Runs `body` over `items` with at most `limit` at a time, results in the order of the items.
func mapConcurrent<T, R>(_ items: [T], limit: Int = 4, _ body: @escaping (T) async -> R) async -> [R] {
    if items.isEmpty { return [] }
    return await withTaskGroup(of: (Int, R).self) { group in
        var out = [R?](repeating: nil, count: items.count)
        var next = 0
        let n = max(1, limit)
        while next < items.count && next < n {
            let i = next; group.addTask { (i, await body(items[i])) }; next += 1
        }
        while let (i, r) = await group.next() {
            out[i] = r
            if next < items.count { let j = next; group.addTask { (j, await body(items[j])) }; next += 1 }
        }
        return out.compactMap { $0 }
    }
}

/// `runCatching { }.getOrNull()` for async work.
func attempt<T>(_ tag: String = "", _ body: () async throws -> T) async -> T? {
    do { return try await body() } catch {
        if !tag.isEmpty { NxLog.w(tag, "\(error)") }
        return nil
    }
}
