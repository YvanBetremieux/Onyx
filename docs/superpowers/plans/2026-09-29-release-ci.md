# Release CI + mises à jour Sparkle — plan d'implémentation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Objectif :** chaque push sur `main` build, signe et publie Onyx en release GitHub, avec un
appcast Sparkle signé EdDSA.

**Architecture :** trois scripts shell testables en local (`build-app.sh` modifié,
`check-bundle.sh` et `make-appcast.sh` nouveaux), orchestrés par un seul workflow GitHub
Actions sur runner macOS. La CI signe avec le même certificat « Onyx Local » qu'en local,
importé depuis des secrets.

**Stack :** bash, SwiftPM, outils CLI de Sparkle 2 (`sign_update`, `generate_keys`), `gh`,
GitHub Actions.

**Spec :** `docs/superpowers/specs/2026-09-29-release-ci-design.md`

## Contraintes globales

- Nom de l'identité de signature : `Onyx Local` ; bundle id : `com.yvanbetremieux.onyx`.
- Flux : `https://github.com/YvanBetremieux/Onyx/releases/latest/download/appcast.xml`.
- Version = `<major.minor de Resources/Info.plist>.<github.run_number>` ; build = `github.run_number`.
- Tag de release : `v<version>` ; nom de l'asset : `Onyx-<version>.zip` plus `appcast.xml`.
- `minimumSystemVersion` : `13.0`.
- Outils Sparkle : `.build/artifacts/sparkle/Sparkle/bin/`.
- Déclencheur : push sur `main` hors `**/*.md` et `docs/**`, plus `workflow_dispatch`.
- Les secrets ne sont jamais écrits dans le repo ; les exports temporaires restent dans le
  scratchpad et sont supprimés aussitôt envoyés.

## Points de vigilance

1. Build local sans `ONYX_VERSION`/`ONYX_BUILD` → la version du plist reste inchangée (test de
   la tâche 1).
2. Un `major.minor` du plist écrit `0.2.0` (trois composantes) → on ne garde que les deux
   premières, pas de `0.2.0.47` (test de la tâche 4, étape de calcul de version).
3. Un zip dont le chemin contient des espaces ou une URL avec `&` → `make-appcast.sh` produit un
   XML valide (échappement ; test de la tâche 2 avec `xmllint`).
4. `sign_update` échoue (clé invalide) → `make-appcast.sh` sort en code non nul et n'écrit pas
   d'appcast partiel (test de la tâche 2).
5. Relance d'un workflow déjà publié (même run_number, tentative 2) → `gh release create` échoue
   sur le tag existant au lieu d'écraser en silence ; attendu, visible dans les logs.

---

### Tâche 1 : `build-app.sh` embarque les ressources et accepte une version injectée, plus `check-bundle.sh`

**Fichiers :**
- Modifier : `scripts/build-app.sh`
- Créer : `scripts/check-bundle.sh`

**Interfaces :**
- Produit : `ONYX_VERSION=<x.y.z> ONYX_BUILD=<n> scripts/build-app.sh` → `dist/Onyx.app` ;
  `scripts/check-bundle.sh <app> [<version> <build>]` → code 0 si le bundle est bon.

- [ ] **Étape 1 : écrire `scripts/check-bundle.sh` (le test)**

```bash
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
```

- [ ] **Étape 2 : lancer le test sur le bundle actuel → il DOIT échouer**

Run : `chmod +x scripts/check-bundle.sh && scripts/check-bundle.sh dist/Onyx.app 0.2.999 999`
Attendu : `check-bundle: version 0.2.0 ≠ 0.2.999` (puis, une fois la version injectée,
`ressource manquante : GRDB_GRDB.bundle`).

- [ ] **Étape 3 : modifier `build-app.sh`**

Après `cp Resources/Info.plist "$APP/Contents/Info.plist"`, ajouter :

```bash
# Version injectée par la CI (sinon : valeurs de Resources/Info.plist).
[ -z "${ONYX_VERSION:-}" ] || /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $ONYX_VERSION" "$APP/Contents/Info.plist"
[ -z "${ONYX_BUILD:-}" ]   || /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $ONYX_BUILD" "$APP/Contents/Info.plist"

# Paquets de ressources SwiftPM : l'accesseur Bundle.module les cherche dans
# Bundle.main.resourceURL. Sans eux, l'app ne marche que sur la machine de build.
for bundle in "$BUILD_DIR"/*.bundle; do
    [ -d "$bundle" ] || continue
    cp -R "$bundle" "$APP/Contents/Resources/"
done
```

- [ ] **Étape 4 : rebuild et relancer le test → il DOIT passer**

Run : `ONYX_VERSION=0.2.999 ONYX_BUILD=999 scripts/build-app.sh && scripts/check-bundle.sh dist/Onyx.app 0.2.999 999`
Attendu : `check-bundle: OK (0.2.999 / 999)`.
Puis vigilance n° 1 : `scripts/build-app.sh && scripts/check-bundle.sh dist/Onyx.app 0.2.0 0.2.0` → OK.

- [ ] **Étape 5 : commit** — `build-app : embarque les ressources SwiftPM, version injectable ; check-bundle.sh`

### Tâche 2 : `make-appcast.sh`

**Fichiers :** créer `scripts/make-appcast.sh`, `scripts/test-make-appcast.sh`

**Interfaces :**
- Consomme : un zip produit par `ditto`.
- Produit : `SPARKLE_ED_PRIVATE_KEY=<clé> scripts/make-appcast.sh <zip> <version> <build> <download-url> <release-notes-url> <out.xml>`
  → écrit `<out.xml>` ; code non nul sans sortie partielle si la signature échoue.

- [ ] **Étape 1 : écrire le test `scripts/test-make-appcast.sh`**

```bash
#!/usr/bin/env bash
# Test de make-appcast.sh avec une clé ed25519 jetable (hors trousseau).
set -euo pipefail
cd "$(dirname "$0")/.."
BIN=.build/artifacts/sparkle/Sparkle/bin
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
openssl genpkey -algorithm ed25519 -out "$T/k.pem"
KEY=$(openssl pkey -in "$T/k.pem" -outform DER | tail -c 32 | base64)
mkdir "$T/dir with space"; echo hello > "$T/dir with space/f"
ditto -c -k --keepParent "$T/dir with space" "$T/dir with space/Onyx-0.2.7.zip"

SPARKLE_ED_PRIVATE_KEY="$KEY" scripts/make-appcast.sh "$T/dir with space/Onyx-0.2.7.zip" \
    0.2.7 7 "https://example.com/dl?a=1&b=2" "https://example.com/notes" "$T/appcast.xml"
xmllint --noout "$T/appcast.xml"
grep -q 'sparkle:version="7"' "$T/appcast.xml"
grep -q 'sparkle:shortVersionString="0.2.7"' "$T/appcast.xml"
SIG=$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' "$T/appcast.xml")
echo "$KEY" | "$BIN/sign_update" --ed-key-file - --verify "$T/dir with space/Onyx-0.2.7.zip" "$SIG"

# Clé invalide → échec, pas de fichier écrit.
if SPARKLE_ED_PRIVATE_KEY="nope" scripts/make-appcast.sh "$T/dir with space/Onyx-0.2.7.zip" \
    0.2.7 7 u n "$T/bad.xml" 2>/dev/null; then echo "FAIL: clé invalide acceptée"; exit 1; fi
[ ! -e "$T/bad.xml" ] || { echo "FAIL: appcast partiel écrit"; exit 1; }
echo "test-make-appcast: OK"
```

- [ ] **Étape 2 : lancer → il DOIT échouer** (`make-appcast.sh: No such file`).

- [ ] **Étape 3 : écrire `scripts/make-appcast.sh`**

```bash
#!/usr/bin/env bash
# Écrit un appcast Sparkle à une seule entrée pour <zip>, signé EdDSA.
# La clé privée vient de $SPARKLE_ED_PRIVATE_KEY (jamais en argument).
# Usage : make-appcast.sh <zip> <version> <build> <download-url> <notes-url> <out.xml>
set -euo pipefail
ZIP="$1"; VERSION="$2"; BUILD="$3"; URL="$4"; NOTES="$5"; OUT="$6"
: "${SPARKLE_ED_PRIVATE_KEY:?SPARKLE_ED_PRIVATE_KEY manquante}"
BIN="$(cd "$(dirname "$0")/.." && pwd)/.build/artifacts/sparkle/Sparkle/bin"

# sign_update imprime : sparkle:edSignature="…" length="…"
ATTRS=$(printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$BIN/sign_update" --ed-key-file - "$ZIP")
[[ "$ATTRS" == *'sparkle:edSignature="'* ]] || { echo "make-appcast: signature échouée" >&2; exit 1; }

xml() { local s="${1//&/&amp;}"; s="${s//</&lt;}"; s="${s//>/&gt;}"; printf '%s' "${s//\"/&quot;}"; }
TMP="$OUT.tmp.$$"
cat > "$TMP" <<EOF
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
EOF
mv "$TMP" "$OUT"
```

- [ ] **Étape 4 : lancer le test → il DOIT passer** — `scripts/test-make-appcast.sh` → `test-make-appcast: OK`.
- [ ] **Étape 5 : commit** — `make-appcast.sh : appcast Sparkle signé EdDSA, + test`

### Tâche 3 : clés, plist, secrets

**Fichiers :** modifier `Resources/Info.plist`

- [ ] **Étape 1 :** `generate_keys` (crée la clé dans le trousseau de session) ; `generate_keys -p` → clé publique.
- [ ] **Étape 2 :** dans le plist : `SUFeedURL` → l'URL du flux ; ajouter `<key>SUPublicEDKey</key><string><publique></string>`.
- [ ] **Étape 3 :** `generate_keys -x <scratch>/sparkle.key` ; `gh secret set SPARKLE_ED_PRIVATE_KEY < <scratch>/sparkle.key` ; supprimer le fichier.
- [ ] **Étape 4 :** mot de passe aléatoire `openssl rand -base64 24` ;
  `security export -k login.keychain-db -t identities -f pkcs12 -P "$PW" -o <scratch>/onyx.p12`
  (exporte les identités du trousseau ; on vérifie ensuite qu'il ne contient que « Onyx Local »,
  sinon on filtre avec `openssl pkcs12` pour ne garder que cette identité) ;
  `base64 -i onyx.p12 | gh secret set CERT_P12_BASE64` ; `gh secret set CERT_P12_PASSWORD --body "$PW"` ; supprimer.
- [ ] **Étape 5 : vérifier** — `gh secret list` montre les 3 secrets ; `scripts/build-app.sh && scripts/check-bundle.sh dist/Onyx.app` OK.
- [ ] **Étape 6 : commit** — `Info.plist : flux Sparkle GitHub Releases + clé publique EdDSA`

### Tâche 4 : workflow

**Fichiers :** créer `.github/workflows/release.yml`

Étapes : checkout → `fetch-sherpa.sh` → `swift test` → import du certificat dans un trousseau
temporaire → calcul de la version (`cut -d. -f1-2` sur le plist : vigilance n° 2) →
`build-app.sh` → `check-bundle.sh` → `ditto` → `make-appcast.sh` → `gh release create` → trousseau
supprimé (`if: always()`).

- [ ] **Étape 1 :** écrire le YAML.
- [ ] **Étape 2 : vérifier** — `ruby -ryaml -e 'YAML.load_file(".github/workflows/release.yml")'`, et tester l'étape de calcul de version en local avec un plist `0.2.0` → `0.2.<n>`.
- [ ] **Étape 3 : commit** — `ci : workflow de release sur push main`

### Tâche 5 : docs, push, premier run

- [ ] **Étape 1 :** `docs/known-decisions.md` (section Sparkle) + une ligne dans le README.
- [ ] **Étape 2 :** commit + `git push origin main`.
- [ ] **Étape 3 : vérifier** — `gh run watch` jusqu'à la fin ; `gh release view --json assets` montre le zip + `appcast.xml` ; télécharger le zip, `scripts/check-bundle.sh` sur l'app extraite.
