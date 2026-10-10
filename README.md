# Recached for Swift

A local-first [Recached](https://github.com/recached-sh/recached) client for
iOS and macOS.

- **Local reads:** `get` reads device memory. It never waits on the network,
  and after a restart with no connection it returns the last-synced data.
- **Durable queued writes:** a write is saved with its place in the outbox
  before `set` returns. It reaches the server exactly once, even if the app is
  killed before the server replied.
- **Reconnect recovery:** after a drop the client reconnects with backoff, or
  immediately when the network or the app comes back. It replays queued
  writes and catches up on what changed meanwhile, deletions included.
- **Reactive updates:** `observe(key)` is an `AsyncStream` that yields when
  that key changes, whether on this device, on another, or on the server. A
  write to one key wakes only that key's observers. SwiftUI models are
  included.

Built on `recached-mobile`, the Rust core it shares with the Android SDK,
through [UniFFI](https://mozilla.github.io/uniffi-rs/).

> **Status: 0.1.0, unreleased.** Builds against an unreleased branch of
> recached until that core ships in a release. Until then, Apple platforms
> need the XCFramework built locally (see Development).

## Install

```swift
dependencies: [
    .package(url: "https://github.com/recached-sh/recached-swift", from: "0.1.0")
],
targets: [
    .target(name: "App", dependencies: [.product(name: "Recached", package: "recached-swift")])
]
```

iOS 15+ and macOS 12+.

## Use

Open one instance and keep it for the life of the app:

```swift
let cache = try Recached.open(
    named: "app",
    config: RecachedConfig(url: URL(string: "wss://cache.example.com")!, syncToken: token)
)
```

Choose what to keep in sync, then read, write and observe:

```swift
cache.watch("todo:*")                         // server state for these keys, kept live

try cache.set("todo:42", #"{"title":"Buy milk"}"#)
let todo = try cache.getString("todo:42")     // local: safe on the main actor

for await todos in cache.observeMatching("todo:*") {
    render(todos)                             // now, then after every change
}
```

In SwiftUI, `ObservedKey` (iOS 17+, Observation) or `ObservableKey`
(iOS 15+, `ObservableObject`) follows one key:

```swift
struct TitleView: View {
    @State private var title: ObservedKey
    init(cache: Recached) { _title = State(initialValue: ObservedKey(cache, "todo:42:title")) }
    var body: some View { Text(title.string ?? "") }
}
```

Show sync state:

```swift
cache.connectionState        // .offline, .connecting, .connected, .waiting
cache.pendingWrites          // writes the server has not acknowledged yet
cache.connectionStates()     // AsyncStream of both, starting with the current value
cache.pendingWriteCounts()
```

A write the server refuses for good, such as one to a key the sync token makes
read-only, leaves the queue without reaching the server. Iterate
`refusedWrites()` to hear about it:

```swift
for await refused in cache.refusedWrites() {
    print("not saved: \(refused.keys): \(refused.reason)")
}
```

A refusal that can clear, such as a sync token the server has not accepted yet,
keeps the write queued; it is retried on every reconnect until it goes through.

Other calls: `incr(_:by:)` (a counter that merges with other clients'
increments instead of overwriting them), `setJSON` / `mergeJSON` /
`getJSON`, `set(_:_:ttl:)`, `delete`, `getMatching`, `setSyncToken`,
`reconnectNow`. `close()` stops syncing; queued writes stay on disk for the
next open.

`open(named:)` keeps the database in Application Support and **excludes it
from backups**. Restoring it onto another device would give the two one client
identity, and the server would drop one device's writes as duplicates of the
other's. If you choose a location with `open(at:)`, exclude it yourself.

## How it fits together

| Module | Contents |
|---|---|
| `Recached` | The API above, the `URLSessionWebSocketTask` transport, the network and foreground hooks |
| `RecachedCore` | UniFFI-generated Swift, committed so SwiftPM can build it. Not an API |
| `RecachedFFI` | The core as `RecachedFFI.xcframework` (Apple), or a system library (Linux) |

The core does no networking. This package owns the socket and hands the core
each frame. The core decides what to send, saves state to SQLite, and reports
which keys changed.

## Development

The core is staged into `engine/` (gitignored) from a recached checkout. On
Linux:

```sh
scripts/build-engine.sh ../recached     # host library, server, bindings (+ XCFramework on macOS)
scripts/test-linux.sh                   # all tests, including live tests against a real server
scripts/check-package.sh                # an app depending on this package builds and runs
```

On Linux, `URLSessionWebSocketTask` needs a libcurl built with WebSocket
support, which Ubuntu 24.04's (8.5) is not. The live tests then skip with that
reason; they always run on macOS CI.

On macOS, `scripts/build-engine.sh` also builds `engine/RecachedFFI.xcframework`,
and `swift test` runs everything. The live tests start the staged
`recached-server` themselves, on free loopback ports. They skip on the iOS
simulator, which cannot start processes.

`build-engine.sh` regenerates `Sources/RecachedCore/RecachedCore.swift`. Commit
the result whenever the core changes; CI fails if it differs from what
`engine.properties`' ref generates. To pin a release, set `engineURL` and
`engineChecksum` in `Package.swift`, and commit that release's generated file.

Style: `swift format lint --strict --recursive Sources/Recached Tests Package.swift`.

## Demo

`Demo/` is a small SwiftUI checklist on this package: items in creation order,
tick and swipe to delete, the connection state and unsynced writes in the
toolbar. Generate its project with [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
scripts/build-engine.sh ../recached         # on a Mac: the XCFramework and server
(cd engine/host && ./recached-server &)     # ws://127.0.0.1:6380
cd Demo && xcodegen && open RecachedDemo.xcodeproj
```

The simulator shares the Mac's network, so the default server URL works
as-is; launch with `-server ws://…` to use another. Its UI tests check an item
added offline survives a relaunch still queued, and that it syncs when a server
is running.

## License

Apache-2.0.
