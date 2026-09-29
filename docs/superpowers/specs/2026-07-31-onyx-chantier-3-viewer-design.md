# Onyx — Chantier 3 : Viewer SwiftUI (Design)

**Date** : 2026-07-31
**Auteur** : Yvan Betremieux
**Statut** : Design validé (mockup), à implémenter
**Chantier** : 3 / 3
**Mockup de référence** : `docs/superpowers/mockups/chantier-3/viewer.html`

---

## 1. Contexte & objectifs

Les Chantiers 1 et 2 ont livré la mécanique complète : capture → transcription → diarisation → notes générées par Claude Code, avec auto-trigger calendrier et détection Meet/Huddle. Tout ce contenu atterrit dans `~/Meetings/<slug>/` mais n'est consultable que par :

- la barre menu (liste des 5 derniers + boutons *Open folder* / *Open transcript.md*),
- Finder + éditeur Markdown externe.

Deux frictions apparaissent à l'usage :

1. **Aucune vue synthétique** : pour retrouver ce qui s'est dit dans une réunion il y a trois semaines, il faut ouvrir Finder, cliquer dans le bon dossier, ouvrir `notes/synthese.md` dans Typora, revenir en arrière pour le transcript, faire ⌘F… c'est utilisable, pas plaisant.
2. **Aucune édition possible sans quitter l'app** : les notes générées contiennent des erreurs (noms mal transcrits, actions oubliées) qu'on voudrait corriger directement, avec l'audio à côté pour vérifier.

Le Chantier 3 livre l'app viewer : une fenêtre SwiftUI qui rend les meetings à la fois **lisibles** (notes au centre, transcript en appui), **cherchables** (full-text SQLite déjà indexé) et **éditables** (notes + transcript, avec restauration possible de la version générée).

### Objectifs mesurables

- Ouvrir un meeting récent et lire sa synthèse en **≤ 2 clics** depuis n'importe quel état de l'app.
- Trouver n'importe quelle phrase prononcée dans les 90 derniers jours en **≤ 500 ms** de recherche (FTS SQLite déjà en place).
- Corriger une note ou un transcript **sans perte de la version générée** (restaurable par bouton).
- Lecture audio synchro avec le transcript : cliquer une ligne saute au timestamp, cliquer dans la waveform met en surbrillance le tour de parole courant.

### Contraintes non-négociables (héritées)

- **100 % offline** : la recherche est locale (SQLite FTS5 déjà présent), l'édition écrit sur disque, aucune ressource externe consultée.
- **Zéro régression sur le pipeline** : le viewer lit et modifie des fichiers dans `~/Meetings/`, il ne touche jamais aux composants d'enregistrement/transcription/notes.
- **Fallback dossier garanti** : chaque meeting reste consultable au Finder / éditeur Markdown, même si le viewer est cassé. Les fichiers écrits par le viewer suivent des conventions lisibles à l'œil nu (`synthese.user.md`, cf. §5).

---

## 2. Périmètre

### Dans le périmètre

- **Fenêtre principale** SwiftUI, layout 3-panneaux (sidebar meetings · notes · transcript), resizable horizontalement entre notes et transcript, hide/show du panneau transcript.
- **Sidebar** : liste virtualisée des meetings, groupée par date (Aujourd'hui, Hier, Cette semaine, mois précédents), badges par source (Manual / Cal / Meet / Huddle), compteur total en pied.
- **Panneau notes** : 4 tabs **Direct / Brief / Synthèse / Détaillée**, contenu éditable (contenteditable-like via `TextEditor` custom), auto-save débounce ~700 ms. La régénération (via bouton du header) écrase la note du niveau actif — comportement assumé, `Direct` est **jamais écrasée** par la régénération, elle sert d'ancrage utilisateur.
- **Notes en direct** : le tab **Direct** est éditable dès la création du meeting (y compris **pendant l'enregistrement**). Son contenu est **injecté dans le prompt Claude** lors de la génération de Brief/Synthèse/Détaillée, avec l'instruction d'intégrer les points, décisions et annotations du user dans le rendu final.
- **Panneau transcript** : tours de parole avec timestamps + chips speakers colorés, mode édition inline (segment par segment), highlight des matches de recherche.
- **Barre audio** en pied : play/pause, waveform précalculée, seek, contrôle vitesse (0.75× / 1× / 1.25× / 1.5× / 2×).
- **Recherche full-text** dans la sidebar (⌘K), snippets highlighted, cliquer un résultat ouvre le meeting positionné sur le premier match.
- **Header meeting** : titre + date + durée + participants (avatars empilés), actions rapides (Regenerate notes, Add speaker, Chapters).
- **Raccourcis clavier** natifs macOS (voir §9).
- **États vides** : pas de meeting sélectionné, pas de notes générées pour ce niveau, recherche sans résultat, meeting encore en transcription.

### Hors périmètre (explicite)

- **Multi-fenêtres** (une seule instance viewer à la fois).
- **Quick Look preview** depuis Finder → itération future.
- **Enregistrement depuis le viewer** : la capture reste déclenchée depuis la barre menu (chantier 1) ou l'auto-trigger (chantier 2). Le viewer est en lecture/édition.
- **Sync vers Notion / Slack / Obsidian / iCloud Drive** → post-chantier 3.
- **Édition manuelle des speakers** (rename "Speaker 1" en "Yvan" avec persistance cross-meetings) → itération future, dépendra d'un voice-fingerprinting pas encore en place.
- **Historique versionné** des éditions (git-style) → hors scope, on garde uniquement `generated` vs `user-edit`.
- **Recherche sur les notes** (v1 : FTS uniquement sur transcripts, comme déjà indexé). Ajout des notes au FTS = itération future ciblée.
- **Filtres avancés** (par participant, durée, source) → post-v1, la search full-text couvre 95 % des besoins.
- **Dark mode** : SwiftUI le gère quasi-gratuitement, mais on ne l'audite pas visuellement en v1. Palette conçue pour light mode d'abord.

---

## 3. Architecture

### Vue d'ensemble

Nouvelle fenêtre SwiftUI dans le target `Onyx`, indépendante de la `MenuBarExtra`. Les composants viewer sont regroupés sous `Sources/Onyx/Viewer/`. Aucun changement d'architecture globale : le viewer consomme les APIs existantes de `RecorderCore` (`MeetingStorage`, `MeetingIndexer`, `MeetingPaths`, `ClaudeNoteGenerator`) et ajoute deux petites APIs manquantes (recherche FTS + lecture/écriture des overrides utilisateur).

```
┌──────────────────────────────────────────────────────────┐
│  Onyx (target)                                            │
│  ┌─────────────────────┐    ┌──────────────────────────┐  │
│  │ MenuBarExtra        │    │ ViewerWindow             │  │
│  │ (Chantier 1 + 2)    │    │ (NEW — Chantier 3)       │  │
│  │  ┌───────────────┐  │    │  ┌──────┬──────┬──────┐  │  │
│  │  │ Recent meets  │──┼────┼─▶│Side  │Notes │Trans │  │  │
│  │  │ Settings      │  │    │  │bar   │      │cript │  │  │
│  │  │ Toggle rec    │  │    │  └──────┴──────┴──────┘  │  │
│  │  └───────────────┘  │    │  ┌──────────────────────┐  │  │
│  └─────────────────────┘    │  │ Audio scrubber       │  │  │
│                             │  └──────────────────────┘  │  │
│                             └────────────┬─────────────┘  │
└──────────────────────────────────────────┼───────────────┘
                                           │ reads/writes
                    ┌──────────────────────┼──────────────────┐
                    ▼                      ▼                  ▼
        ┌─────────────────┐    ┌───────────────────┐   ┌─────────────┐
        │ MeetingStorage  │    │ MeetingIndexer    │   │ FS layout   │
        │ (existing)      │    │ (existing + NEW   │   │ existing +  │
        │  loadMetadata   │    │  search API §7)   │   │  NEW user   │
        │  loadTranscript │    │                   │   │  overrides  │
        └─────────────────┘    └───────────────────┘   └─────────────┘
```

### Contrats

- **ViewerWindow ↔ MeetingStorage** : lecture de `meta.json`, `job.json`, `transcript.md`, `notes/<level>.md`. Écriture uniquement des fichiers `.user.md` (jamais des fichiers générés).
- **ViewerWindow ↔ MeetingIndexer** : `search(query:limit:)` (NEW), `recentMeetings(limit:)` (existing), `listAllGrouped()` (NEW).
- **ViewerWindow ↔ ClaudeNoteGenerator** : appel direct pour la regénération à la demande depuis le header (comme la barre menu le fait déjà).
- **ViewerWindow ↔ Recorder / Pipeline** : **aucun appel**. Le viewer est strictement en lecture/édition post-pipeline.
- **MenuBarExtra ↔ ViewerWindow** : la barre menu ouvre la fenêtre viewer (`showViewerWindow()`), ou la ramène au premier plan si elle existe déjà. Réutilise le même pattern que `showSettingsWindow()` déjà en place.

### Cycle de vie de la fenêtre

- Instance unique. Créée à la première ouverture, cachée à la fermeture (`orderOut` plutôt que dealloc), re-affichée par le prochain appel.
- État persistant sur disque (`~/Library/Application Support/Onyx/viewer_state.json`) : dernière sélection, split ratio notes/transcript, panneau transcript visible ou non, dernière recherche non vidée.

---

## 4. Layout & états — mapping mockup ↔ SwiftUI

Le mockup HTML (`docs/superpowers/mockups/chantier-3/viewer.html`) est la référence visuelle. Traduction SwiftUI :

| Zone mockup | Composant SwiftUI | Fichier prévu |
|---|---|---|
| Fenêtre (titlebar, traffic lights) | `NSWindow` avec `titleVisibility = .hidden`, `titlebarAppearsTransparent = true`, style `.hiddenTitleBar` | `Viewer/ViewerWindowController.swift` |
| Titre centré + breadcrumb | Custom `HStack` en toolbar, `NSToolbarItem` avec vue SwiftUI | `Viewer/Toolbar/ViewerToolbar.swift` |
| Sidebar (translucide) | `NSVisualEffectView` wrap + `List` SwiftUI virtualisée | `Viewer/Sidebar/MeetingsSidebar.swift` |
| Groupes par date | `Section` avec header custom (SF Pro semibold, 10.5px, tracking wide) | `Viewer/Sidebar/DateGroupSection.swift` |
| Ligne meeting | `MeetingRow` (HStack : time mono, title, meta, source badge) | `Viewer/Sidebar/MeetingRow.swift` |
| Search box (⌘K) | `TextField` custom avec background rounded, keybinding global | `Viewer/Sidebar/SearchField.swift` |
| Résultats search | `List` de `SearchResultRow` (title, snippet avec `AttributedString` highlighted, context mono) | `Viewer/Sidebar/SearchResultsList.swift` |
| Header meeting (title, actions) | `MeetingHeaderView` — titre `.system(size: 28, weight: .semibold)` + participants (`AvatarStack`) | `Viewer/Main/MeetingHeaderView.swift` |
| Notes panel + tabs | `NotesPanel` avec 4 tabs (Direct · Brief · Synthèse · Détaillée), `NotesEditor` (TextEditor custom rich) | `Viewer/Main/NotesPanel.swift` |
| Bandeau "édité, régénérer va écraser" | `RegenerateWarningBanner` (affiché uniquement si le fichier généré a été modifié depuis) | `Viewer/Main/NotesPanel.swift` |
| Transcript panel | `TranscriptPanel` (LazyVStack de `TurnView`) | `Viewer/Main/TranscriptPanel.swift` |
| Turn (timestamp, speaker chip, body) | `TurnView` avec `.editable` en mode édition | `Viewer/Main/TurnView.swift` |
| Resizer draggable | Custom `Divider` avec `NSCursor.resizeLeftRight` + `DragGesture` | `Viewer/Main/ResizableSplit.swift` |
| Hide panel button + FAB | Bouton dans `TranscriptPanel`, floating `Button` conditionnel | `Viewer/Main/TranscriptPanel.swift` |
| Audio scrubber | `AudioScrubberBar` avec `WaveformView` (Metal ou Canvas) + `AVAudioPlayer` | `Viewer/Audio/AudioScrubberBar.swift` |

### États UI principaux

1. **No meeting selected** — fond neutre, message "Sélectionne un meeting dans la sidebar" + icône SF Symbol `waveform`.
2. **Meeting en cours de transcription** — badge "Transcribing…" dans le header, tabs notes grisés, tooltip "Les notes seront disponibles à la fin du pipeline". Le viewer polle `job.json` (via `FileMonitor` NSFilePresenter, pas de timer) pour mettre à jour l'état.
3. **Notes non générées pour ce niveau** — le tab affiche un placeholder "Aucune note *Détaillée* pour ce meeting. [Générer]".
4. **Recherche active** — sidebar bascule en mode résultats, main panel garde le meeting courant. Cliquer un résultat charge le meeting cible et scroll le transcript au timestamp du match.
5. **Édition notes** — indicateur `Enregistré / Enregistrement…` dans la barre tabs, écriture directe dans le fichier du niveau actif. Aucun override, aucun Reset : la régénération (bouton header) écrase.
6. **Notes en direct pendant enregistrement** — le tab **Direct** est actif et éditable dès que le meeting existe (créé au moment où `Recorder.start()` crée le dossier). Les autres tabs (Brief/Synthèse/Détaillée) affichent un placeholder "Notes non générées, seront produites en fin de pipeline avec intégration de tes notes en direct".
7. **Édition transcript** — un tour est passé en édition (double-clic ou raccourci ⌘E), outline accent + tag "editing" à droite. Les modifs écrivent directement dans `transcript.md` (regen impossible côté transcript, c'est une donnée pipeline).
8. **Panneau transcript caché** — notes prennent toute la largeur, FAB `« Transcript` en haut à droite.

---

## 5. Data model & fichiers

### Layout meeting après Chantier 3

```
~/Meetings/2026-07-31_15h10/
├── meta.json                      (existing)
├── job.json                       (existing)
├── audio/
│   ├── mic.wav                    (existing)
│   ├── system.wav                 (existing)
│   ├── mic_normalized.wav         (existing)
│   ├── system_normalized.wav      (existing)
│   └── waveform.json              (NEW, pré-calculé au step .render)
├── transcripts/
│   ├── whisper_mic.json           (existing)
│   ├── whisper_system.json        (existing)
│   ├── diarization.json           (existing)
│   ├── transcript.json            (existing, generated)
│   └── transcript.md              (existing, éditable in-place)
└── notes/
    ├── live.md                    (NEW, créée à Recorder.start(), éditable pendant + après le meeting)
    ├── brief.md                   (existing, généré + éditable in-place)
    ├── synthese.md                (existing, généré + éditable in-place)
    └── detaillee.md               (existing, généré + éditable in-place)
```

### Modèle éditorial : simple et destructif assumé

Décision : **une seule version par niveau**. Pas de fichiers `.user.md` séparés.

- **Édition** = écriture directe dans `notes/<level>.md` (auto-save débounce ~700 ms, écriture atomique).
- **Régénération** (bouton du header) = écrase le fichier. Les modifs sont perdues. Comportement assumé et communiqué via un banner d'avertissement affiché **seulement si le fichier a été modifié après la dernière génération** :
  > "Cette note a été éditée depuis sa génération. Régénérer va écraser tes modifications."
  > `[Annuler]  [Régénérer quand même]`
- **Confirm de régénération** intégré au banner (pas de dialog séparé). Si aucune édition détectée, régénération sans confirm.

### Notes en direct (`notes/live.md`) — nouveau

- **Créée automatiquement** par `Recorder.start()` (nouveau step trivial : `try? "".write(to: paths.liveNotes, ...)` juste après le `createDirectory`).
- **Éditable immédiatement** dès que le user ouvre le meeting dans le viewer, y compris pendant que l'enregistrement tourne (tab "Direct" actif, autres tabs en placeholder tant que le pipeline n'a pas fini).
- **Jamais écrasée** par la régénération. C'est un artefact user permanent.
- **Injectée dans le prompt Claude** au moment de la génération de Brief/Synthèse/Détaillée (voir §5b).
- Persistée à chaque édition (auto-save débounce comme les autres notes).
- Si le user n'écrit rien pendant l'enregistrement, `live.md` reste vide et n'a aucun impact sur le prompt.

### Détection "modifié depuis génération"

- Comparer `attributesOfItem(atPath: notesFile(level).path).modificationDate` avec `attributesOfItem(atPath: paths.job).modificationDate` (proxy raisonnable de la date de fin de pipeline).
- Si `notes.mtime > job.mtime + N secondes` → considéré modifié, banner affiché.
- Solution robuste alternative (post-v1) : ajouter un champ `notesGeneratedAt` dans `meta.json` mis à jour par le pipeline, comparer à `notes.mtime`.

### Écriture

- Auto-save débounce ~700 ms.
- Écriture atomique (`Data.write(to:options:.atomic)`) → pas de fichier corrompu si crash pendant l'écriture.
- Indicator "Enregistré / Enregistrement…" dans la barre tabs (comme le mockup).

---

## 5b. Intégration des notes en direct dans le prompt Claude

Modification de `NotePromptTemplates.prompt(for:transcript:)` (fichier existant, `Sources/RecorderCore/Notes/NotePromptTemplates.swift`) pour accepter un paramètre optionnel `liveNotes: String?`.

### Comportement

- Si `liveNotes == nil` ou `liveNotes.isEmpty` → prompt inchangé (rétrocompat totale avec les meetings pré-chantier-3 où `live.md` n'existera pas).
- Sinon → **avant** le bloc `Transcript :`, injection d'un bloc :

  ```
  Notes prises par l'utilisateur en direct pendant le meeting :
  ---
  {{LIVE_NOTES}}
  ---

  Ces notes reflètent ce que l'utilisateur a jugé important sur le moment.
  Intègre-les dans ta synthèse : reprends les points, décisions et actions
  qu'il a notées, corrige-les si le transcript les contredit, et complète
  avec ce qui manque. Ne les recopie pas mot pour mot, restructure-les
  proprement dans la sortie demandée.
  ```

- `ClaudeNoteGenerator.generate(paths:level:binary:)` lit `paths.liveNotes` avant de construire le prompt :

  ```swift
  let live = (try? String(contentsOf: paths.liveNotes, encoding: .utf8))?
      .trimmingCharacters(in: .whitespacesAndNewlines)
  let prompt = NotePromptTemplates.prompt(
      for: level, transcript: transcript, liveNotes: live?.isEmpty == false ? live : nil
  )
  ```

### Impact sur le pipeline

- Aucun changement de step. Le step `.notes` existant continue de tourner, il lit juste un fichier de plus si présent.
- Coût token supplémentaire : proportionnel à ce que le user tape. Négligeable dans l'écosystème Claude Code (~few hundred tokens en moyenne).

### Impact sur la barre menu (chantier 2 existant)

- Nouvelle entrée dans le menu barre : **"Open live notes ⌘⇧L"** pendant qu'un enregistrement tourne. Ouvre le viewer sur le meeting courant, tab Direct focussé. Non bloquant si viewer déjà ouvert.
- Alternative "MVP" : le tab Direct n'est atteignable qu'en ouvrant explicitement le viewer + sélectionnant le meeting courant. On peut ajouter le raccourci menu bar en itération.

### Waveform pré-calculée

- Générée une seule fois au step `.render` du pipeline (nouveau sous-step, ou append au step existant).
- Format : `waveform.json` = `[Float]` (peaks RMS toutes les ~50 ms).
- Le viewer lit ce tableau, dessine 200-300 barres selon la largeur du scrubber.
- Fallback : si `waveform.json` absent (meetings pré-chantier-3), le viewer le génère à la volée depuis `mic_normalized.wav` en une passe et le sauvegarde.

---

## 6. Composants SwiftUI

### Arbre de composants (top-down)

```
ViewerWindow (NSWindowController)
└─ ViewerRootView
   ├─ ViewerToolbar (breadcrumb + actions)
   └─ HSplitView
      ├─ MeetingsSidebar
      │  ├─ SearchField (⌘K binding)
      │  └─ ScrollView
      │     ├─ (browse) List<DateGroupSection>
      │     │           └─ MeetingRow (many)
      │     └─ (search) List<SearchResultRow>
      ├─ MainPanel
      │  ├─ MeetingHeaderView
      │  ├─ ResizableSplit (draggable divider)
      │  │  ├─ NotesPanel
      │  │  │  ├─ NotesTabs (Brief · Synthèse · Détaillée)
      │  │  │  ├─ NotesToolbar (Enregistré status · Reset button)
      │  │  │  └─ NotesEditor (rich TextEditor, contenteditable-like)
      │  │  └─ TranscriptPanel
      │  │     ├─ TranscriptToolbar (Copy · Export · Hide)
      │  │     └─ ScrollView
      │  │        └─ LazyVStack<TurnView>
      │  └─ AudioScrubberBar
      │     ├─ PlayButton
      │     ├─ WaveformView
      │     ├─ TimeLabel
      │     └─ SpeedButton
      └─ ShowPanelFAB (visible si transcript caché)
```

### Store & state management

- `ViewerStore` (`@Observable` class, macOS 14+ ou `ObservableObject` fallback) — single source of truth pour la fenêtre : `selectedMeetingId`, `activeNoteLevel`, `searchQuery`, `searchResults`, `splitRatio`, `transcriptPanelHidden`, `audioPlayer` (wrapping `AVAudioPlayer`), `currentPlayheadSeconds`.
- Les composants observent ce store via `@Bindable` / `@ObservedObject`.
- La persistance viewer-state écrit sur disque à chaque changement (débounce 500 ms).

---

## 7. Search API (backend addition)

Extension de `MeetingIndexer` avec deux méthodes :

```swift
public struct SearchHit: Equatable, Sendable {
    public let meetingId: String
    public let title: String?
    public let startedAt: Date
    public let speaker: String
    public let snippet: AttributedString    // avec les matches surlignés
    public let approximateTimestamp: TimeInterval?
    public let matchCount: Int
}

public func search(_ query: String, limit: Int = 100) throws -> [SearchHit]
public func listAllGrouped() throws -> [MeetingListing]  // pour la sidebar full
```

### Implémentation

- Requête FTS5 : `SELECT meeting_id, speaker, snippet(transcripts_fts, 2, '<mark>', '</mark>', '…', 12) FROM transcripts_fts WHERE text MATCH ? LIMIT ?`
- Jointure avec `meetings` pour récupérer titre/date.
- Extraction du timestamp : `transcripts_fts` n'a pas de colonne `start_seconds` en v1 — **ajout d'une colonne `start_ms INTEGER`** dans la migration v2 du schéma, alimentée depuis `TranscriptSegment.start` au moment de l'`upsert`.
- Retour d'`AttributedString` déjà formatée (parse manuel des balises `<mark>` en `foregroundColor` + `backgroundColor`).

### Migration IndexSchema v2

```swift
m.registerMigration("v2_fts_timestamp") { db in
    // FTS5 external content tables ne supportent pas ALTER TABLE ADD COLUMN
    // → drop+recreate + backfill si existant.
    try db.execute(sql: "DROP TABLE IF EXISTS transcripts_fts")
    try db.execute(sql: """
        CREATE VIRTUAL TABLE transcripts_fts USING fts5(
            meeting_id, speaker, text, start_ms UNINDEXED
        )
    """)
    // Marker pour déclencher un RescanRunner au prochain boot
    try db.execute(sql: "UPDATE meetings SET indexed_at = NULL")
}
```

Le `RescanRunner` existant repeuple le FTS depuis les `transcript.json` sur disque, incluant le nouveau champ `start_ms`.

### Debounce recherche

- Frappe utilisateur → 200 ms de debounce avant requête.
- Résultats stream via `AsyncStream<SearchHit>` pour ne pas bloquer l'UI sur les gros index.
- Cache LRU de 20 requêtes récentes en mémoire (clé = `query.lowercased().trim()`).

---

## 8. Audio playback & sync

### Playback

- `AVAudioPlayer` initialisé avec le premier fichier disponible parmi : `audio/mic_normalized.wav`, `audio/mic.wav`.
- Alternative future : mix mic + system à la volée via `AVAudioEngine` (hors scope v1, on prend mic-only pour simplifier).
- Vitesses supportées : 0.75× à 2× (5 crans). Persisté par meeting dans `viewer_state.json`.

### Sync playhead → transcript

- `AVAudioPlayer` publie sa position via un timer 100 ms (`CADisplayLink` idéalement).
- `TranscriptPanel` observe `currentPlayheadSeconds` et calcule le tour courant (binary search sur `[TranscriptSegment]` triés par `start`).
- Le tour courant est mis en évidence via `background(.accentColor.opacity(0.06))` + `id(activeTurnId)` pour scroll auto.
- Auto-scroll optionnel (toggleable, off par défaut pour éviter la nausée pendant qu'on lit).

### Sync transcript → playhead

- Cliquer sur le timestamp d'un tour ou double-clic sur son body → seek le player à `turn.start`.
- Cliquer dans la waveform → seek proportionnel à la position X.

---

## 9. Raccourcis clavier

| Raccourci | Action |
|---|---|
| `⌘K` | Focus search field |
| `⌘F` | Focus search (alias) |
| `⌘1` / `⌘2` / `⌘3` | Tabs notes : Brief / Synthèse / Détaillée |
| `⌘\` | Toggle panneau transcript |
| `⌘⇧E` | Enter/exit edit mode transcript (segment courant) |
| `⌘⇧R` | Regenerate notes du niveau actif |
| `␣` (Space) | Play/pause audio (si focus pas dans un éditeur) |
| `←` / `→` | Seek audio -5s / +5s |
| `⌘←` / `⌘→` | Seek au tour précédent / suivant |
| `⌘,` | Ouvrir Settings (comportement standard macOS) |
| `⌘S` | Force save (auto-save couvre déjà) |
| `Esc` | Fermer un dialogue modal, sortir d'un mode édition |

---

## 10. Intégration menu bar → viewer

Nouveau bouton dans le menu bar `Onyx` :

```
Open viewer…            ⌘⇧V
Recent Meetings ▸       (sous-menu existant, inchangé)
```

Clic → si la fenêtre viewer existe, la ramène au premier plan ; sinon la crée. Réutilise le pattern `openSettingsWindow()` déjà présent (`Sources/Onyx/Menu/MenuBarView.swift:72`).

Les entrées "Open transcript.md" et "Open folder" du sous-menu `Recent Meetings` restent (fallback Finder), mais un nouveau `Open in viewer` est ajouté en tête et devient l'action par défaut au clic sur le nom du meeting.

---

## 11. Migrations & backward compatibility

### FTS schema v2

Migration `v2_fts_timestamp` (§7) → drop + recreate FTS, mark `indexed_at = NULL` pour tous les meetings, `RescanRunner` repeuple au prochain boot. **Coût** : quelques secondes pour un index de 500 meetings.

### Fichiers `.user.md`

- Purement additifs, ne cassent rien. Un meeting sans override reste affiché comme avant.
- Les meetings d'avant chantier 3 (donc sans `.user.md`) affichent normalement le fichier généré.

### Waveform

- Absente pour tous les meetings existants → générée à la volée à la première ouverture dans le viewer, cache disque écrit après. Migration transparente.

### Aucune migration destructive.

---

## 12. Testing strategy

### Unit tests (Tests/RecorderCoreTests/)

- `MeetingIndexerSearchTests` : requêtes FTS avec highlights, `start_ms` correctement retourné, edge cases (query vide, accents, apostrophes).
- `IndexSchemaMigrationV2Tests` : bootstrap DB v1 avec données, migrer v2, vérifier `indexed_at = NULL` et schéma FTS correct.
- `WaveformGeneratorTests` : passage sur WAV court, vérifier peaks non-vides et longueur cohérente.
- `MeetingPathsUserOverrideTests` : accesseurs `userVariant`, résolution `resolvedNotesFile(level)`.

### Unit tests (Tests/OnyxTests/ ou UI/)

- `ViewerStoreTests` : sélection meeting, changement de tab, débounce search, persistance state.
- `NotesEditorAutosaveTests` : frapper, wait, vérifier écriture `.user.md`.
- `ResetWorkflowTests` : édit → reset → override supprimé, badge revenu à "Généré".

### Snapshot tests (optionnel, macOS)

- Screenshots de `MeetingsSidebar` avec 0/1/50/500 meetings.
- Screenshots de `NotesPanel` pour chaque tab, avec/sans override.
- Comparaison directe avec le mockup HTML pour valider le rendu.

### Manual QA checklist (à ajouter au plan)

- Search "test" retourne les bons meetings avec les bons snippets.
- Éditer note → refresh viewer (⌘R hypothétique ou re-sélection meeting) → override chargé.
- Reset supprime bien `.user.md` sur disque (vérifier au Finder).
- Cliquer un tour de transcript joue l'audio au bon endroit.
- Hide panel + relaunch → panneau reste caché (persistance state).
- Regénérer notes pendant qu'un `.user.md` existe → banner d'avertissement, `.md` écrasé, `.user.md` intact.

---

## 13. Décisions & alternatives écartées

### Un seul fichier édité vs override séparé
**Choix** : un seul fichier, édition destructive assumée. Régénération = écrasement, protégée par banner si édité depuis génération.
**Alternative initiale envisagée** : override séparé (`.user.md`). **Rejeté** parce que ça complique la mental model (deux versions, comment switcher, laquelle est "vraie"), et que la régénération produit intentionnellement une version qui remplace la précédente — pas de raison de garder deux copies divergentes.

### Notes en direct : fichier dédié `live.md` vs édit dans synthèse
**Choix** : fichier dédié `notes/live.md`, jamais écrasé par la pipeline, injecté dans le prompt.
**Alternative** : le user tape directement dans `synthese.md` avant que la pipeline ne tourne, puis on merge. **Rejeté** parce que la pipeline écraserait ce que le user a tapé et perdrait la source. Avec `live.md` séparé, la note directe reste consultable comme artefact permanent (utile pour audit "qu'est-ce que je pensais sur le moment vs ce que Claude a synthétisé").

### Rich TextEditor vs Markdown source
**Choix** : édition sur le Markdown rendu (WYSIWYG-like), sauvegarde en Markdown reconstruit.
**Alternative** : édition texte brut Markdown (comme iA Writer). **Rejeté** pour l'usage viewer (on ne veut pas voir `**gras**`), mais reste faisable en v2 avec un toggle.

### Historique versionné vs generated/user seulement
**Choix** : deux états (généré + éditée), pas d'historique.
**Alternative** : historique git par meeting. **Rejeté** en v1 (complexité, storage, UI supplémentaire). Peut être ajouté sans casser rien.

### Recherche sur notes aussi
**Choix** : v1 = FTS uniquement sur transcripts (existant).
**Alternative** : ajouter les notes au FTS. **Reporté** : les notes changent (regénération), plus complexe à garder synchro. À ajouter en itération ciblée si l'usage le demande.

### Une seule fenêtre viewer vs multi-window
**Choix** : instance unique.
**Alternative** : plusieurs meetings ouverts côte à côte (tabs ou fenêtres). **Rejeté** en v1, ajoutable plus tard sans refonte.

---

## 14. Ouvertures / post-chantier 3

- **Speakers persistants** : rename "Speaker 1" → "Yvan", persisté cross-meetings via voice fingerprint. Nécessite un modèle speaker embeddings (pyannote fait ça, WhisperKit non).
- **Export** : sync des notes vers Notion via API, ou push vers Obsidian vault local. Le format Markdown existant est déjà compatible.
- **Chapters** : segmentation automatique du transcript en chapitres via LLM, affichage sous forme d'ancre dans le transcript.
- **Cross-meeting insights** : "toutes les fois où on a parlé de X ces 90 derniers jours" — Claude synthèse à partir des résultats FTS.
- **Voice memos rapides** : bouton "quick record" dans le viewer pour capturer une pensée hors meeting, avec le même pipeline.

---

## 15. Résumé exécutif

Chantier 3 = **fenêtre viewer SwiftUI** livrée en quatre pans :

1. **Lire** — layout 3-panneaux (sidebar meetings groupée par date · notes centrales · transcript de côté), audio scrubber en pied, waveform pré-calculée, sync playhead↔transcript. Basé sur le mockup HTML validé.
2. **Chercher** — extension de `MeetingIndexer` avec `search(_:limit:)` retournant `SearchHit` avec snippets highlighted et timestamps. Migration schema v2 pour ajouter `start_ms` au FTS.
3. **Éditer** — notes ET transcript éditables in-place, écriture directe dans les fichiers, régénération assumée comme destructive avec banner d'avertissement si le fichier a été modifié depuis la génération.
4. **Prendre des notes en direct** — nouveau fichier `notes/live.md` créé à `Recorder.start()`, éditable pendant tout le meeting via un tab "Direct" dans le panneau notes, contenu injecté dans le prompt Claude au moment de la génération pour intégration dans la synthèse.

**Nouveaux composants** : ~15 fichiers Swift sous `Sources/Onyx/Viewer/`, 2 méthodes ajoutées à `MeetingIndexer`, 1 migration schema v2, 1 helper `WaveformGenerator`, 4 accesseurs sur `MeetingPaths` (dont `liveNotes`), extension de `NotePromptTemplates.prompt` avec paramètre `liveNotes:` optionnel.

**Aucune régression** sur les chantiers 1 & 2 : le viewer est un consommateur en lecture + écriture directe. La seule modif au pipeline chantier 2 est l'injection optionnelle des live notes, purement additive. Fallback dossier/Finder toujours possible.

**Coût implémentation estimé** (indicatif, sans engagement) : ~30 tâches TDD dans la lignée du chantier 2, cf. plan `docs/superpowers/plans/2026-07-31-onyx-chantier-3-viewer.md`.
