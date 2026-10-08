#!/bin/bash
# Build the wcr-capture helper into binaries/wcr-capture (arm64, ad-hoc
# signed). Requires Xcode command line tools. Caches stay inside the repo.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/native/wcr-capture/Sources"
OUT="$ROOT/binaries/wcr-capture"
CACHE="$ROOT/.ci-cache/swift-module-cache"

mkdir -p "$(dirname "$OUT")" "$CACHE"

xcrun swiftc \
  -O \
  -swift-version 5 \
  -target arm64-apple-macos27.0 \
  -module-cache-path "$CACHE" \
  -o "$OUT" \
  "$SRC"/*.swift

codesign --force --sign - "$OUT"
echo "Built $OUT"
