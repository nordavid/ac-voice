#!/bin/sh
# Regenerates test/fixtures/ipc-v1.json from the Swift codec (Sources/ACVoiceCore/IPC.swift).
# Run it after any change to IPC.swift, then `npm test` shows where the TypeScript codec drifted.
set -eu
cd "$(dirname "$0")/.."
out=.cache/ipc-fixtures
mkdir -p "$out"
xcrun swiftc -swift-version 6 -O -module-cache-path "$out/mc" \
	../Sources/ACVoiceCore/IPC.swift scripts/ipc-fixtures/main.swift -o "$out/gen"
"$out/gen" > test/fixtures/ipc-v1.json
echo "wrote test/fixtures/ipc-v1.json"
