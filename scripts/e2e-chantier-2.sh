#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
echo "--- Building E2ETrigger ---"
swift build --product E2ETrigger -c release --arch arm64 2>&1 | tail -5
echo "--- Running E2ETrigger ---"
.build/arm64-apple-macosx/release/E2ETrigger "$@"
