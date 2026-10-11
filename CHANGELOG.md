# Changelog

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
