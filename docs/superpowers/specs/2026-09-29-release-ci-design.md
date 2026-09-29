# Release CI + mises à jour Sparkle — design

## Objectif

Chaque push sur `main` publie automatiquement une nouvelle version d'Onyx sous forme de
release GitHub, et les apps déjà installées la proposent via Sparkle. Aucune action manuelle
après le push.

## Contraintes acceptées

- **Gatekeeper** : l'app reste signée avec le certificat auto-signé « Onyx Local » (pas de
  Developer ID ni de notarisation). Au premier lancement, l'utilisateur doit passer par
  « Ouvrir quand même » ; c'est documenté dans le README.
- **Repo privé pour l'instant** : les assets des releases et l'appcast ne sont pas
  téléchargeables sans authentification, donc la vérification de mises à jour Sparkle échoue
  tant que le repo est privé. Comportement attendu, sans gravité ; tout fonctionne une fois le
  repo passé en public.
- **Minutes macOS** : en privé, les runners macOS consomment le quota ×10 (~200 minutes réelles
  par mois sur le plan gratuit). Gratuit une fois le repo public.

## Composants

### 1. `scripts/build-app.sh` (modifié)

- Embarque les paquets de ressources SwiftPM (`$BUILD_DIR/*.bundle` : GRDB, swift-transformers
  Hub, swift-crypto) dans `Contents/Resources`, où l'accesseur `Bundle.module` généré les
  cherche (`Bundle.main.resourceURL`). Sans ça, l'app ne marche que sur la machine qui l'a
  compilée.
- Nouvelles variables d'environnement facultatives :
  - `ONYX_VERSION` : si définie, remplace `CFBundleShortVersionString` dans le plist du bundle ;
  - `ONYX_BUILD` : si définie, remplace `CFBundleVersion`.
  Sans elles, le comportement local est inchangé (valeurs de `Resources/Info.plist`).
- Aucun changement de signature : il signe toujours avec l'identité `Onyx Local`, qu'elle vienne
  du trousseau de session (en local) ou d'un trousseau temporaire (en CI).

### 2. `Resources/Info.plist` (modifié)

- `SUFeedURL` → `https://github.com/YvanBetremieux/Onyx/releases/latest/download/appcast.xml`.
  `releases/latest/download/<asset>` redirige toujours vers la release la plus récente, donc
  pas d'hébergement séparé pour l'appcast.
- `SUPublicEDKey` → clé publique EdDSA générée par le `generate_keys` de Sparkle.
- `CFBundleShortVersionString` reste la source du `major.minor` (actuellement `0.2`).

### 3. `scripts/make-appcast.sh` (nouveau)

Entrées : chemin du zip, version, build, URL de téléchargement, clé privée EdDSA (via
l'environnement). Lance `sign_update` de Sparkle (depuis `.build/artifacts/sparkle/Sparkle/bin`)
et écrit un `appcast.xml` à une seule entrée (la dernière version) : `sparkle:version` = build,
`sparkle:shortVersionString` = version, `sparkle:minimumSystemVersion` = 13.0,
`sparkle:edSignature` + `length` renvoyés par `sign_update`, et un lien de notes de release vers
la page de la release. Un appcast à une seule entrée suffit : Sparkle ne regarde que l'élément
le plus récent.

### 4. `.github/workflows/release.yml` (nouveau)

- **Déclencheur** : `push` sur `main`, `paths-ignore` : `**/*.md`, `docs/**`. Plus
  `workflow_dispatch` pour relancer à la main.
- **Concurrence** : groupe `release`, `cancel-in-progress: false` (les releases se sérialisent).
- **Runner** : image GitHub macOS arm64 (`macos-26`, qui fournit Xcode 26). Dépôt personnel :
  un runner hébergé par GitHub convient.
- **Permissions** : `contents: write`.
- **Étapes** :
  1. checkout ;
  2. `scripts/fetch-sherpa.sh` ;
  3. `swift test` : si ça échoue, rien n'est publié ;
  4. import du certificat : `CERT_P12_BASE64` décodé dans un trousseau temporaire (avec
     `CERT_P12_PASSWORD`), ajouté à la liste de recherche, partition list configurée pour
     `codesign` ; trousseau supprimé à la fin de l'étape (`if: always()`) ;
  5. versions : `ONYX_VERSION = <major.minor du plist>.<github.run_number>`,
     `ONYX_BUILD = <github.run_number>` ;
  6. `scripts/build-app.sh` ;
  7. `ditto -c -k --keepParent dist/Onyx.app dist/Onyx-<version>.zip` ;
  8. `scripts/make-appcast.sh` avec `SPARKLE_ED_PRIVATE_KEY` ;
  9. `gh release create v<version> dist/Onyx-<version>.zip dist/appcast.xml
     --generate-notes --target <sha>` (marquée « latest »).

`github.run_number` croît strictement pour ce workflow, ce qui donne à Sparkle un
`CFBundleVersion` croissant. Le passage à 0.3 se fait en modifiant le plist.

### 5. Secrets GitHub (définis par Claude via `gh secret set`)

| Secret | Source |
|---|---|
| `CERT_P12_BASE64` | identité « Onyx Local » exportée du trousseau de session en `.p12`, en base64 |
| `CERT_P12_PASSWORD` | mot de passe aléatoire choisi au moment de l'export |
| `SPARKLE_ED_PRIVATE_KEY` | `generate_keys -x` (la clé reste aussi dans le trousseau de session) |

Le `.p12` et la clé exportée ne passent que par le scratchpad de la session et sont supprimés
juste après leur envoi. L'export du `.p12` depuis le trousseau déclenchera une demande du
mot de passe du trousseau de session.

### 6. Documentation

- `docs/known-decisions.md` : la section Sparkle décrit maintenant le pipeline réel (appcast
  GitHub Releases, signature EdDSA, certificat auto-signé partagé en CI).
- `README` : une ligne sur les mises à jour automatiques.

## Pourquoi le même certificat en CI

macOS attache les autorisations TCC (micro, enregistrement d'écran) à l'exigence désignée de
la signature de l'app. Une signature ad hoc ou avec une nouvelle identité à chaque build
invaliderait ces autorisations à chaque mise à jour, et Sparkle rejette une mise à jour dont
l'identité de signature diffère de celle de l'app installée.

## Tests

- En local : `build-app.sh` avec `ONYX_VERSION=0.2.999 ONYX_BUILD=999`, puis vérifier le plist
  du bundle, la présence des `.bundle` dans `Contents/Resources`, et `codesign --verify`.
- `make-appcast.sh` sur le zip local : vérifier l'XML, puis
  `sign_update --verify` (avec la clé publique) sur la signature.
- CI : le premier push lance le workflow ; vérifier que la release `v0.2.<n>` contient le zip
  et `appcast.xml`, et que l'app du zip passe `codesign --verify`.
- Le téléchargement de bout en bout par Sparkle ne peut être vérifié qu'une fois le repo public ;
  à faire à ce moment-là.

## Hors périmètre

Developer ID / notarisation, DMG, deltas, canaux beta, Homebrew cask.
