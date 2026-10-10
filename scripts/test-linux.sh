#!/usr/bin/env bash
# Run the test suite on Linux against the core staged by scripts/build-engine.sh.
# Extra arguments go to `swift test`, e.g. --filter LiveTests.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="$ROOT/engine/host"
[[ -f "$HOST/librecached_mobile.so" ]] || { echo "error: run scripts/build-engine.sh first" >&2; exit 1; }
cd "$ROOT"
exec swift test -Xlinker -L"$HOST" -Xlinker -rpath -Xlinker "$HOST" "$@"
