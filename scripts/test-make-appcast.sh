#!/usr/bin/env bash
# Test de make-appcast.sh avec une clé ed25519 jetable (hors trousseau).
set -euo pipefail
cd "$(dirname "$0")/.."
BIN=.build/artifacts/sparkle/Sparkle/bin
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
# Une clé privée ed25519 (format Sparkle) = 32 octets arbitraires en base64.
KEY=$(openssl rand -base64 32)
mkdir "$T/dir with space"; echo hello > "$T/dir with space/f"
ditto -c -k --keepParent "$T/dir with space/f" "$T/dir with space/Onyx-0.2.7.zip"

SPARKLE_ED_PRIVATE_KEY="$KEY" scripts/make-appcast.sh "$T/dir with space/Onyx-0.2.7.zip" \
    0.2.7 7 "https://example.com/dl?a=1&b=2" "https://example.com/notes" "$T/appcast.xml"
xmllint --noout "$T/appcast.xml"
grep -q 'sparkle:version="7"' "$T/appcast.xml"
grep -q 'sparkle:shortVersionString="0.2.7"' "$T/appcast.xml"
grep -q 'dl?a=1&amp;b=2' "$T/appcast.xml"
SIG=$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' "$T/appcast.xml")
echo "$KEY" | "$BIN/sign_update" --ed-key-file - --verify "$T/dir with space/Onyx-0.2.7.zip" "$SIG"

# Clé invalide → échec, pas de fichier écrit.
if SPARKLE_ED_PRIVATE_KEY="nope" scripts/make-appcast.sh "$T/dir with space/Onyx-0.2.7.zip" \
    0.2.7 7 u n "$T/bad.xml" 2>/dev/null; then echo "FAIL: clé invalide acceptée"; exit 1; fi
[ ! -e "$T/bad.xml" ] || { echo "FAIL: appcast partiel écrit"; exit 1; }
echo "test-make-appcast: OK"
