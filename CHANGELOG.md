# Changelog

## [Unreleased]

Requires recached-mobile from recached 0.5.

- `syncStatus` / `syncStatuses()`: the synchronization lifecycle — `.ready`
  only once the session is authenticated, queued writes are replayed and
  answered, and the patterns watched at connect time are hydrated — with the
  current problem and `lastSyncedAt`. `subscriptionStates` reports each
  watched pattern. SwiftUI models `ObservedSyncStatus` and
  `ObservableSyncStatus`.
- A write past `maxPendingWrites` throws `RecachedError.outboxFull` and
  changes nothing; until now the oldest queued write was dropped.
  `RecachedConfig(evictOldestWhenFull: true)` keeps the old behaviour.
  `RecachedError` gains `.outboxFull` and `.writeIdsExhausted`: an exhaustive
  `switch` over it needs the new cases.
- A write that throws `.storage` now changes nothing: the core rolls it back
  instead of keeping it in memory.
- `RefusedWrite.unreconciled` names the refused keys no watched pattern covers.

## [0.1.0] (2026-10-11)

- First release: `Recached.open(at:)` / `open(named:)`, local reads, durable
  queued writes, `watch`, `AsyncStream` observers per key and per pattern,
  `connectionState` and `pendingWrites` with streams, and the SwiftUI models
  `ObservedKey` (Observation) and `ObservableKey` (`ObservableObject`).
- `refusedWrites()`: writes the server refused for good. A write refused for a
  reason that can clear, such as a sync token not yet accepted, stays queued
  and is retried after a reconnect.
- Watched keys keep the server's expiry, so an expiring key read offline
  expires on time.
- `URLSessionWebSocketTask` transport with backoff and pings, reconnecting at
  once when a network becomes available or an iOS app returns to the
  foreground.
