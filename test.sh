#!/bin/bash
# Run the test suite.
#
# Compiles the core sources together with the tests into one binary. No XCTest,
# so this runs on a machine with only the Command Line Tools installed — the
# same machines ./build.sh targets.
set -e
cd "$(dirname "$0")"

DEPLOYMENT_TARGET="12.0"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

echo "Compiling tests…"
swiftc -O Sources/Core/*.swift Tests/*.swift -o "$OUT/tests" \
    -target "$(uname -m)-apple-macosx${DEPLOYMENT_TARGET}" \
    -framework Foundation

FIXTURES_DIR="$(pwd)/Tests/Fixtures" "$OUT/tests"
