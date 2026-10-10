import Foundation

#if canImport(Combine)
    import Combine
#endif
#if canImport(Observation)
    import Observation
#endif

/// Holds the task feeding a model, and cancels it when the model goes away.
final class Feed: Sendable {
    private let task: Task<Void, Never>

    init(_ task: Task<Void, Never>) {
        self.task = task
    }

    deinit {
        task.cancel()
    }
}

/// A weak reference a feeding task can hold without keeping its model alive.
final class WeakModel<Model: AnyObject>: @unchecked Sendable {
    weak var model: Model?
}

#if canImport(Combine)
    /// One key's value as an `ObservableObject`, for SwiftUI on iOS 15+ and
    /// macOS 12+:
    ///
    /// ```swift
    /// @StateObject private var title = ObservableKey(cache, "todo:42:title")
    /// var body: some View { Text(title.string ?? "") }
    /// ```
    ///
    /// On iOS 17+ and macOS 14+, ``ObservedKey`` does the same with Observation.
    @MainActor
    public final class ObservableKey: ObservableObject {
        /// The current value; see ``Recached/get(_:)``.
        @Published public private(set) var value: Data?
        private var feed: Feed?

        public init(_ cache: Recached, _ key: String) {
            value = cache.get(key)
            let weak = WeakModel<ObservableKey>()
            let stream = cache.observe(key)
            feed = Feed(
                Task { @MainActor in
                    for await value in stream {
                        guard let model = weak.model else { return }
                        model.value = value
                    }
                })
            weak.model = self
        }

        /// The value as text, or `nil` when absent or binary.
        public var string: String? { value.flatMap { String(data: $0, encoding: .utf8) } }
    }
#endif

#if canImport(Observation)
    /// One key's value as an Observation model, for SwiftUI on iOS 17+ and
    /// macOS 14+:
    ///
    /// ```swift
    /// @State private var title = ObservedKey(cache, "todo:42:title")
    /// var body: some View { Text(title.string ?? "") }
    /// ```
    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @MainActor
    @Observable
    public final class ObservedKey {
        /// The current value; see ``Recached/get(_:)``.
        public private(set) var value: Data?
        @ObservationIgnored private var feed: Feed?

        public init(_ cache: Recached, _ key: String) {
            value = cache.get(key)
            let weak = WeakModel<ObservedKey>()
            let stream = cache.observe(key)
            feed = Feed(
                Task { @MainActor in
                    for await value in stream {
                        guard let model = weak.model else { return }
                        model.value = value
                    }
                })
            weak.model = self
        }

        /// The value as text, or `nil` when absent or binary.
        public var string: String? { value.flatMap { String(data: $0, encoding: .utf8) } }
    }
#endif
