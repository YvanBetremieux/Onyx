#!/usr/bin/env bash
set -euo pipefail
NAME="Onyx Local"
# Pas de `-v` : un cert auto-signé n'est jamais « valid » (CSSMERR_TP_NOT_TRUSTED),
# donc `-v` ne le listerait jamais et chaque relance réimporterait un doublon.
if security find-identity -p codesigning login.keychain-db | grep -q "\"$NAME\""; then
  echo "Cert '$NAME' already exists in login keychain."
  exit 0
fi
TMPDIR_CERT=$(mktemp -d)
trap 'rm -rf "${TMPDIR_CERT}"' EXIT

cat > "${TMPDIR_CERT}/onyx-cert.conf" <<EOF
[req]
distinguished_name = req_dn
prompt = no
x509_extensions = v3_codesign
[req_dn]
CN = $NAME
[v3_codesign]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
openssl req -new -x509 -days 3650 -nodes \
    -config "${TMPDIR_CERT}/onyx-cert.conf" \
    -keyout "${TMPDIR_CERT}/onyx.key" -out "${TMPDIR_CERT}/onyx.crt"
# `-legacy` (ou, à défaut, les algos SHA1/3DES) est obligatoire : OpenSSL 3
# chiffre le PKCS#12 en AES-256 avec un MAC SHA-256, que `security import`
# d'Apple ne sait pas vérifier — il échoue sur « MAC verification failed
# during PKCS12 import (wrong password?) », message trompeur puisque le mot de
# passe est correct.
if ! openssl pkcs12 -export -legacy -out "${TMPDIR_CERT}/onyx.p12" \
        -inkey "${TMPDIR_CERT}/onyx.key" -in "${TMPDIR_CERT}/onyx.crt" \
        -passout pass:onyx 2>/dev/null; then
    openssl pkcs12 -export -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES \
        -macalg sha1 -out "${TMPDIR_CERT}/onyx.p12" \
        -inkey "${TMPDIR_CERT}/onyx.key" -in "${TMPDIR_CERT}/onyx.crt" \
        -passout pass:onyx
fi
security import "${TMPDIR_CERT}/onyx.p12" -k login.keychain-db -P onyx -T /usr/bin/codesign
# Sans `-k`, `security` demande le mot de passe du trousseau de session (celui
# de la session macOS) ; `-k ""` ne marche que si ce mot de passe est vide.
echo "Mot de passe du trousseau de session (= mot de passe macOS) pour autoriser codesign :"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s login.keychain-db >/dev/null
# Temp files cleaned up automatically by the trap above.
echo "Cert '$NAME' installed. BACK IT UP: export to .p12 via Keychain Access."
