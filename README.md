# Onyx

App macOS en barre de menus qui enregistre les réunions (micro + audio système), les
transcrit avec WhisperKit, sépare les locuteurs avec sherpa-onnx, fusionne le tout en un
transcript, et génère optionnellement des notes via le CLI `claude` local.

L'enregistrement peut être déclenché manuellement, par un événement du calendrier (EventKit),
ou par la détection d'une fenêtre Google Meet / Slack Huddle active.

## Prérequis

- macOS 13 (Ventura) ou plus
- Xcode Command Line Tools (`xcode-select --install`)
- Swift 5.9+ (fourni avec Xcode 15+)
- Optionnel : le CLI `claude` installé localement, pour la génération de notes

## Installer depuis une release

Télécharger `Onyx-<version>.zip` depuis la
[dernière release](https://github.com/YvanBetremieux/Onyx/releases/latest), le dézipper et
glisser `Onyx.app` dans `/Applications`.

L'app est signée avec un certificat auto-signé (pas de notarisation Apple) : au premier
lancement, macOS la bloque. Ouvrir **Réglages Système → Confidentialité et sécurité →
« Ouvrir quand même »**, ou en terminal :

```bash
xattr -dr com.apple.quarantine /Applications/Onyx.app
```

Les mises à jour arrivent ensuite automatiquement via Sparkle : chaque push sur `main` publie
une release (`.github/workflows/release.yml`).

## Compiler sur une nouvelle machine

```bash
gh auth login                # si gh n'est pas encore configuré sur la machine
gh repo clone YvanBetremieux/Onyx
cd Onyx

scripts/fetch-sherpa.sh    # télécharge les dylibs sherpa-onnx dans Vendor/ + le header c-api.h
scripts/setup-cert.sh      # crée l'identité de signature locale "Onyx Local" dans le trousseau
scripts/build-app.sh       # build release + bundle + signature → dist/Onyx.app
git config core.hooksPath .githooks   # hook pre-commit : bloque un commit contenant un secret
```

Le repo est public : aucun secret ne doit y entrer. Trois garde-fous : le hook pre-commit
local (gitleaks sur l'index), la push protection de GitHub (refuse un push contenant un
token connu), et le workflow `Secrets` (gitleaks sur tout l'historique à chaque push et
chaque semaine, également exécuté avant chaque release). Scan manuel : `scripts/scan-secrets.sh`.

Le repo est privé : le clone suppose d'être authentifié sur le compte `YvanBetremieux`.
En SSH direct : `git clone git@github.com:YvanBetremieux/Onyx.git` (nécessite que la clé SSH
de la machine soit enregistrée sur ce compte).

`Vendor/sherpa-onnx/` et `Sources/CSherpaOnnx/include/c-api.h` ne sont **pas** versionnés :
ils sont régénérés par `fetch-sherpa.sh`. De même, le certificat de signature est propre à
chaque machine — d'où `setup-cert.sh`.

Puis déplacer `dist/Onyx.app` dans `/Applications` et le lancer.

## Au premier lancement

L'onboarding guide à travers les étapes qui ne peuvent pas être transférées d'une machine
à l'autre :

- **Permissions TCC** : micro, enregistrement d'écran (requis pour l'audio système),
  calendrier, et automation (pour la détection Google Meet via AppleScript)
- **Téléchargement des modèles** : Whisper (transcription) et le modèle de diarisation
- **Chemin du binaire `claude`** : si la génération de notes est activée

Ces autorisations sont liées à la signature de l'app : re-signer avec un nouveau certificat
les réinitialise.

## Développement

```bash
swift build                                  # build debug
swift test                                   # tous les tests
swift test --filter PipelineTests            # une classe de tests
swift build -c release --arch arm64          # ce que build-app.sh utilise
```

`RecorderCore` porte toute la logique et est couvert par les tests ; la cible `Onyx` est une
fine couche SwiftUI par-dessus. `DiarizerSmoke` et `E2ETrigger` sont des exécutables de
vérification manuelle, hors bundle.

Voir `CLAUDE.md` pour l'architecture détaillée (machine à états d'enregistrement, pipeline
reprenable, layout de stockage) et `docs/known-decisions.md` pour les trous délibérés à ne
pas « corriger ».

## Données

Rien de tout ça n'est dans le repo :

- Enregistrements et transcripts : `~/Meetings/`
- Index de recherche : `~/Library/Application Support/Onyx/index.sqlite` (reconstruit
  automatiquement s'il est corrompu)
- Réglages : `UserDefaults` de l'app

Pour retrouver l'historique des réunions sur la nouvelle machine, copier `~/Meetings/`
manuellement — l'index se reconstruira au lancement.
