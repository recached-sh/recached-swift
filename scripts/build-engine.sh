#!/usr/bin/env bash
# Build recached-mobile from a local checkout of recached-sh/recached and stage
# it where the package looks for it.
#
#   engine/include/RecachedFFI.h                 C header (the Linux system library)
#   engine/host/librecached_mobile.{so,dylib}    host library the tests link
#   engine/host/recached-server                  server the live tests run against
#   engine/RecachedFFI.xcframework               macOS only: what Package.swift links
#                                                on Apple platforms until it pins a release
#   Sources/RecachedCore/RecachedCore.swift      UniFFI-generated Swift (committed: SwiftPM
#                                                users compile it, so it must match the core)
#   engine/SOURCE                                where the files came from
#
# Usage:
#   scripts/build-engine.sh [path-to-recached-checkout]    default: ../recached
#   HOST_ONLY=1 scripts/build-engine.sh ...                 macOS: skip the XCFramework
#
# Requires cargo; on macOS, Xcode for the XCFramework.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$(cd "${1:-${RECACHED_SRC:-$ROOT/../recached}}" && pwd)"
OUT="$ROOT/engine"

[[ -f "$SRC/recached-mobile/Cargo.toml" ]] || {
    echo "error: $SRC is not a recached checkout with recached-mobile/" >&2
    exit 1
}

TARGET_DIR="$(cargo metadata --manifest-path "$SRC/Cargo.toml" --no-deps --format-version 1 |
    python3 -c 'import sys, json; print(json.load(sys.stdin)["target_directory"])')"
case "$(uname -s)" in
    Darwin) HOST_LIB=librecached_mobile.dylib ;;
    *)      HOST_LIB=librecached_mobile.so ;;
esac

rm -rf "$OUT"
mkdir -p "$OUT/include" "$OUT/host"
GEN="$(mktemp -d)"
trap 'rm -rf "$GEN"' EXIT

echo "Building host library and server"
(cd "$SRC" && cargo build --locked -p recached-mobile --lib && cargo build --locked -p recached --bin recached-server)
cp "$TARGET_DIR/debug/$HOST_LIB" "$TARGET_DIR/debug/recached-server" "$OUT/host/"

(cd "$SRC" && cargo run --locked -q -p recached-mobile --features cli --bin uniffi-bindgen -- \
    generate --library "$TARGET_DIR/debug/$HOST_LIB" --language swift --no-format --out-dir "$GEN")
cp "$GEN/RecachedFFI.h" "$OUT/include/"
cp "$GEN/RecachedCore.swift" "$ROOT/Sources/RecachedCore/RecachedCore.swift"

if [[ "$(uname -s)" == Darwin && "${HOST_ONLY:-0}" != 1 ]]; then
    echo "Building RecachedFFI.xcframework"
    "$SRC/recached-mobile/scripts/build-apple.sh" "$GEN/apple-out"
    cp -R "$GEN/apple-out/apple/RecachedFFI.xcframework" "$OUT/"
fi

echo "local $(git -C "$SRC" describe --always --dirty) ($SRC)" > "$OUT/SOURCE"
echo "Staged engine from $(cat "$OUT/SOURCE") in $OUT"
