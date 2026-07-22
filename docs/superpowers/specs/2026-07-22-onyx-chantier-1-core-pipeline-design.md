# Onyx — Chantier 1 : Core Pipeline (Design)

**Date** : 2026-07-22
**Auteur** : Yvan Betremieux
**Statut** : Design validé, à implémenter
**Chantier** : 1 / 3

---

## 1. Contexte & objectifs

Onyx est un projet personnel : une app macOS type Granola, mais qui n'utilise **aucune API IA payante**. Les résumés/notes futurs seront générés en spawnant une session Claude Code fraîche à chaque meeting (Chantier 2). L'utilisateur est déjà abonné aux plans Claude, cette approche évite tout coût marginal.

Le projet est découpé en trois chantiers séquentiels, chacun livrant de la valeur seul :

- **Chantier 1** (ce document) — Core pipeline : capture audio + transcription + diarisation, 100 % offline, avec storage propre sur disque.
- **Chantier 2** — Auto-trigger via Calendar + détection Meet/Slack Huddle + intégration Claude Code (niveaux de note paramétrables).
- **Chantier 3** — App SwiftUI de visualisation/édition/recherche des transcripts et notes.

Extension future (post-Chantier 3, non-planifiée) : voice fingerprinting pour identifier automatiquement chaque intervenant à partir d'une banque de profils.

### Objectifs du Chantier 1

Livrer un outil utilisable seul : l'utilisateur clique dans la barre menu, parle, arrête, ouvre le dossier dans Finder, y trouve un transcript Markdown propre horodaté avec speakers identifiés.

### Contraintes non-négociables

- **100 % offline** dans le chemin critique (capture → transcription → diarisation → storage). Le VPN peut sauter, l'app continue.
- **Aucune perte de données** en cas de crash, kill process, coupure alim. Les segments audio déjà écrits doivent rester exploitables.
- **Pipeline reprenable** : si on tue l'app pendant la transcription, on peut relancer et il reprend à la dernière étape complétée.
- **UX minimaliste** : icône menu bar + un raccourci global. Zéro friction à l'usage courant.
- **Permissions préservées à travers les updates** (voir §8 — signature stable).

---

## 2. Périmètre

### Dans le périmètre

- Capture audio simultanée mic + audio système (macOS 13+, ScreenCaptureKit).
- Transcription locale via WhisperKit (modèle `large-v3`), langue forcée FR par défaut.
- Diarisation locale via sherpa-onnx sur le flux système, tag `MOI` explicite sur le flux mic.
- Storage hybride : dossiers plats par meeting (source de vérité) + index SQLite reconstructible (cache).
- UI menu bar (SwiftUI `MenuBarExtra`) avec raccourci global ⌘⇧R.
- Reprise automatique après crash (jobs idempotents, checkpointing sur disque).
- Onboarding en une étape (permissions + download modèles).
- Auto-update via Sparkle, signature avec certificat local self-signed (permissions macOS préservées).

### Hors périmètre (explicite)

- Auto-trigger via Google Calendar / iCal → Chantier 2.
- Détection de fin de meeting Meet/Slack Huddle → Chantier 2.
- Spawn Claude Code, niveaux de note (brève / synthèse / détaillée) → Chantier 2.
- Nommage automatique des meetings depuis titre calendar → Chantier 2.
- App viewer, édition manuelle des transcripts, recherche full-text UI → Chantier 3.
- Voice fingerprinting / identification par calendar attendees → extension future.
- Notarisation Apple / Developer ID → non requis pour usage perso.
- Distribution publique (Homebrew, site web) → post-Chantier 3.

---

## 3. Architecture

Cinq composants isolés, chacun testable indépendamment.

```
┌─────────────────┐    ┌──────────────┐    ┌────────────────┐
│ MenuBar UI      │───▶│ Recorder     │───▶│ Audio files    │
│ (SwiftUI)       │    │ (SCKit +     │    │ mic.wav        │
│ start/stop      │    │ AVFoundation)│    │ system.wav     │
└─────────────────┘    └──────────────┘    └────────┬───────┘
                                                    │ (on stop)
                                        ┌───────────▼─────────┐
                                        │ TranscriptionJob    │
                                        │ (post-recording,    │
                                        │  idempotent)        │
                                        │ ┌─────────────────┐ │
                                        │ │ 1. Normalize    │ │
                                        │ │ 2. Whisper mic  │ │
                                        │ │ 3. Whisper sys  │ │
                                        │ │ 4. Diarize sys  │ │
                                        │ │ 5. Merge        │ │
                                        │ │ 6. Render .md   │ │
                                        │ └─────────────────┘ │
                                        └─────────┬───────────┘
                                                  │
                                        ┌─────────▼───────────┐
                                        │ Storage             │
                                        │ ~/Meetings/<slug>/  │
                                        │ + SQLite index      │
                                        │   (rebuildable)     │
                                        └─────────────────────┘
```

### Contrats entre composants

- **UI → Recorder** : `start()`, `stop()`, `state` (observable).
- **Recorder → disque** : écrit `audio/mic.wav`, `audio/system.wav`, `meta.json` en continu.
- **Recorder → TranscriptionJob** : à `stop()`, notifie le job manager avec le chemin du dossier meeting.
- **TranscriptionJob** : lit les .wav, écrit progressivement dans `transcripts/*.json`, met à jour `job.json` à chaque étape.
- **Storage → SQLite index** : hook post-`done`, insert/update de la ligne dans `meetings`.

Aucun composant ne dépend de l'état runtime d'un autre : tout passe par le disque, ce qui rend chaque étape crash-safe et testable.

---

## 4. Recorder

### Capture audio

- **Mic** : `AVAudioEngine` avec tap sur l'input node.
- **Système** : `ScreenCaptureKit` (`SCStream`, `capturesAudio = true`), aucun filtrage par app pour v1.
- Les deux streams utilisent la **même horloge de référence** (`CMClock.hostTimeClock`) pour permettre l'alignement ultérieur.
- Format d'écriture pendant l'enregistrement : **WAV 16 kHz mono PCM float32** — pas de container à finaliser, chaque frame écrite est acquise même si le process meurt.
- Conversion en M4A (AAC) à la fin, pour archive compacte. Les .wav sont supprimés après transcription réussie ; le M4A est conservé.

Trade-off assumé : ~10× la taille disque temporaire pendant l'enregistrement (1 h ≈ 200 MB pour les deux flux WAV). Acceptable, la robustesse prime.

### Machine à états

```
idle ──▶ recording ──▶ stopping ──▶ transcribing ──▶ done
                          │              │
                          ▼              ▼
                       (crash)        (crash)
                          │              │
                          ▼              ▼
                    recoverable    resumable job
```

- **`idle`** : rien en cours. Menu bar icône grise.
- **`recording`** : capture active. Icône rouge pulsante. `stop()` → `stopping`.
- **`stopping`** : flush des writers WAV, conversion M4A, kick le `TranscriptionJob`. Bref (< 5 s).
- **`transcribing`** : job en background. Icône jaune. Nouveau `start()` autorisé (le job précédent continue en background).
- **`done`** : final. Retour à `idle` pour la session courante ; le meeting est visible dans le storage.

### Robustesse

- Écriture WAV en append via `AVAudioFile` (framework standard).
- Header WAV rewrité toutes les 30 s (task périodique) pour rester lisible si crash.
- Au démarrage de l'app, scanner `~/Meetings/*/job.json` : tout état non-`done`/`failed` est mis en queue de reprise.

### UI menu bar

- Icône : grise (idle) / rouge pulsante (recording) / jaune (transcribing).
- Click sur l'icône → menu : `Start recording` / `Stop recording`, `Open meetings folder`, `Settings`, `Quit`.
- Raccourci global : **⌘⇧R** = toggle start/stop.
- Aucune fenêtre principale en v1. Le seul écran plein est l'onboarding au premier lancement.

---

## 5. Pipeline de transcription

Job orchestré séquentiel, checkpointing sur disque après chaque étape. Chaque étape vérifie si son output existe déjà et le réutilise → idempotent.

### Étape 1 — Normalisation audio

- Input : `audio/mic.wav`, `audio/system.wav` (16 kHz mono float32 déjà, mais on garantit le format ici).
- Output : `audio/mic_normalized.wav`, `audio/system_normalized.wav`.
- Rôle : garantir le format d'entrée exact attendu par Whisper, indépendamment de ce qui a été capturé.

### Étape 2a — Transcription Whisper mic

- Modèle : **WhisperKit `large-v3`** CoreML (~3 GB, cached dans `~/Library/Application Support/Onyx/models/`).
- Langue : forcée FR par défaut. Réglage utilisateur dans Settings (pas d'auto-detect en v1 pour simplifier).
- Input : `audio/mic_normalized.wav`.
- Output : `transcripts/whisper_mic.json` — segments `[{start, end, text, confidence}]`.
- Checkpointing : append par chunks de N segments toutes les ~30 s.

### Étape 2b — Transcription Whisper système

Identique à 2a sur `audio/system_normalized.wav` → `transcripts/whisper_system.json`.

### Étape 3 — Diarisation (flux système uniquement)

- Modèle : **sherpa-onnx** avec pyannote segmentation + embedding (~50 MB, cached).
- Input : `audio/system_normalized.wav`.
- Output : `transcripts/diarization.json` — segments `[{start, end, speaker_id}]` avec `speaker_id ∈ {SPEAKER_00, SPEAKER_01, …}`.
- Le mic n'est pas diarisé : par convention c'est toujours `MOI`.

### Étape 4 — Merge

Fusion des trois sources en une timeline unique.

- Input : `whisper_mic.json`, `whisper_system.json`, `diarization.json`.
- Algo :
  1. Tag chaque segment de `whisper_mic` avec `speaker = "MOI"`.
  2. Pour chaque segment de `whisper_system`, associer le `speaker_id` de diarisation dont l'intervalle recouvre le plus l'intervalle du segment Whisper.
  3. Merger les deux listes en une seule triée par `start`.
- Output : `transcripts/transcript.json` — **source de vérité**, format :
  ```json
  [
    {"start": 0.0, "end": 4.2, "speaker": "MOI", "text": "Salut Alice, on commence ?"},
    {"start": 4.5, "end": 7.1, "speaker": "SPEAKER_00", "text": "Oui, j'ai regardé le doc."}
  ]
  ```

### Étape 5 — Rendu Markdown

- Input : `transcripts/transcript.json`, `meta.json` (pour l'horodatage absolu).
- Output : `transcripts/transcript.md`. Format :
  ```markdown
  # Meeting 2026-07-22 14:32

  ## 14:32:15 — MOI
  Salut Alice, on commence ?

  ## 14:32:19 — SPEAKER_00
  Oui, j'ai regardé le doc.
  ```

### Étape 6 — Cleanup

- Supprime `audio/mic_normalized.wav`, `audio/system_normalized.wav`.
- Convertit `audio/mic.wav` + `audio/system.wav` → `audio/mic.m4a` + `audio/system.m4a`, supprime les .wav sources.
- Marque `job.json` → `state: done`.
- Trigger l'indexer SQLite pour insérer/mettre à jour la ligne.

### Perf attendue

Sur M-series récent (M1 Pro et +) : `large-v3` ≈ 3-5× temps réel. Un meeting d'1 h transcrit + diarisé en ~15-20 min en background. Acceptable pour du post-processing (l'utilisateur consulte les notes plus tard, pas dans les 30 s).

---

## 6. Storage

### Layout disque

```
~/Meetings/
  2026-07-22_14h32/                    ← slug = date + heure (Chantier 1)
    audio/
      mic.m4a                          ← archive compressée finale
      system.m4a
      mic.wav                          ← pendant recording, supprimé après conversion
      system.wav                       ← idem
      mic_normalized.wav               ← intermédiaire, supprimé après transcription
      system_normalized.wav            ← idem
    transcripts/
      whisper_mic.json                 ← étape 2a
      whisper_system.json              ← étape 2b
      diarization.json                 ← étape 3
      transcript.json                  ← étape 4 — source de vérité
      transcript.md                    ← étape 5 — lisible humain
    meta.json                          ← metadata du meeting
    job.json                           ← state machine du pipeline
```

### `meta.json`

```json
{
  "id": "2026-07-22_14h32",
  "started_at": "2026-07-22T14:32:15+02:00",
  "ended_at":   "2026-07-22T15:47:03+02:00",
  "duration_seconds": 4488,
  "title": null,
  "source": "manual",
  "app_version": "0.1.0",
  "models": {
    "whisper": "large-v3",
    "diarization": "sherpa-pyannote-3.1"
  }
}
```

- `title` reste `null` en Chantier 1, sera rempli par Chantier 2 (titre calendar).
- `source` : `"manual"` en Ch1 ; futurs : `"calendar"`, `"huddle"`.

### `job.json`

```json
{
  "state": "merging",
  "steps": {
    "normalize":        {"status": "done",         "completed_at": "..."},
    "whisper_mic":      {"status": "done",         "completed_at": "..."},
    "whisper_system":   {"status": "done",         "completed_at": "..."},
    "diarize":          {"status": "done",         "completed_at": "..."},
    "merge":            {"status": "in_progress",  "started_at":  "..."},
    "render":           {"status": "pending"},
    "cleanup":          {"status": "pending"}
  },
  "error": null
}
```

- `state` ∈ `recording | normalizing | transcribing | diarizing | merging | rendering | cleanup | done | failed`.
- Au démarrage, l'app scanne `~/Meetings/*/job.json` : tout ce qui n'est ni `done` ni `failed` est mis en queue de reprise.
- Chaque étape lit son statut : si `done`, réutilise l'output existant sur disque ; sinon exécute.

### Index SQLite

- Chemin : `~/Library/Application Support/Onyx/index.sqlite`.
- Rôle : cache pour la recherche et le listing dans le viewer (Chantier 3). **Zéro donnée de vérité.**
- Reconstructible via l'action **Settings → Rescan meetings folder** (voir §8) qui relit tous les `meta.json` + `transcript.json` du dossier `~/Meetings/`. Si la DB est absente ou corrompue au démarrage, un rescan est déclenché automatiquement.

```sql
CREATE TABLE meetings (
  id                TEXT PRIMARY KEY,   -- slug = nom de dossier
  path              TEXT NOT NULL,      -- chemin absolu
  started_at        TEXT NOT NULL,      -- ISO 8601
  duration_seconds  INTEGER,
  title             TEXT,               -- NULL en Ch1
  transcript_state  TEXT,               -- 'done' | 'in_progress' | 'failed'
  indexed_at        TEXT
);

CREATE VIRTUAL TABLE transcripts_fts USING fts5(
  meeting_id, speaker, text
);
```

Le FTS n'est peuplé qu'après `state = done`. Le Chantier 3 en tirera parti.

---

## 7. Stack & structure du projet

Aligné sur la structure de `~/PycharmProjects/alt-tab` (WinTab) : **Swift pur, SwiftPM only**, pas de projet Xcode versionné.

### Cibles

- Swift 5.9+
- macOS **13+** (Ventura, requis pour `ScreenCaptureKit` avec `capturesAudio`)

### Dépendances SwiftPM

- [`WhisperKit`](https://github.com/argmaxinc/WhisperKit) — transcription CoreML/MLX
- [`sherpa-onnx`](https://github.com/k2-fsa/sherpa-onnx) — diarisation ONNX
- [`GRDB.swift`](https://github.com/groue/GRDB.swift) — SQLite avec API Swift propre
- [`Sparkle`](https://github.com/sparkle-project/Sparkle) — auto-update

Zéro dépendance runtime système : pas de Python, pas de FFmpeg externe (AVFoundation suffit).

### Arborescence

```
Onyx/
  Package.swift
  Sources/
    RecorderCore/                      ← lib pure, testable, sans UI
      Recorder/                        ← capture audio (mic + system)
      Transcription/                   ← wrapper WhisperKit
      Diarization/                     ← wrapper sherpa-onnx
      Pipeline/                        ← orchestrateur + Merger
      Storage/                         ← layout disque, meta.json, job.json
      Index/                           ← GRDB, indexer SQLite
      Models/                          ← téléchargement + cache modèles
    Onyx/                              ← executable target
      App.swift                        ← MenuBarExtra, wiring
      Onboarding/                      ← écran premier lancement
      Settings/                        ← langue, dossier meetings, hotkey
      Update/                          ← intégration Sparkle
  Tests/
    RecorderCoreTests/
      MergerTests.swift                ← align mic + system + diarisation sur fixtures
      StorageTests.swift               ← création/reprise job
      PipelineTests.swift              ← integration mini-audio 30 s
  scripts/
    build-app.sh                       ← monte Onyx.app + signe avec cert local
    generate-appcast.sh                ← génère l'appcast Sparkle pour releases
  docs/
    superpowers/
      specs/
        2026-07-22-onyx-chantier-1-core-pipeline-design.md
```

---

## 8. UX, lifecycle, distribution

Contrainte utilisateur : **installation simple, updates transparentes, permissions demandées une seule fois, minimum de clics, stable**.

### Signature & permissions

- Signature **self-signed avec certificat local stable**, généré une fois dans Keychain (`security create-keychain` + cert code-signing).
- Le script `build-app.sh` signe chaque release avec ce même cert → macOS voit une signature identique version après version → permissions Mic + Screen Recording **jamais redemandées** après le premier accord.
- Trade-off : premier lancement affiche Gatekeeper (clic-droit → Ouvrir la première fois). Une seule fois, jamais plus.
- Le certificat est sauvegardé/backupé — le perdre force une redemande de permissions à tous les users existants.

### Distribution

- Format : DMG contenant `Onyx.app`. Drag vers `/Applications`, double-click.
- Aucun installer, aucun daemon séparé, désinstallation = drag to trash.

### Auto-update

- **Sparkle** avec appcast hébergé sur GitHub Releases (repo privé) ou bucket S3.
- Vérification en background au lancement + toutes les 24 h.
- Popup non-intrusif : "Update ready, restart to install". Jamais forcé, jamais pendant un recording (Sparkle est mis en pause si `state == recording`).
- Delta updates activés (Sparkle gère nativement) → downloads légers.

### Onboarding (premier lancement)

Un seul écran, séquentiel :

1. **Bienvenue** (bouton "Commencer").
2. **Autorisation microphone** — demande système, deep-link vers Settings si refus.
3. **Autorisation Screen Recording** — idem.
4. **Téléchargement des modèles** — progress bar unique, télécharge Whisper large-v3 (~3 GB) et sherpa-onnx (~50 MB) en parallèle.
5. **Ready** — l'écran se ferme, l'icône menu bar apparaît.

Aucune fenêtre principale par la suite. Toute l'interaction courante passe par l'icône menu bar + le raccourci.

### Settings

Petite fenêtre accessible via menu bar → `Settings…` :

- Langue (défaut FR ; choix : FR, EN, autre).
- Dossier de sauvegarde (défaut `~/Meetings`).
- Raccourci global (défaut ⌘⇧R, remappable).
- Toggle "Check for updates automatically" (Sparkle).
- Bouton "Rescan meetings folder" (reconstruit l'index SQLite).
- Bouton "Open logs".

---

## 9. Testing

### Unit tests (`Tests/RecorderCoreTests/`)

- **MergerTests** : fixtures JSON représentant plusieurs scénarios (overlap total, partiel, aucun ; segments courts intercalés ; silences longs) → vérifie l'alignement Whisper + diarisation.
- **StorageTests** : création dossier meeting, écriture atomique `meta.json`, `job.json`, reprise depuis chaque état intermédiaire.
- **PipelineTests** : mini fichier audio 30 s avec 2 speakers pré-enregistrés → pipeline complet → transcript.json attendu (tolérance sur le texte via similarité string, exact match sur nombre de segments et speakers).

### Integration manuelle

- Vrai meeting perso 5 min sur Meet → dossier créé, transcript lisible.
- Test crash : `killall Onyx` pendant recording → relancer → vérifier que les .wav existants sont récupérés et le pipeline reprend.
- Test crash pendant transcription à chaque étape → vérifier reprise sans doublon (chaque étape lit son status dans `job.json`).
- Test permissions préservées : signer avec cert stable, faire 2 releases successives, vérifier qu'aucune permission n'est redemandée.

---

## 10. Risques identifiés

- **Précision de la diarisation** : sherpa-onnx sur audio Zoom compressé peut confondre 2 voix proches. Mitigation Ch2 : proposer via Claude un mapping speaker→invité basé sur les attendees calendar. Extension future : voice fingerprinting.
- **Taille du modèle Whisper large-v3** (~3 GB) : lourd au premier lancement. Mitigation : progress bar claire, DL en background, possibilité (v0.2) de proposer `distil-large-v3` (~1 GB) pour utilisateurs constraints.
- **Perte du certificat de signature** : si le keychain est perdu et pas backupé, une nouvelle signature révoquera toutes les permissions. Mitigation : documenter le backup du cert dans le README dev, procédure d'export .p12 chiffré.
- **`ScreenCaptureKit` sur macOS 13** : quelques bugs edge cases connus (audio drops rares). Mitigation : monitoring runtime, log de warning si stream health dégradé.
- **Perf sur Mac Intel** : hors périmètre. Onyx cible Apple Silicon (WhisperKit optimisé Neural Engine). Un Mac Intel fonctionnera mais transcript sera lent ; documenter dans README.

---

## 11. Livrables du Chantier 1

- Repo Git initialisé à `~/PycharmProjects/Onyx/` avec structure ci-dessus.
- `Package.swift` avec toutes les deps résolues, `swift build` et `swift test` verts.
- `scripts/build-app.sh` produit un `Onyx.app` signé, exécutable.
- Manuel : enregistrer un meeting 5 min via icône menu bar, obtenir un `transcript.md` propre horodaté avec speakers `MOI` + `SPEAKER_00/01/…`.
- Crash-test manuel réussi : force-quit pendant recording puis pendant chaque étape de transcription → reprise correcte au relaunch.
- Sparkle intégré, appcast fonctionnel sur une release factice.

Chantier 2 démarre uniquement quand tous ces critères sont verts.
