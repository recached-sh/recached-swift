import Foundation
import RecachedCore

/// Where synchronization stands. See ``Recached/syncStatus``.
///
/// An open socket is only the start: ``ready`` also needs authentication, the
/// replay of every write queued while offline, and the snapshot of every
/// pattern watched when the socket opened.
public enum SyncPhase: Sendable, Equatable {
    /// No socket, or the last one closed.
    case disconnected
    /// A socket is being opened.
    case connecting
    /// The password, sync token or protocol options are not yet answered.
    case authenticating
    /// Writes queued while offline have been sent and not all answered.
    case replaying
    /// The snapshots of the patterns watched at connect time have not all arrived.
    case hydrating
    /// Synchronized. Patterns watched later report through ``Recached/subscriptionStates``.
    case ready
    /// Open but impaired; ``SyncStatus/problem`` says why.
    case degraded
}

/// Why a watched pattern was refused.
public enum SubscriptionFailure: Sendable, Equatable {
    /// More keys match than the server sends in one snapshot. Nothing local was reconciled.
    case snapshotTooLarge
    /// Outside the sync token's scope.
    case outOfScope
    case other
}

/// A connection-level problem. `reason` is the server's text, which never contains a credential.
public enum SyncProblem: Sendable, Equatable {
    case authFailed(reason: String)
    case scopeRefused(reason: String)
    /// A queued write was refused for a reason that can clear; it replays on the next connection.
    case writeDeferred(reason: String)
    case subscriptionFailed(pattern: String, failure: SubscriptionFailure, reason: String)
    /// A frame from the server could not be parsed; the socket is replaced.
    case malformedFrame
}

/// The synchronization status, from ``Recached/syncStatus``.
public struct SyncStatus: Sendable, Equatable {
    public let phase: SyncPhase
    /// What is wrong, when something is; while disconnected, what ended the last connection.
    public let problem: SyncProblem?
    /// When ``phase`` last became ``SyncPhase/ready``, or `nil`: the moment
    /// synchronization completed — never merely when a socket opened.
    public let lastSyncedAt: Date?

    public init(phase: SyncPhase, problem: SyncProblem? = nil, lastSyncedAt: Date? = nil) {
        self.phase = phase
        self.problem = problem
        self.lastSyncedAt = lastSyncedAt
    }
}

/// One watched pattern's progress, from ``Recached/subscriptionStates``.
public enum SubscriptionState: Sendable, Equatable {
    /// Waiting for a connection; local copies are what the last session left.
    case pending
    /// Snapshot requested, not yet received.
    case hydrating
    /// Snapshot applied; changes stream as they happen.
    case current
    /// Refused by the server; retried on the next connection.
    case failed(failure: SubscriptionFailure, reason: String)
}

extension SyncPhase {
    init(_ core: RecachedCore.SyncPhase) {
        switch core {
        case .disconnected: self = .disconnected
        case .connecting: self = .connecting
        case .authenticating: self = .authenticating
        case .replaying: self = .replaying
        case .hydrating: self = .hydrating
        case .ready: self = .ready
        case .degraded: self = .degraded
        }
    }
}

extension SubscriptionFailure {
    init(_ core: RecachedCore.SubscriptionFailure) {
        switch core {
        case .snapshotTooLarge: self = .snapshotTooLarge
        case .outOfScope: self = .outOfScope
        case .other: self = .other
        }
    }
}

extension SyncProblem {
    init(_ core: RecachedCore.SyncError) {
        switch core {
        case .authFailed(let reason): self = .authFailed(reason: reason)
        case .scopeRefused(let reason): self = .scopeRefused(reason: reason)
        case .writeDeferred(let reason): self = .writeDeferred(reason: reason)
        case .subscriptionFailed(let pattern, let failure, let reason):
            self = .subscriptionFailed(pattern: pattern, failure: SubscriptionFailure(failure), reason: reason)
        case .malformedFrame: self = .malformedFrame
        }
    }
}

extension SubscriptionState {
    init(_ core: RecachedCore.SubscriptionState) {
        switch core {
        case .pending: self = .pending
        case .hydrating: self = .hydrating
        case .current: self = .current
        case .failed(let failure, let reason): self = .failed(failure: SubscriptionFailure(failure), reason: reason)
        }
    }
}
