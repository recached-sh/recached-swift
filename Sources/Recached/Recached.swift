import Foundation
import RecachedCore

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// A Recached cache on the device: a local copy of the keys you ``watch(_:)``,
/// kept in sync with the server and saved to disk.
///
/// - **Reads** (``get(_:)``, ``getString(_:)``, ``getMatching(_:)``, …) come
///   from local memory. They never wait on the network, so they are safe on
///   the main actor.
/// - **Writes** (``set(_:_:)-(String,String)``, ``delete(_:)``,
///   ``incr(_:by:)``, …) apply locally, are saved together with their place in
///   the outbox before the call returns, and go to the server now or after the
///   next reconnect. Each reaches the server exactly once, even if the app is
///   killed in between.
/// - **Observers** (``observe(_:)``, ``observeMatching(_:)``) yield the
///   current value and then every change, from this device or any other. A
///   write to one key wakes only that key's observers.
///
/// Open one per database file and keep it for the life of the process.
public final class Recached: Sendable {
    private let client: RecachedClient
    private let bus: ChangeBus
    private let pending: StateCell<Int>
    private let state: StateCell<ConnectionState>
    private let transport: Transport?
    private let hooks = Locked<[Registration]>([])

    private init(client: RecachedClient, config: RecachedConfig, sessionConfiguration: URLSessionConfiguration) {
        let bus = ChangeBus(anyMatches: { anyKeyMatches(pattern: $0, keys: $1) })
        let pending = StateCell(Int(client.pendingWrites()))
        let state = StateCell(config.url == nil ? ConnectionState.offline : .connecting)
        self.client = client
        self.bus = bus
        self.pending = pending
        self.state = state
        self.transport = config.url.map { url in
            Transport(
                client: client,
                url: url,
                configuration: sessionConfiguration,
                state: state,
                onChanged: { bus.publish($0) },
                onUnknownChange: { bus.invalidateAll() },
                onAcknowledged: { pending.set(Int(client.pendingWrites())) }
            )
        }
        if let transport {
            transport.connect()
            hooks.withLock { $0 = PlatformHooks.attach(reconnect: { [weak transport] in transport?.connect() }) }
        }
    }

    deinit {
        close()
    }

    /// Open the cache stored at `fileURL`, creating it if needed, and start
    /// syncing when `config` has a URL.
    ///
    /// Everything saved by an earlier run is readable at once, before any
    /// connection, and writes still waiting for the server go out on the first
    /// one.
    ///
    /// - Parameter sessionConfiguration: for the WebSocket's `URLSession`, e.g.
    ///   to set headers or a proxy.
    public static func open(
        at fileURL: URL,
        config: RecachedConfig = RecachedConfig(),
        sessionConfiguration: URLSessionConfiguration = .default
    ) throws -> Recached {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let client = try core {
            try RecachedClient.open(
                path: fileURL.path,
                config: ClientConfig(
                    password: config.password,
                    syncToken: config.syncToken,
                    maxPendingWrites: config.maxPendingWrites
                )
            )
        }
        return Recached(client: client, config: config, sessionConfiguration: sessionConfiguration)
    }

    /// Open the cache named `name` in the app's Application Support directory.
    ///
    /// The directory is excluded from iCloud and device backups on purpose:
    /// restoring it onto another device would give two devices one client
    /// identity, and the server's duplicate suppression would then drop one
    /// device's writes as replays of the other's.
    public static func open(
        named name: String = "recached",
        config: RecachedConfig = RecachedConfig(),
        sessionConfiguration: URLSessionConfiguration = .default
    ) throws -> Recached {
        var directory = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Recached", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #if canImport(Darwin)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
        #endif
        return try open(
            at: directory.appendingPathComponent("\(name).db"),
            config: config,
            sessionConfiguration: sessionConfiguration
        )
    }

    // MARK: Reads — local memory

    /// The value's bytes, or `nil` when absent, expired, or a collection.
    public func get(_ key: String) -> Data? {
        client.get(key: key)
    }

    /// The value as text, or `nil` when absent.
    ///
    /// - Throws: ``RecachedError/notUTF8(key:)`` when the value is binary.
    public func getString(_ key: String) throws -> String? {
        try core { try client.getString(key: key) }
    }

    /// JSON at `path` (the whole document by default), serialised.
    public func getJSON(_ key: String, path: String? = nil) -> String? {
        client.getJson(key: key, path: path)
    }

    public func exists(_ key: String) -> Bool {
        client.exists(key: key)
    }

    /// Seconds until the key expires: `-1` without an expiry, `-2` when absent.
    public func ttl(_ key: String) -> Int64 {
        client.ttl(key: key)
    }

    /// Every local key matching a glob `pattern` (`*`, `?`), sorted by key.
    public func getMatching(_ pattern: String) -> [Entry] {
        client.getMatching(pattern: pattern).map { Entry(key: $0.key, value: $0.value) }
    }

    // MARK: Writes — local, durable, then synced

    public func set(_ key: String, _ value: String) throws {
        try set(key, Data(value.utf8))
    }

    public func set(_ key: String, _ value: Data) throws {
        try write(key) { try client.set(key: key, value: value) }
    }

    /// Set a value that expires after `ttl` seconds, rounded up to whole seconds.
    public func set(_ key: String, _ value: String, ttl: TimeInterval) throws {
        try set(key, Data(value.utf8), ttl: ttl)
    }

    /// Set a value that expires after `ttl` seconds, rounded up to whole seconds.
    public func set(_ key: String, _ value: Data, ttl: TimeInterval) throws {
        precondition(ttl > 0, "ttl must be positive")
        try write(key) { try client.setEx(key: key, value: value, seconds: UInt64(ttl.rounded(.up))) }
    }

    /// Delete a key. Returns whether it existed locally.
    @discardableResult
    public func delete(_ key: String) throws -> Bool {
        try write(key) { try client.del(key: key) }
    }

    /// Add `delta` to an integer counter and return the new local value.
    ///
    /// Queued offline as a delta, so it merges with other clients' increments
    /// on reconnect instead of overwriting them.
    @discardableResult
    public func incr(_ key: String, by delta: Int64 = 1) throws -> Int64 {
        try write(key) { try client.incrBy(key: key, delta: delta) }
    }

    /// Set JSON at `path` (`$`, the whole document, by default).
    public func setJSON(_ key: String, _ json: String, path: String = "$") throws {
        try write(key) { try client.jset(key: key, path: path, json: json) }
    }

    /// Apply an RFC 7386 JSON Merge Patch to the whole document.
    public func mergeJSON(_ key: String, _ patch: String) throws {
        try write(key) { try client.jmerge(key: key, patch: patch) }
    }

    private func write<T>(_ key: String, _ body: () throws -> T) throws -> T {
        // Also after a storage error, which leaves the change applied in
        // memory; a refused command changed nothing, and observers re-read the
        // same value and yield nothing.
        defer {
            bus.publish([key])
            pending.set(Int(client.pendingWrites()))
        }
        return try core(body)
    }

    // MARK: Sync

    /// Keep every key matching `pattern` in sync: the server sends their
    /// current state, then every change, and after each reconnect a fresh
    /// snapshot that also removes keys deleted meanwhile.
    ///
    /// Not remembered across opens; call it again at startup.
    public func watch(_ pattern: String) {
        client.watch(pattern: pattern)
    }

    /// Stop syncing `pattern`. Local copies of its keys stay readable.
    public func unwatch(_ pattern: String) {
        client.unwatch(pattern: pattern)
    }

    /// Replace the sync token, e.g. after refreshing it. Sent now and on every reconnect.
    public func setSyncToken(_ token: String) {
        client.setSyncToken(token: token)
    }

    /// Connect now instead of waiting out the backoff, when a socket is not
    /// already open. Happens by itself when a network becomes available and
    /// when an iOS app returns to the foreground.
    public func reconnectNow() {
        transport?.connect()
    }

    /// Where the connection stands. Always ``ConnectionState/offline`` without a URL.
    public var connectionState: ConnectionState { state.current }

    /// ``connectionState`` now, then each change.
    public func connectionStates() -> AsyncStream<ConnectionState> { state.stream() }

    /// Writes not yet acknowledged by the server, including ones from earlier runs.
    public var pendingWrites: Int { pending.current }

    /// ``pendingWrites`` now, then each change.
    public func pendingWriteCounts() -> AsyncStream<Int> { pending.stream() }

    /// Stop syncing. Reads and writes keep working locally, and queued writes
    /// stay on disk for the next open.
    public func close() {
        let registrations = hooks.withLock { hooks -> [Registration] in
            defer { hooks = [] }
            return hooks
        }
        for registration in registrations { registration.cancel() }
        transport?.close()
    }

    // MARK: Observing

    /// The value of `key` now, then after every change to it — from this
    /// device, from the server, or from a reconnect snapshot. Equal consecutive
    /// values are not repeated, and a consumer that falls behind skips to the
    /// latest value rather than queueing every one.
    public func observe(_ key: String) -> AsyncStream<Data?> {
        values(register: { [bus] in bus.onKey(key, $0) }, read: { [client] in client.get(key: key) })
    }

    /// ``observe(_:)`` as text; a binary value reads as `nil`.
    public func observeString(_ key: String) -> AsyncStream<String?> {
        values(
            register: { [bus] in bus.onKey(key, $0) },
            read: { [client] in client.get(key: key).flatMap { String(data: $0, encoding: .utf8) } }
        )
    }

    /// ``getMatching(_:)`` for `pattern` now, then after every change to a matching key.
    public func observeMatching(_ pattern: String) -> AsyncStream<[Entry]> {
        values(
            register: { [bus] in bus.onPattern(pattern, $0) },
            read: { [client] in client.getMatching(pattern: pattern).map { Entry(key: $0.key, value: $0.value) } }
        )
    }

    /// A stream that re-reads on every invalidation and yields what changed.
    ///
    /// The listener is registered before the first read, so a change in
    /// between cannot be missed. Each read and yield happens under one lock: a
    /// change reported on two threads cannot leave an older value yielded last.
    private func values<T: Equatable & Sendable>(
        register: (@escaping @Sendable () -> Void) -> Registration,
        read: @escaping @Sendable () -> T
    ) -> AsyncStream<T> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let last = Locked<T?>(nil)
            let emit: @Sendable () -> Void = {
                last.withLock { last in
                    let value = read()
                    if last != .some(value) {
                        last = .some(value)
                        continuation.yield(value)
                    }
                }
            }
            let registration = register(emit)
            continuation.onTermination = { _ in registration.cancel() }
            emit()
        }
    }
}
