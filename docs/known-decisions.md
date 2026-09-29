# Known Technical Decisions

This file documents intentional technical choices that may look like issues in code review
but are deliberate. Future reviewers and audit tools should not flag these.

## Sparkle Auto-Update Infrastructure

**Decision:** Updates are published by `.github/workflows/release.yml` on every push to `main`
as GitHub Releases. `SUFeedURL` points to `releases/latest/download/appcast.xml`; the appcast
(one item, the latest version) is generated and EdDSA-signed by `scripts/make-appcast.sh`.
CI signs the app with the same self-signed "Onyx Local" identity as local builds, imported
from repository secrets (`CERT_P12_BASE64`, `CERT_P12_PASSWORD`, `SPARKLE_ED_PRIVATE_KEY`).

**Why:** Same identity across builds keeps TCC permissions (mic, screen recording) valid
after an update and satisfies Sparkle's signing-identity check. No Developer ID /
notarization: Gatekeeper friction on first launch is accepted and documented in the README.
While the repo is private, update checks fail (assets require auth) — expected.

## Package.resolved tracked in git

**Decision:** `Package.resolved` is committed to the repository.

**Why:** Ensures reproducible builds — all developers and CI use the exact same dependency
versions. This is the recommended practice for app targets (as opposed to libraries).

## ModelManifest SHA-256 checksums are nil

**Decision:** SHA-256 checksums in `ModelManifest.swift` are `nil` for all models.

**Why:** The checksum verification infrastructure is in place (ModelDownloader will skip
verification with a warning when sha256 is nil). Checksums will be added once download
URLs are stable and verified. The missing checksum is logged as a warning, not silently
ignored.

## sherpa-onnx SHA-256 in fetch-sherpa.sh is FILL_ME_IN

**Decision:** `EXPECTED_SHA256` in `scripts/fetch-sherpa.sh` is set to `"FILL_ME_IN"`.

**Why:** The actual hash must be verified against the official sherpa-onnx GitHub release.
When the placeholder is detected, the script prints a warning with the command to obtain
the hash rather than silently skipping verification.

## SwiftPM unsafeFlags for rpath

**Decision:** `Package.swift` uses `unsafeFlags(["-Xlinker", "-rpath", ...])` for sherpa-onnx.

**Why:** SwiftPM does not have a first-class API for setting rpaths on dynamic library
dependencies. The `build-app.sh` script copies dylibs into `Contents/Frameworks/` and
sets the correct rpath for distribution; the unsafeFlags are only for local development.
