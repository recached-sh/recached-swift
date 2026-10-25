# Recached for Swift

A local-first [Recached](https://github.com/recached-sh/recached) client for
iOS and macOS.

- **Local reads:** `get` reads device memory. It never waits on the network,
  and after a restart with no connection it returns saved data that has not expired.
- **Durable queued writes:** a write is saved with its place in the outbox
  before a successful `set` returns. Pending writes survive an app kill and replay with their original duplicate-suppression identities; see the limits below.
- **Reconnect recovery:** after a drop the client reconnects with backoff, or
  immediately when the network becomes available or an iOS app returns to the foreground. It replays queued
  writes and catches up on what changed meanwhile, deletions included.
- **Reactive updates:** `observe(key)` is an `AsyncStream` of the current local value and later changes, including server updates. Equal values are suppressed and slow consumers can skip intermediate values. A
  write to one key wakes only that key's observers. SwiftUI models are
  included.

Built on `recached-mobile`, the Rust core it shares with the Android SDK,
through [UniFFI](https://mozilla.github.io/uniffi-rs/).

> **Status: 0.1.0, preview.** Built on the native core of recached v0.4.0. The API may still change before 1.0.

## Install

In Xcode, **File → Add Package Dependencies…** with
`https://github.com/recached-sh/recached-swift`, or in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/recached-sh/recached-swift", from: "0.1.0")
],
targets: [
    .target(name: "App", dependencies: [
        .product(name: "Recached", package: "recached-swift")
    ])
]
```

The native core comes as a prebuilt XCFramework from the recached v0.4.0 release, so building needs no Rust. Supports iOS 15+ and macOS 12+. Linux is a contributor test path using the staged system library.

## Use

Open one instance and keep it for the life of the app:

```swift
import Foundation
import Recached

let cache = try Recached.open(
    named: "app",
    config: RecachedConfig(url: URL(string: "wss://cache.example.com")!, syncToken: token)
)
```

Choose what to keep in sync, then read, write and observe:

```swift
cache.watch("todo:*")                         // server state for these keys, kept live

try cache.set("todo:42:title", "Buy milk")
let todo = try cache.getString("todo:42:title")     // local: safe on the main actor

for await todos in cache.observeMatching("todo:*") {
    render(todos)                             // now, then after every change
}
```

In SwiftUI, `ObservedKey` (iOS 17+ / macOS 14+, Observation) or `ObservableKey`
(iOS 15+, `ObservableObject`) follows one key:

```swift
import SwiftUI

@available(iOS 17, macOS 14, *)
@MainActor
struct TitleView: View {
    @State private var title: ObservedKey
    init(cache: Recached) { _title = State(initialValue: ObservedKey(cache, "todo:42:title")) }
    var body: some View { Text(title.string ?? "") }
}
```

`watch` requests a server snapshot asynchronously. Until it arrives, reads can return a miss or saved data. Watches are not persisted; register them after every open. Observers and SwiftUI models listen to local changes and do not create server subscriptions.

The examples assume your app supplies a backend-minted `token` and a `render` function. A watch is not an authorization boundary: configure [sync scopes](https://recached.dev/server/sync-scopes) for per-user state.

Show sync state:

```swift
cache.syncStatus             // .disconnected, .connecting, .authenticating, .replaying,
                             // .hydrating, .ready, .degraded — plus the problem and lastSyncedAt
cache.syncStatuses()         // AsyncStream of it, starting with the current value
cache.subscriptionStates     // each watched pattern: .pending, .hydrating, .current, .failed
cache.pendingWrites          // writes the server has not acknowledged yet
cache.connectionState        // the socket alone: .offline, .connecting, .connected, .waiting
```

`.ready` means synchronized: the session is authenticated, every queued write
has been replayed and answered, and every pattern watched when the socket opened
has its snapshot. `ObservedSyncStatus` (Observation) and `ObservableSyncStatus`
(`ObservableObject`) put it in SwiftUI. A write past `maxPendingWrites` (10,000
by default) throws `RecachedError.outboxFull` and changes nothing; a write that
throws `.storage` changed nothing either. `pendingWriteCounts()` and
`connectionStates()` stream the other two.

A write the server refuses for good, such as one to a key the sync token makes
read-only, leaves the queue without reaching the server. Iterate
`refusedWrites()` to hear about it:

```swift
for await refused in cache.refusedWrites() {
    print("not saved: \(refused.keys): \(refused.reason)")
    // No watched pattern covers these, so nothing will correct them locally.
    refused.unreconciled.forEach(rereadOrMarkFailed)
}
```

A refusal that can clear, such as a sync token the server has not accepted yet,
keeps the write queued; it is retried on every reconnect until it goes through.

Other calls: `incr(_:by:)` (a counter that merges with other clients'
increments instead of overwriting them), `setJSON` / `mergeJSON` /
`getJSON`, `set(_:_:ttl:)`, `delete`, `getMatching`, `setSyncToken`,
`reconnectNow`. `close()` stops syncing; local reads and writes remain usable, and queued writes stay on disk for the next open.

`open(named:)` keeps the database in Application Support and **excludes it
from backups**. Restoring it onto another device would give the two one client
identity, and the server would drop one device's writes as duplicates of the
other's. If you choose a location with `open(at:)`, exclude it yourself.

## Delivery and storage limits

A connected state means the WebSocket is open, not that authentication, watch hydration, or pending writes have completed — `syncStatus` reports those. Local write results describe the local operation; the server can later refuse it.

- The outbox defaults to 10,000 writes. `maxPendingWrites` changes the cap; overflow drops the oldest queued write while keeping its local effect. The native API has no overflow event.
- Server duplicate suppression covers retries while the client's mark is retained. AOF recovery after the latest checkpoint can replay a write without its dedup mark; idle marks can also be swept after 24 hours when the map exceeds 10,000 clients. This is not an unconditional exactly-once guarantee.
- A permanent refusal emits a live event and removes the write from the queue. A permitted watched snapshot restores the server value; an unwatched key can keep the refused local value. Refusal events are not saved for replay.
- A storage error can leave a write applied in memory and eligible to sync without saving it. Handle errors instead of assuming rollback.
- SQLite uses WAL with `synchronous = NORMAL`. Committed data survives an app kill; an OS crash or power loss can lose recent commits.

Binary reads return `Data`; `getString` fails on invalid UTF-8, while text observers return `nil`. TTL reads use seconds (`-1` without expiry, `-2` when absent), and positive TTL writes round up to whole seconds. Reads mask expired values; offline expiry alone does not notify observers because there is no local expiry timer. The native wrappers expose strings, bytes, counters, and JSON operations; they do not expose individual collection commands or pub/sub.

Omitting the config URL keeps the cache local; writes still enter the outbox for a later open with a server URL. See [client support and limits](https://recached.dev/guide/client-support) for the shared protocol and adapter differences.

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

On macOS, `swift test` runs everything against the released XCFramework that
`Package.swift` pins. To work against an unreleased core, empty `engineURL` and
`engineChecksum` there: Apple builds then use the `engine/RecachedFFI.xcframework`
that `scripts/build-engine.sh` builds on a Mac. The live tests start the staged
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
