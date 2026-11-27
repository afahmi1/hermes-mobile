#!/bin/bash
# Build and run every Swift suite. The suites are plain executables that link the app's model sources,
# so they need no Xcode test target. Usage: Tests/run-swift.sh [booted-simulator-udid]
# Without a simulator the media-import suite, which needs UIKit, is skipped and reported.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d "${TMPDIR:-/tmp}/hermes-swift-suites.XXXXXX")
trap 'rm -rf "$out"' EXIT
export CFFIXED_USER_HOME="$out/test-home"
mkdir -p "$CFFIXED_USER_HOME"
lib=(App/Sources/{API,AppModel,InboxCache,ChatModel,Management,ManagementAPI,Models,Projects,StatusModel,RecentModels,StreamRecovery,Workspaces,MediaStaging,ReplyNotifier,Changelog}.swift)
for source in Tests/*Tests.swift; do
  suite=$(basename "$source" Tests.swift)
  [[ "$suite" == MediaImport ]] && continue
  swiftc -parse-as-library "${lib[@]}" "$source" -o "$out/$suite"
  if [[ "$suite" == ComposerDraft ]]; then "$out/$suite" --write; fi
  "$out/$suite"
done
if [ -n "${1:-}" ]; then
  xcrun -sdk iphonesimulator swiftc -parse-as-library -target arm64-apple-ios17.0-simulator \
    "${lib[@]}" App/Sources/Views/Thermocline.swift App/Sources/Views/DesignSystem.swift \
    App/Sources/Views/ChatMedia.swift Tests/MediaImportTests.swift -o "$out/MediaImport"
  env -u CFFIXED_USER_HOME xcrun simctl spawn "$1" "$out/MediaImport"
else
  echo "SKIPPED MediaImport: pass a booted simulator UDID to run it"
fi
echo "All Swift suites passed"
