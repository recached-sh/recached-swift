#!/usr/bin/env bash
# Build and run a throwaway app that depends on this package the way the README
# tells users to — `.product(name: "Recached", package: "recached-swift")` — so
# a release tag never discovers a product, identity or public-API problem the
# package's own tests cannot see. Nothing is published.
#
# Linux: run scripts/build-engine.sh first; the app links engine/host like
# scripts/test-linux.sh does. macOS: uses whatever Package.swift resolves.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A path dependency's identity is its directory name, so link the checkout
# under the name users resolve it by.
ln -s "$ROOT" "$WORK/recached-swift"
mkdir -p "$WORK/app/Sources/App"

cat > "$WORK/app/Package.swift" <<'SWIFT'
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "App",
    platforms: [.iOS(.v15), .macOS(.v12)],
    dependencies: [.package(path: "../recached-swift")],
    targets: [
        .executableTarget(name: "App", dependencies: [.product(name: "Recached", package: "recached-swift")])
    ]
)
SWIFT

cat > "$WORK/app/Sources/App/main.swift" <<'SWIFT'
import Foundation
import Recached

let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
defer { try? FileManager.default.removeItem(at: dir) }

let cache = try Recached.open(at: dir.appendingPathComponent("app.db"))
try cache.set("todo:1", "Buy milk")
let text = try cache.getString("todo:1")  // not inside precondition: its condition cannot throw
precondition(text == "Buy milk", "read back what was written")
precondition(cache.pendingWrites == 1, "the write is queued for the server")

var updates = cache.observeString("todo:1").makeAsyncIterator()
let first = await updates.next()
precondition(first == "Buy milk", "observe starts with the current value")
try cache.set("todo:1", "Buy oat milk")
let second = await updates.next()
precondition(second == "Buy oat milk", "observe sees the change")

let reopened = try Recached.open(at: dir.appendingPathComponent("app.db"))
precondition(reopened.pendingWrites == 2, "both queued writes survive reopening")
print("OK: an app depending on recached-swift builds, links, writes, observes and reopens")
SWIFT

args=()
if [[ "$(uname -s)" != Darwin ]]; then
    HOST="$ROOT/engine/host"
    [[ -f "$HOST/librecached_mobile.so" ]] || { echo "error: run scripts/build-engine.sh first" >&2; exit 1; }
    args=(-Xlinker -L"$HOST" -Xlinker -rpath -Xlinker "$HOST")
fi
cd "$WORK/app"
swift run "${args[@]}" App
