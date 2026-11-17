#!/bin/bash
# Compiles the press sensor with its checks and runs them. Needs only the Swift toolchain.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
swiftc -parse-as-library -O iOS/PressSensor.swift tools/PressSensorCheck.swift -o "$OUT/check"
"$OUT/check"
