#!/bin/bash
# Builds the feature-GIF generator against the app's own sources and runs it.
# Usage: Scripts/demo/make-gifs.sh [out-dir] [scene]   (default: docs/assets, every scene)
# A scene is an output name without extension, e.g. hand-a-file.
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="${1:-docs/assets}"
BIN="$(mktemp -d)/feature-gifs"
mkdir -p "$OUT"
swiftc -target arm64-apple-macos12.0 \
  $(find Sources/AgentBar -name "*.swift" ! -name "main.swift") \
  Scripts/demo/feature-gifs.swift -framework AVFoundation -o "$BIN"
"$BIN" "$OUT" ${2:+"$2"}
# AVAssetWriter's network-optimise pass leaves its scratch copy beside the MP4
# (`agentbar-tour.mp4.sb-…`); it is not an output and must not reach the repo.
find "$OUT" -maxdepth 1 -name '*.mp4.sb-*' -delete
