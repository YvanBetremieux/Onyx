#!/usr/bin/env bash
set -euo pipefail

if ! command -v generate_appcast &>/dev/null; then
    echo "ERROR: generate_appcast not found. Install Sparkle tools: https://sparkle-project.org"
    exit 1
fi
DIST_DIR="${1:-dist/releases}"
mkdir -p "$DIST_DIR"
generate_appcast "$DIST_DIR"
echo "Appcast at $DIST_DIR/appcast.xml"
echo "Host the whole $DIST_DIR/ folder somewhere reachable (e.g. GitHub Releases + a static appcast.xml URL)."
