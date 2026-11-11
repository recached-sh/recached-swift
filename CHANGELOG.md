# Changelog

## [0.1.2] (2026-11-11)

Built on the native core of recached v0.5.1. No API changes.

- With `evictOldestWhenFull`, a write that throws `RecachedError.storage` no
  longer loses the older queued write it evicted to make room; that write
  stays queued and is sent.
- With `evictOldestWhenFull`, the late reply to an evicted write that had
  already been sent no longer appears in `refusedWrites()` or drops the
  connection.
- A token passed to `setSyncToken` and accepted by the server now clears an
  earlier `scopeRefused` problem; `syncStatus` stayed `.degraded` until the
  next reconnect.
- `syncStatus` no longer misses a phase change when saving an incoming change
  fails.
- The bundled SQLite is 3.54.1, fixing RUSTSEC-2026-0459 / CVE-2026-119375
  (uninitialized memory returned when a database is opened with a `-wal` of a
  different page size; local only).
- `RecachedCore.swift` is regenerated from the v0.5.1 core; only the
  documentation of `RecachedError.storage` changes.
- Pair it with a recached 0.5.1 server for the server-side fixes; see the
  [recached 0.5.1 changelog](https://github.com/recached-sh/recached/blob/main/CHANGELOG.md).

## [0.1.1] (2026-10-25)

Built on the native core of recached v0.5.0.

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
