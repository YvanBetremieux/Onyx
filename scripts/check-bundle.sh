#!/usr/bin/env bash
# Vérifie qu'un Onyx.app est distribuable : version, ressources SwiftPM,
# dylibs embarquées, signature. Usage : check-bundle.sh <app> [<version> <build>]
set -euo pipefail
APP="$1"; WANT_VERSION="${2:-}"; WANT_BUILD="${3:-}"
PLIST="$APP/Contents/Info.plist"
fail() { echo "check-bundle: $*" >&2; exit 1; }

got_v=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")
got_b=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST")
[ -z "$WANT_VERSION" ] || [ "$got_v" = "$WANT_VERSION" ] || fail "version $got_v ≠ $WANT_VERSION"
[ -z "$WANT_BUILD" ]   || [ "$got_b" = "$WANT_BUILD" ]   || fail "build $got_b ≠ $WANT_BUILD"

for b in GRDB_GRDB swift-transformers_Hub swift-crypto_Crypto; do
    [ -d "$APP/Contents/Resources/$b.bundle" ] || fail "ressource manquante : $b.bundle"
done
for lib in libsherpa-onnx-c-api.dylib libonnxruntime.dylib; do
    [ -f "$APP/Contents/Frameworks/$lib" ] || fail "dylib manquante : $lib"
done
[ -d "$APP/Contents/Frameworks/Sparkle.framework" ] || fail "Sparkle.framework manquant"
codesign --verify --strict "$APP" || fail "signature invalide"
echo "check-bundle: OK ($got_v / $got_b)"
