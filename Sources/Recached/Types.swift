import Foundation
import RecachedCore

/// How a ``Recached`` connects.
public struct RecachedConfig: Sendable, CustomStringConvertible {
    /// The server's WebSocket endpoint, e.g. `wss://cache.example.com`. `nil`
    /// keeps the cache local: reads and writes work, and writes queue until a
    /// later open supplies a URL.
    public var url: URL?
    /// Sent as `AUTH` each time the socket opens.
    public var password: String?
    /// Sent as `SYNC TOKEN` each time the socket opens; replace it later with
    /// ``Recached/setSyncToken(_:)``.
    public var syncToken: String?
    /// Cap on writes waiting for the server. Past it the oldest is dropped.
    /// `nil` keeps the core's default of 10,000.
    public var maxPendingWrites: UInt32?

    public init(url: URL? = nil, password: String? = nil, syncToken: String? = nil, maxPendingWrites: UInt32? = nil) {
        self.url = url
        self.password = password
        self.syncToken = syncToken
        self.maxPendingWrites = maxPendingWrites
    }

    /// Never prints the credentials.
    public var description: String {
        "RecachedConfig(url: \(url?.absoluteString ?? "nil"), password: \(password == nil ? "nil" : "***"), "
            + "syncToken: \(syncToken == nil ? "nil" : "***"), maxPendingWrites: \(maxPendingWrites.map(String.init) ?? "nil"))"
    }
}

/// Where the connection to the server stands. See ``Recached/connectionState``.
public enum ConnectionState: Sendable, Equatable {
    /// No server URL, or the cache was closed. Nothing will be attempted.
    case offline
    /// A socket is being opened.
    case connecting
    /// The socket is open: writes go out at once and server changes arrive live.
    case connected
    /// The last socket closed or failed, and the next attempt is scheduled with
    /// backoff. A regained network or a return to the foreground retries at once.
    case waiting
}

/// A write the server will never apply, from ``Recached/refusedWrites()``.
///
/// Its local effect stays: the cache cannot undo it. Keys a
/// ``Recached/watch(_:)`` pattern covers get the server's values back from a
/// fresh snapshot a moment later; any other key keeps the refused value until
/// the app changes it.
public struct RefusedWrite: Sendable, Hashable {
    /// The keys the write would have changed.
    public let keys: [String]
    /// The server's error, such as `NOSCOPE key 'k' is read-only on this connection`.
    public let reason: String

    public init(keys: [String], reason: String) {
        self.keys = keys
        self.reason = reason
    }
}

/// One key and its value, from ``Recached/getMatching(_:)`` or
/// ``Recached/observeMatching(_:)``.
public struct Entry: Sendable, Hashable {
    public let key: String
    /// The bytes of a string value, or `nil` for a collection, which has no
    /// single-value form.
    public let value: Data?

    public init(key: String, value: Data?) {
        self.key = key
        self.value = value
    }

    /// The value as text, or `nil` when absent or not valid UTF-8.
    public var string: String? { value.flatMap { String(data: $0, encoding: .utf8) } }
}

/// Everything a ``Recached`` call can fail with.
public enum RecachedError: Error, Sendable, Equatable, LocalizedError {
    /// The on-device database could not be read or written. On a write, the
    /// change was applied in memory and will sync while the app keeps running,
    /// but would not survive a restart.
    case storage(String)
    /// The engine refused the command — a `WRONGTYPE`, an invalid JSON path, a
    /// counter that is not an integer. Nothing was applied or queued.
    case command(String)
    /// The key holds bytes that are not valid UTF-8; read it with ``Recached/get(_:)``.
    case notUTF8(key: String)

    public var errorDescription: String? {
        switch self {
        case .storage(let reason): return "storage: \(reason)"
        case .command(let reason): return reason
        case .notUTF8(let key): return "value of \"\(key)\" is not valid UTF-8"
        }
    }
}

/// Run a call into the core, rethrowing its errors as this package's.
func core<T>(_ body: () throws -> T) throws -> T {
    do {
        return try body()
    } catch let error as RecachedCore.RecachedError {
        switch error {
        case .Storage(let reason): throw RecachedError.storage(reason)
        case .Command(let reason): throw RecachedError.command(reason)
        case .NotUtf8(let key): throw RecachedError.notUTF8(key: key)
        }
    }
}
