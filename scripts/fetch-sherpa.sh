#!/usr/bin/env bash
# Downloads sherpa-onnx macOS shared libraries + headers into Vendor/sherpa-onnx.
# Idempotent: re-running with the artifacts already in place is a no-op.
set -euo pipefail

VERSION="v1.13.4"
ASSET="sherpa-onnx-${VERSION}-osx-universal2-shared.tar.bz2"
URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/${VERSION}/${ASSET}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
VENDOR_DIR="${ROOT_DIR}/Vendor/sherpa-onnx"
INCLUDE_TARGET="${ROOT_DIR}/Sources/CSherpaOnnx/include"

if [[ -f "${VENDOR_DIR}/lib/libsherpa-onnx-c-api.dylib" ]] \
   && [[ -f "${INCLUDE_TARGET}/c-api.h" ]]; then
  echo "sherpa-onnx already present at ${VENDOR_DIR} (skipping download)."
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

echo "Downloading ${ASSET}..."
curl -fL -o "${TMP}/${ASSET}" "${URL}"

# SHA-256 verification.
# To obtain the expected hash, run:
#   shasum -a 256 <downloaded-tarball>
# Update EXPECTED_SHA256 below whenever VERSION changes.
EXPECTED_SHA256="FILL_ME_IN"
ACTUAL_SHA256=$(shasum -a 256 "${TMP}/${ASSET}" | awk '{print $1}')
if [ "${EXPECTED_SHA256}" = "FILL_ME_IN" ]; then
  echo "WARNING: EXPECTED_SHA256 is not set. Skipping integrity check."
  echo "         Run: shasum -a 256 ${TMP}/${ASSET}"
  echo "         Then set EXPECTED_SHA256 in $(basename "$0") to that value."
elif [ "${ACTUAL_SHA256}" != "${EXPECTED_SHA256}" ]; then
  echo "ERROR: SHA-256 mismatch for ${ASSET}"
  echo "Expected: ${EXPECTED_SHA256}"
  echo "Actual:   ${ACTUAL_SHA256}"
  exit 1
fi

echo "Extracting..."
tar -xjf "${TMP}/${ASSET}" -C "${TMP}"

SRC="${TMP}/sherpa-onnx-${VERSION}-osx-universal2-shared"

mkdir -p "${VENDOR_DIR}/lib" "${VENDOR_DIR}/include" "${INCLUDE_TARGET}"

# Copy only the dylibs we need at runtime (drop bin/ CLI tools).
cp "${SRC}/lib/libsherpa-onnx-c-api.dylib" "${VENDOR_DIR}/lib/"
cp "${SRC}/lib/libonnxruntime.dylib" "${VENDOR_DIR}/lib/"
cp "${SRC}/lib/libonnxruntime."*".dylib" "${VENDOR_DIR}/lib/" 2>/dev/null || true

# Public headers
cp -R "${SRC}/include/sherpa-onnx" "${VENDOR_DIR}/include/"

# Mirror c-api.h into the SwiftPM C target's public headers.
cp "${SRC}/include/sherpa-onnx/c-api/c-api.h" "${INCLUDE_TARGET}/c-api.h"

# Re-sign the dylibs ad-hoc. The upstream signature is often flagged as
# invalid on recent macOS versions (SIGKILL "Code Signature Invalid" on load).
# Also strip the com.apple.quarantine xattr that curl adds for downloaded files.
for f in "${VENDOR_DIR}/lib/"*.dylib; do
  xattr -d com.apple.quarantine "${f}" 2>/dev/null || true
  codesign --force --sign - "${f}" >/dev/null
done

echo "sherpa-onnx ${VERSION} installed at ${VENDOR_DIR}."
