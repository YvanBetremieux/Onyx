#!/usr/bin/env bash
# Scan de secrets avec gitleaks (version et checksum épinglés, binaire mis en
# cache dans .build/tools). Utilisé par la CI et par le hook pre-commit.
# Usage : scan-secrets.sh            → tout l'historique git
#         scan-secrets.sh --staged   → seulement ce qui est indexé (pre-commit)
set -euo pipefail
VERSION=8.30.1
ROOT=$(cd "$(dirname "$0")/.." && pwd)
case "$(uname -s)_$(uname -m)" in
    Darwin_arm64) ARCH=darwin_arm64; SHA=b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5 ;;
    Linux_x86_64) ARCH=linux_x64;    SHA=551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb ;;
    *) echo "scan-secrets: plateforme non supportée ($(uname -s) $(uname -m))" >&2; exit 1 ;;
esac

BIN="$ROOT/.build/tools/gitleaks-$VERSION"
if [ ! -x "$BIN" ]; then
    mkdir -p "$(dirname "$BIN")"
    T=$(mktemp -d)
    curl -fsSL -o "$T/gitleaks.tgz" \
        "https://github.com/gitleaks/gitleaks/releases/download/v$VERSION/gitleaks_${VERSION}_$ARCH.tar.gz"
    if ! echo "$SHA  $T/gitleaks.tgz" | shasum -a 256 -c - >/dev/null; then
        echo "scan-secrets: checksum gitleaks invalide, abandon" >&2; rm -rf "$T"; exit 1
    fi
    tar -xzf "$T/gitleaks.tgz" -C "$T" gitleaks
    mv "$T/gitleaks" "$BIN"
    rm -rf "$T"
fi

if [ "${1:-}" = "--staged" ]; then
    exec "$BIN" git --pre-commit --staged --redact --no-banner -v "$ROOT"
else
    exec "$BIN" git --redact --no-banner -v "$ROOT"
fi
