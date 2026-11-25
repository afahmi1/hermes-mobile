#!/bin/bash
# Render chat message views to PNGs inside a booted simulator, for visual review with no taps.
# Usage: Tests/render-snapshots.sh <booted-simulator-udid> [output-dir]
set -euo pipefail
cd "$(dirname "$0")/.."
sim="${1:?pass a booted simulator UDID}"
dest="${2:-build/snapshots}"
mkdir -p "$dest"
dest="$(cd "$dest" && pwd)"
work=$(mktemp -d "${TMPDIR:-/tmp}/hermes-render.XXXXXX")
trap 'rm -rf "$work"' EXIT
sources=()
while IFS= read -r file; do sources+=("$file"); done < <(find App/Sources -name '*.swift' ! -name 'HermesMobileApp.swift' | sort)
# The app entry point holds shared views too; compile it without its @main so the renderer can be the entry.
sed 's/^@main$//' App/Sources/HermesMobileApp.swift > "$work/HermesMobileApp.swift"
sources+=("$work/HermesMobileApp.swift")
xcrun -sdk iphonesimulator swiftc -parse-as-library -target arm64-apple-ios17.0-simulator \
  "${sources[@]}" Tests/RenderSnapshots.swift -o "$work/RenderSnapshots"
xcrun simctl spawn "$sim" "$work/RenderSnapshots" "$dest"
echo "Snapshots in $dest"
