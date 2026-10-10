import Foundation

/// A listener registration; `cancel()` removes it and is safe to repeat.
final class Registration: Sendable {
    private let onCancel: @Sendable () -> Void

    init(_ onCancel: @escaping @Sendable () -> Void) {
        self.onCancel = onCancel
    }

    func cancel() {
        onCancel()
    }
}

/// Routes changed keys to the listeners of those keys and of patterns that
/// match them.
///
/// Listeners are invalidation signals, not values: they are told *that* a key
/// changed and re-read it. They run on whichever thread reported the change —
/// the socket's delegate queue for server frames, the caller for local
/// writes — so they must return at once.
final class ChangeBus: @unchecked Sendable {
    typealias Listener = @Sendable () -> Void

    private let lock = NSLock()
    private var keyListeners: [String: [UUID: Listener]] = [:]
    private var patternListeners: [String: [UUID: Listener]] = [:]
    /// The core's glob matcher, so routing agrees with the server about which
    /// keys a pattern covers.
    private let anyMatches: @Sendable (_ pattern: String, _ keys: [String]) -> Bool

    init(anyMatches: @escaping @Sendable (_ pattern: String, _ keys: [String]) -> Bool) {
        self.anyMatches = anyMatches
    }

    private enum Kind: Sendable {
        case key, pattern
    }

    func onKey(_ key: String, _ listener: @escaping Listener) -> Registration {
        add(.key, key, listener)
    }

    func onPattern(_ pattern: String, _ listener: @escaping Listener) -> Registration {
        add(.pattern, pattern, listener)
    }

    func publish(_ keys: [String]) {
        guard !keys.isEmpty else { return }
        let (byKey, byPattern) = snapshot { keyListeners, patternListeners in
            (keys.flatMap { keyListeners[$0]?.values.map { $0 } ?? [] }, patternListeners)
        }
        for listener in byKey { listener() }
        // One call into the core per pattern, not per key: a reconnect
        // snapshot can name thousands of keys.
        for (pattern, listeners) in byPattern where anyMatches(pattern, keys) {
            for listener in listeners.values { listener() }
        }
    }

    /// Every listener re-reads: for when what changed is not known.
    func invalidateAll() {
        let all = snapshot { keyListeners, patternListeners in
            keyListeners.values.flatMap(\.values) + patternListeners.values.flatMap(\.values)
        }
        for listener in all { listener() }
    }

    /// Listeners are called outside the lock, from a copy.
    private func snapshot<T>(
        _ body: ([String: [UUID: Listener]], [String: [UUID: Listener]]) -> T
    ) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(keyListeners, patternListeners)
    }

    private func add(_ kind: Kind, _ name: String, _ listener: @escaping Listener) -> Registration {
        let id = UUID()
        lock.lock()
        switch kind {
        case .key: keyListeners[name, default: [:]][id] = listener
        case .pattern: patternListeners[name, default: [:]][id] = listener
        }
        lock.unlock()
        return Registration { [weak self] in self?.remove(kind, name, id) }
    }

    private func remove(_ kind: Kind, _ name: String, _ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        switch kind {
        case .key: Self.remove(id, name, from: &keyListeners)
        case .pattern: Self.remove(id, name, from: &patternListeners)
        }
    }

    private static func remove(_ id: UUID, _ name: String, from registry: inout [String: [UUID: Listener]]) {
        registry[name]?[id] = nil
        if registry[name]?.isEmpty == true { registry[name] = nil }
    }
}
