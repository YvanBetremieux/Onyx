#!/usr/bin/env bash
set -euo pipefail

CONF="release"
APP_NAME="Onyx"
BUNDLE_ID="com.yvanbetremieux.onyx"
CERT_NAME="Onyx Local"
DIST_DIR="dist"
APP="$DIST_DIR/$APP_NAME.app"

# Avec le SDK macOS 27, `@State` & co. sont des macros dont le plugin
# (SwiftUIMacros) n'est livré qu'avec Xcode : les Command Line Tools seules
# échouent sur « plugin for module 'SwiftUIMacros' not found ». Sans Xcode, on
# retombe sur le SDK 26.x le plus récent, où ce sont encore des property wrappers.
if [ -z "${SDKROOT:-}" ] && [[ "$(xcode-select -p)" == */CommandLineTools ]]; then
    SDK26=$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.*.sdk 2>/dev/null | sort -V | tail -1)
    if [ -n "$SDK26" ]; then
        export SDKROOT="$SDK26"
        echo "→ pas d'Xcode : build avec $SDKROOT"
    fi
fi

echo "→ swift build -c $CONF"
swift build -c "$CONF" --arch arm64
# Le chemin des produits dépend du build system (.build/arm64-apple-macosx/release
# historiquement, .build/out/Products/Release avec swift-build) : on le demande.
BUILD_DIR=$(swift build -c "$CONF" --arch arm64 --show-bin-path)

# ── Bundle skeleton ────────────────────────────────────────────────────────────
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Frameworks"
mkdir -p "$APP/Contents/Resources"

# ── Main binary ────────────────────────────────────────────────────────────────
cp "$BUILD_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
# Ensure dyld can find frameworks in Contents/Frameworks at runtime.
install_name_tool -add_rpath '@loader_path/../Frameworks' "$APP/Contents/MacOS/$APP_NAME" 2>/dev/null || true

# ── Dylibs ────────────────────────────────────────────────────────────────────
# sherpa-onnx est lié via @rpath depuis Vendor/ (rpath absolu, dev only) : on
# l'embarque pour que l'app le trouve via @loader_path/../Frameworks.
for lib in "$BUILD_DIR"/*.dylib Vendor/sherpa-onnx/lib/*.dylib; do
    [ -f "$lib" ] || continue
    cp "$lib" "$APP/Contents/Frameworks/"
done

# ── Sparkle.framework ─────────────────────────────────────────────────────────
# SwiftPM copies the framework into the arch-specific build dir; prefer that.
SPARKLE_FW="$BUILD_DIR/Sparkle.framework"
if [ ! -d "$SPARKLE_FW" ]; then
    # Fallback: xcframework slice from .build/artifacts
    SPARKLE_FW=$(find .build/artifacts -name "Sparkle.framework" -type d 2>/dev/null | head -1)
fi
if [ -d "$SPARKLE_FW" ]; then
    cp -R "$SPARKLE_FW" "$APP/Contents/Frameworks/"
else
    echo "WARNING: Sparkle.framework not found – app may crash at runtime on other machines"
fi

# ── Plists & resources ────────────────────────────────────────────────────────
cp Resources/Info.plist        "$APP/Contents/Info.plist"

# Version injectée par la CI (sinon : valeurs de Resources/Info.plist).
[ -z "${ONYX_VERSION:-}" ] || /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $ONYX_VERSION" "$APP/Contents/Info.plist"
[ -z "${ONYX_BUILD:-}" ]   || /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $ONYX_BUILD" "$APP/Contents/Info.plist"

# Paquets de ressources SwiftPM : l'accesseur Bundle.module les cherche dans
# Bundle.main.resourceURL. Sans eux, l'app ne marche que sur la machine de build.
for bundle in "$BUILD_DIR"/*.bundle; do
    [ -d "$bundle" ] || continue
    cp -R "$bundle" "$APP/Contents/Resources/"
done

# Copy any icon / asset files from Resources (skip .plist and .entitlements)
for res in Resources/*; do
    base=$(basename "$res")
    case "$base" in
        Info.plist|*.entitlements) continue ;;
    esac
    cp -R "$res" "$APP/Contents/Resources/"
done

# ── Inside-out codesigning ────────────────────────────────────────────────────
# Sign nested content first (dylibs, then frameworks), then the app bundle.
# --deep is deliberately omitted (deprecated and broken for nested code).
echo "→ codesign with '$CERT_NAME' (inside-out)"

# 1. Dylibs
for lib in "$APP/Contents/Frameworks/"*.dylib; do
    [ -f "$lib" ] || continue
    codesign --force --sign "$CERT_NAME" --options runtime "$lib"
done

# 2. Frameworks (sign the framework bundle, not just the binary)
for fw in "$APP/Contents/Frameworks/"*.framework; do
    [ -d "$fw" ] || continue
    codesign --force --sign "$CERT_NAME" --options runtime "$fw"
done

# 3. App bundle (must be signed last)
codesign --force --sign "$CERT_NAME" --options runtime \
    --entitlements Resources/Onyx.entitlements \
    "$APP"

# ── Verify ────────────────────────────────────────────────────────────────────
echo "→ verify"
codesign --verify --verbose=2 "$APP"
spctl --assess --type execute --verbose=4 "$APP" || true

echo "Built $APP"
