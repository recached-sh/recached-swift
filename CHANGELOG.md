# Changelog

## [0.1.0] (unreleased)

- First release: `Recached.open(at:)` / `open(named:)`, local reads, durable
  queued writes, `watch`, `AsyncStream` observers per key and per pattern,
  `connectionState` and `pendingWrites` with streams, and the SwiftUI models
  `ObservedKey` (Observation) and `ObservableKey` (`ObservableObject`).
- `URLSessionWebSocketTask` transport with backoff and pings, reconnecting at
  once when a network becomes available or an iOS app returns to the
  foreground.
