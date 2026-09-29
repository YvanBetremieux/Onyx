#!/usr/bin/env bash
# Écrit un appcast Sparkle à une seule entrée pour <zip>, signé EdDSA.
# La clé privée vient de $SPARKLE_ED_PRIVATE_KEY (jamais en argument).
# Usage : make-appcast.sh <zip> <version> <build> <download-url> <notes-url> <out.xml>
set -euo pipefail
ZIP="$1"; VERSION="$2"; BUILD="$3"; URL="$4"; NOTES="$5"; OUT="$6"
: "${SPARKLE_ED_PRIVATE_KEY:?SPARKLE_ED_PRIVATE_KEY manquante}"
BIN="$(cd "$(dirname "$0")/.." && pwd)/.build/artifacts/sparkle/Sparkle/bin"

# sign_update imprime : sparkle:edSignature="…" length="…"
ATTRS=$(printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$BIN/sign_update" --ed-key-file - "$ZIP") || true
[[ "$ATTRS" == *'sparkle:edSignature="'* ]] || { echo "make-appcast: signature échouée" >&2; exit 1; }

xml() { local s="${1//&/&amp;}"; s="${s//</&lt;}"; s="${s//>/&gt;}"; printf '%s' "${s//\"/&quot;}"; }
TMP="$OUT.tmp.$$"
trap 'rm -f "$TMP"' EXIT
cat > "$TMP" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Onyx</title>
    <item>
      <title>Onyx $(xml "$VERSION")</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$(xml "$BUILD")</sparkle:version>
      <sparkle:shortVersionString>$(xml "$VERSION")</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>$(xml "$NOTES")</sparkle:releaseNotesLink>
      <enclosure url="$(xml "$URL")" sparkle:version="$(xml "$BUILD")" sparkle:shortVersionString="$(xml "$VERSION")" type="application/octet-stream" $ATTRS />
    </item>
  </channel>
</rss>
XML
mv "$TMP" "$OUT"
