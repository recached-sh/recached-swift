import Foundation

/// A value behind a lock.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}

/// A current value plus a stream of its changes, like Kotlin's `StateFlow`.
///
/// Each stream starts with the current value and keeps only the newest one
/// when its consumer falls behind: a slow consumer skips intermediate values
/// but always ends on the latest.
final class StateCell<Value: Sendable & Equatable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    private var continuations: [UUID: AsyncStream<Value>.Continuation] = [:]

    init(_ value: Value) {
        self.value = value
    }

    var current: Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Value) {
        lock.lock()
        defer { lock.unlock() }
        guard newValue != value else { return }
        value = newValue
        // Under the lock, so two concurrent sets cannot reach a consumer out
        // of order. `yield` only buffers; it never blocks.
        for continuation in continuations.values { continuation.yield(newValue) }
    }

    func stream() -> AsyncStream<Value> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            continuation.onTermination = { [weak self] _ in self?.remove(id) }
            lock.lock()
            defer { lock.unlock() }
            continuations[id] = continuation
            continuation.yield(value)
        }
    }

    private func remove(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        continuations[id] = nil
    }
}
