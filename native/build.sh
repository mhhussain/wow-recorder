#!/bin/bash
# Prepare the native binaries the app ships in binaries/ (extraResources):
#   - wcr-capture: the ScreenCaptureKit recording helper (built from source)
#   - ffmpeg: arm64 build from ffmpeg-static, used for cutting (D-005)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

bash "$ROOT/native/wcr-capture/build.sh"

FFMPEG_SRC="$ROOT/node_modules/ffmpeg-static/ffmpeg"

if [ ! -x "$FFMPEG_SRC" ]; then
  echo "Missing $FFMPEG_SRC: run npm ci (ffmpeg-static downloads it on install)" >&2
  exit 1
fi

cp "$FFMPEG_SRC" "$ROOT/binaries/ffmpeg"
chmod +x "$ROOT/binaries/ffmpeg"
codesign --force --sign - "$ROOT/binaries/ffmpeg"
echo "Copied ffmpeg to $ROOT/binaries/ffmpeg"
