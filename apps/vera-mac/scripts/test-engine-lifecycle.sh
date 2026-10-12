#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
scratch=$(mktemp -d "${TMPDIR:-/tmp}/vera-engine-test.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
swiftc -swift-version 6 -module-cache-path "$scratch/modules" -parse-as-library \
  Sources/Vera/EngineLifecycle.swift Sources/Vera/EngineManager.swift \
  Tests/EngineLifecycleFixtures.swift Tests/EngineLifecycleTests.swift -o "$scratch/tests"
"$scratch/tests"
