# Onyx — Chantier 2 : Auto-trigger + Notes Claude Code (Design)

**Date** : 2026-07-28
**Auteur** : Yvan Betremieux
**Statut** : Design validé, à implémenter
**Chantier** : 2 / 3

---

## 1. Contexte & objectifs

Le Chantier 1 a livré le core pipeline : capture audio + transcription + diarisation + storage, déclenché manuellement depuis la barre menu. À l'usage, deux frictions restent :

1. Il faut **penser à cliquer start** au bon moment ; oublier = pas d'enregistrement, tard = premières minutes manquées.
2. Le livrable final reste un **transcript brut**, sans synthèse. Utile mais coûteux à relire.

Le Chantier 2 attaque les deux : l'app démarre toute seule quand un meeting commence, et produit une note structurée en fin de pipeline. L'objectif d'usage passe de "clic → transcript brut" à "je ne fais rien → note lisible arrive dans mon dossier".

### Objectifs mesurables

- 0 clic requis pour capturer un meeting sur Google Meet ou Slack Huddle listé dans mon calendrier de travail.
- Une note Markdown structurée dans `notes/<level>.md` dans les ~2-3 min après la fin du meeting (dépend du modèle Whisper et de Claude Code).
- Aucun coût récurrent : la génération de notes utilise l'abo Claude Code de l'utilisateur (pas d'API tokens facturés).

### Contraintes non-négociables (héritées + nouvelles)

- **Core reste 100 % offline** : capture + transcription + diarisation + storage n'utilisent aucune ressource externe. Les deux nouvelles briques (calendar, notes Claude) sont des **couches ajoutées**, désactivables individuellement, sans impact sur le core.
- **Auth externe = zéro** : EventKit lit les calendriers déjà configurés dans macOS, Claude Code utilise son propre login. Aucun OAuth custom, aucun token à stocker.
- **Fallback manuel garanti** : chaque brique auto a un chemin manuel de secours (start manuel, generate on-demand). Panne d'une brique n'empêche pas l'app de rester utilisable.

---

## 2. Périmètre

### Dans le périmètre

- Auto-trigger d'enregistrement à partir des events du calendrier macOS (EventKit) qui matchent une règle explicite.
- Détection en direct de Google Meet (Chrome / Safari / Arc / Brave) et Slack Huddle (Slack.app natif).
- Nommage automatique des meetings depuis le titre de l'event calendar quand un match est établi.
- Génération de notes Markdown via `claude -p` en fin de pipeline, à un niveau default configurable (brief / synthèse / détaillée).
- Regénération à un autre niveau depuis la barre menu.
- Notifications macOS avec bouton "Stop" pour les auto-starts (opt-out silencieux).
- Onboarding étendu : accès EventKit, choix des calendriers, permissions automation navigateurs, détection binaire `claude`.

### Hors périmètre (explicite)

- Détection Zoom / MS Teams / Discord / FaceTime → itération future.
- Détection Meet dans Firefox / Vivaldi / autres navigateurs non-scriptables → itération future (ajout d'un bundle à la liste JXA).
- Slack web app dans le navigateur → non détecté v1 (Slack.app uniquement).
- Frontmatter YAML dans les notes → post-Chantier 2 (utile pour Chantier 3, pas nécessaire maintenant).
- Configuration des prompts depuis Settings → hardcodés dans le code, éditables via patch.
- Multi-langues des notes → FR hardcodé v1.
- App viewer / recherche full-text UI → Chantier 3.
- Sync des notes vers Notion / Slack → post-Chantier 3.

---

## 3. Architecture

Cinq nouveaux composants dans `RecorderCore`, un step ajouté au pipeline, et des extensions ciblées de `Onyx` (settings, UI, onboarding). Communication par disque + `AsyncStream` internes.

```
┌────────────────┐      ┌────────────────────────┐
│ CalendarWatcher│      │ DetectionCoordinator   │
│  EventKit poll │      │ ┌───────────┐┌───────┐ │
│  60s / 15min   │      │ │Meet       ││Huddle │ │
│  → matched     │      │ │Detector   ││Detect │ │
│    events      │      │ │(JXA 5s)   ││(NSWs) │ │
└────────┬───────┘      │ └───────────┘└───────┘ │
         │              └────────┬───────────────┘
         │                       │
         ▼                       ▼
   ┌────────────────────────────────────────┐
   │  AutoTriggerOrchestrator (actor)       │
   │  - états : .idle / .recording(meta)    │
   │  - consomme events + detection         │
   │  - émet start(meta) / stop             │
   │  - notif macOS "Recording X — [Stop]"  │
   └────────────┬───────────────────────────┘
                │
                ▼
        ┌───────────────────┐
        │  Recorder         │ (Chantier 1, inchangé)
        │  Pipeline         │  + NEW step .notes après .cleanup
        └────────┬──────────┘
                 │
                 ▼
        ┌──────────────────────┐
        │ ClaudeNoteGenerator  │  Process(claude -p)
        │  + NotePromptTemplates│  → notes/<level>.md
        └──────────────────────┘
```

### Contrats entre composants

- **CalendarWatcher → Orchestrator** : `AsyncStream<MatchedEvent>`. Émet quand un event pertinent approche.
- **DetectionCoordinator → Orchestrator** : `AsyncStream<CallEvent>`. Émet `.started(app, code)` / `.ended(app, code)` avec debounce 3s sur `.ended`.
- **Orchestrator → Recorder** : appels directs `start()` / `stop()` (Recorder existant, contrat inchangé).
- **Pipeline → ClaudeNoteGenerator** : appel direct dans le step `.notes`, lecture du `transcript.md` déjà écrit, écriture dans `notes/<level>.md`.
- **UI → ClaudeNoteGenerator** : appel direct pour la regénération à la demande (via menu bar → Recent Meetings → Regenerate as…).

Chaque composant est isolé, testable seul via un mock (pattern déjà en place pour `WhisperTranscribing` / `Diarizing` en Chantier 1).

---

## 4. CalendarWatcher

### Accès EventKit

- `EKEventStore.requestFullAccessToEvents()` demandé pendant l'onboarding.
- Refus → l'app reste fonctionnelle, l'auto-trigger calendar est off, banner permanent dans Settings pour ré-inviter.
- L'utilisateur configure ses calendriers Google / iCloud / Exchange dans macOS Settings une fois pour toutes ; Onyx lit ce qui est déjà là.

### Boucle de polling

- Poll toutes les **60 secondes** dans un horizon `now → now + 15 min`.
- Latence max avant déclenchement : 60s (acceptable, on gagne quelques minutes de contexte en amont de toute façon).
- Cache d'events déjà "armés" : `Set<eventIdentifier + startDate>` pour idempotence.
- Cache purgé des events dont `endDate < now - 5 min`.

Pas d'observer `EKEventStoreChanged` en v1 : la latence n'est pas garantie pour les nouveaux events et un poll simple couvre le besoin.

### Règles de match

Un event est **matché** (donc "à auto-record") si **tous** les critères sont vrais :

1. `event.calendar.calendarIdentifier ∈ Settings.enabledCalendarIds`.
2. `event.hasAttendees == true` et compte des participants > 1.
3. `event.title` ne contient pas `[no-rec]` (case-insensitive).
4. Un lien Meet est détecté dans `event.location` ou `event.notes` via la regex `meet\.google\.com/[a-z]{3}-[a-z]{4}-[a-z]{3}`.

**Slack Huddle n'apparaît jamais via calendar** : Huddle n'a pas d'URL invitable. Les huddles passent uniquement via la détection en direct (spontanée).

### Type émis

```swift
struct MatchedEvent {
    let id: String                 // EKEvent.eventIdentifier
    let title: String
    let startDate: Date
    let endDate: Date
    let meetURL: URL               // parsée depuis location/notes
    let calendarId: String
}
```

Émis via `AsyncStream<MatchedEvent>` dès qu'un event nouvellement matché entre dans l'horizon `now → now + 15 min`.

---

## 5. Detection (Meet + Slack Huddle)

Protocol commun, deux implémentations, un coordinator qui agrège et debounce.

### Protocol

```swift
public enum MeetingApp: String, Codable { case meet, slackHuddle }

public enum CallLifecycle: Sendable {
    case started(code: String)   // code = meeting code (Meet) ou window ID (Huddle)
    case ended(code: String)
}

public protocol MeetingAppDetector: Sendable {
    var app: MeetingApp { get }
    func events() -> AsyncStream<CallLifecycle>
}
```

### MeetDetector

- Poll toutes les **5 secondes** via AppleScript (JXA) sur les bundles suivants : `com.google.Chrome`, `com.apple.Safari`, `company.thebrowser.Browser` (Arc), `com.brave.Browser`.
- Script : énumère `windows -> tabs -> URL`, matche `meet\.google\.com/[a-z]{3}-[a-z]{4}-[a-z]{3}`.
- État interne : `Set<meetingCode>`. Diff avec l'état précédent → émet `.started` / `.ended`.
- Bundles pour lesquels la permission automation n'est pas accordée → skippés silencieusement (log warning).

**Limitation assumée** : Firefox n'expose pas d'API AppleScript pour ses onglets → Meets dans Firefox non détectés v1.

### SlackHuddleDetector

- Observer `NSWorkspace.shared.runningApplications` pour la présence de `com.tinyspeck.slackmacgap`.
- Slack en cours d'exécution → poll toutes les **5 secondes** via `CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID)`, filtre `kCGWindowOwnerName == "Slack"`, match `kCGWindowName` contenant `"Huddle"` (case-insensitive).
- Diff avec l'état précédent → émet `.started(windowID)` / `.ended(windowID)`.
- Ne requiert pas de nouvelle permission (Screen Recording déjà accordée pour ScreenCaptureKit du Chantier 1 ouvre `CGWindowList*`).

### DetectionCoordinator

- Instancie les détecteurs enabled, s'abonne à leurs streams.
- Merge en un seul `AsyncStream<CallEvent>` :
  ```swift
  struct CallEvent {
      let app: MeetingApp
      let kind: Kind
      let code: String
      let at: Date
      enum Kind { case started, ended }
  }
  ```
- **Debounce 3 secondes sur `.ended`** : si un `.started` du même `(app, code)` revient dans les 3s, on annule le `.ended` (Meet flicker au reload de page, changement de tab).

---

## 6. AutoTriggerOrchestrator (state machine)

Actor stateful qui consomme les deux streams + les commandes UI (manual start/stop, opt-out).

### États

- `.idle` — aucun enregistrement en cours.
- `.recording(meta: MeetingMeta)` — un enregistrement tourne, `meta` sur disque.

### Table de transitions

| Depuis | Événement | Vers | Action |
|---|---|---|---|
| `.idle` | Matched event, `startDate` atteinte | `.recording` | `recorder.start()`, `meta = .calendar(title, eventId, url)`, notif "Recording X — [Stop]" |
| `.idle` | `CallEvent.started(app, code)` | `.recording` | Cherche matched event dont `startDate ∈ [now-5min, now+5min]` : si trouvé → `meta = .calendar + detectedApp filled(eventId, app, code)` ; sinon → `meta = .detected(app, code)`, notif "Meet in progress — [Stop]" |
| `.idle` | Manual start (menu / ⌘⇧R) | `.recording` | `meta = .manual` |
| `.recording` | Matched event, autre event | `.recording` | Ignore, notif "Event X ignored — already recording" |
| `.recording` | `CallEvent.started(app, code)` et `meta.detectedApp == nil` | `.recording` | Link : `meta.detectedApp = app`, `meta.detectedCode = code`, patch `meta.json` sur disque |
| `.recording` | `CallEvent.started(app, code)` et `meta.detectedApp != nil` | `.recording` | Ignore (assume même session) |
| `.recording` | `CallEvent.ended(app, code)` et `code == meta.detectedCode` | `.idle` | `recorder.stop()`, pipeline s'enchaîne |
| `.recording` | `CallEvent.ended(...)` autre | `.recording` | Ignore |
| `.recording` | Manual stop | `.idle` | `recorder.stop()` |
| `.recording` | Safety timer : > 3h | `.idle` | Force stop + notif "auto-stopped after 3h" |

### Cas "leave meet → join autre meet"

Le premier `.ended` fait passer en `.idle`. Le second `.started` déclenche donc une nouvelle session propre (nouveau slug, nouveau dossier). Deux enregistrements séparés, comme voulu.

### Notification macOS d'opt-out

Framework : `UserNotifications` (`UNUserNotificationCenter`).

- À chaque `.idle → .recording` auto (calendar ou detection), notif immédiate avec :
  - **Title** : "Recording — <title ou meeting sans titre>"
  - **Body** : "Started at HH:mm. Click [Stop] to cancel."
  - **Action** : "Stop"
- Comportement du bouton Stop :
  - Cliqué dans les **30 premières secondes** de l'enregistrement → cancel silencieux : `recorder.cancel()` (à ajouter au Recorder, cf. §10), delete le dossier meeting, retour `.idle`.
  - Cliqué après 30s → stop normal, pipeline traite ce qui a été capturé.

### Persistance

L'orchestrator est **stateless en mémoire**. L'état "recording en cours" est déjà persistant sur disque (Recorder écrit `meta.json` + audio en continu, Chantier 1). Si l'app crashe pendant un enregistrement, au redémarrage :

- `AppState.resumePendingJobs` (existant Chantier 1) détecte le meeting incomplet et relance le pipeline dessus.
- L'orchestrator démarre en `.idle`. Le meeting précédent est pipeliné en arrière-plan, l'orchestrator réagit normalement aux prochains signaux.

---

## 7. Claude Code notes

### Invocation

```
/usr/bin/env <claude> -p --output-format text
```

où `<claude>` est le path absolu résolu par l'onboarding et stocké dans `Settings.claudeBinaryPath`.

- **stdin** : `<system prompt>\n\n<transcript.md content>`.
- **cwd** : le dossier du meeting (permet à un futur prompt d'inclure des chemins relatifs, si besoin).
- **Timeout** : 5 minutes (`DispatchTime.now() + .seconds(300)`).
- **Env** : hérite de l'env de l'app (donc PATH minimal en `.app` bundle — d'où la nécessité du path absolu).

Aucun `--model` explicite → utilise le modèle default de l'installation Claude Code de l'utilisateur.

### Détection du binaire `claude` (onboarding)

Cherche dans l'ordre, s'arrête à la première trouvée :

1. `~/.claude/local/claude`
2. `~/.local/bin/claude`
3. `/opt/homebrew/bin/claude`
4. `/usr/local/bin/claude`
5. Résolution via `sh -lc "which claude"` (login shell → PATH étendu).

Trouvé → stocké dans `Settings.claudeBinaryPath`. Vérifié en lançant `<path> --version` (exit 0 attendu).

Non trouvé → banner dans onboarding et Settings : "Claude Code non détecté — auto-generate désactivé. [Configure path…]". L'app reste utilisable, `autoNotesEnabled` forcé à `false`.

### Prompts (3 templates constants)

Fichier `RecorderCore/Notes/NotePromptTemplates.swift`. Chaque prompt a la même structure :

```
Tu es un preneur de notes de meeting. Tu reçois la transcription d'un meeting
avec speakers identifiés :
- "MOI" = moi-même (l'utilisateur d'Onyx)
- "SPEAKER_N" = autres intervenants (N = 0, 1, 2, ...)

Génère les notes en français, format Markdown.

Niveau demandé : <BRIEF | SYNTHESE | DETAILLE>

<instructions spécifiques au niveau>

Transcript :
{{TRANSCRIPT}}
```

Instructions par niveau :

- **brief** : "3 à 5 bullets. TL;DR en une phrase, décisions prises, action items (owner si mentionné). Zéro contexte, zéro détail. ~150 mots max."
- **synthese** : "Sections : `## Contexte` (2-3 phrases), `## Décisions`, `## Points clés discutés`, `## Action items` (owner + deadline si mentionnés), `## Questions ouvertes`. ~500 mots. Ton neutre. Pas de verbatim, tu reformules."
- **detaillee** : "Synthèse (mêmes sections que ci-dessus) + `## Détail par thème` avec sous-sections thématiques, quotes verbatim entre guillemets pour les points-clés, timestamps `[MM:SS]` pour les moments notables. ~1500-2000 mots."

Les prompts sont **hardcodés** en Swift, versionnés avec le code. Modifier = patch + rebuild. Cette rigidité est assumée v1.

### Step .notes du pipeline

Ajouté après `.cleanup` :

```swift
try await runStep(.notes, paths: paths, overall: .generatingNotes) {
    guard settings.autoNotesEnabled, let path = settings.claudeBinaryPath else { return }
    let level = settings.defaultNoteLevel
    try await noteGenerator.generate(paths: paths, level: level,
                                     binary: path)
}
```

- **Idempotent** : skip si `notes/<level>.md` existe déjà pour ce niveau.
- **Échec du step** : `.notes` marqué `.failed` en `job.json`, `job.state` **reste `.done`** (transcript déjà écrit, réutilisable). Notif macOS "Notes generation failed for <slug> — retry from menu".
- **Retry** : depuis "Regenerate notes" dans la barre menu (utilise le même code path).

### Regénération depuis l'UI

Menu bar → "Recent Meetings" → clic sur un meeting → sous-menu "Regenerate notes as ▸ brief | synthese | detaillee".

Invoque `noteGenerator.generate(paths, level: chosen)` directement, écrit `notes/<level>.md`, ne touche pas à `job.json`. Écrase le fichier existant pour ce niveau si présent.

---

## 8. Data model & storage layout

### MeetingMetadata (évolution)

```swift
public struct MeetingMetadata: Codable {
    public let slug: String
    public let startedAt: Date
    public var stoppedAt: Date?
    // NOUVEAU Chantier 2 :
    public var title: String?
    public var source: Source
    public var calendarEventId: String?
    public var detectedApp: String?     // "meet" | "slack_huddle"
    public var detectedCode: String?    // code Meet ou window ID Huddle
    
    public enum Source: String, Codable {
        case manual, calendar, detected
    }
}
```

**Rétro-compat** : les meetings Chantier 1 n'ont pas ces champs. Le decoder utilise `decodeIfPresent` pour tous les nouveaux ; `source` par défaut = `.manual`.

### JobState (évolution)

- `JobStep` : ajout de `.notes` après `.cleanup` (donc dernier step de la chaîne).
- `JobOverallState` : ajout de `.generatingNotes`.
- `JobState.fresh()` initialise `.notes` en `.pending` comme les autres.

**Migration** : les `job.json` existants n'ont pas ce step. Le decoder tolérant de `JobState` (déjà en place, cf. `Sources/RecorderCore/Storage/JobState.swift`) ajoute un `.notes` à `.pending` par défaut. Les meetings **déjà terminés** (`state == .done`) ne re-déclenchent pas la génération rétroactive automatiquement ; l'utilisateur peut le faire via "Regenerate as…".

### MeetingPaths (évolution)

```swift
public extension MeetingPaths {
    var notesDir: URL { root.appendingPathComponent("notes", isDirectory: true) }
    func notesFile(_ level: NoteLevel) -> URL {
        notesDir.appendingPathComponent("\(level.rawValue).md")
    }
}

public enum NoteLevel: String, Codable, CaseIterable {
    case brief, synthese, detaillee
}
```

### Filesystem layout d'un meeting Chantier 2

```
~/Meetings/<slug>/
├── audio/
│   ├── mic.m4a
│   └── system.m4a
├── transcripts/
│   ├── whisper_mic.json
│   ├── whisper_system.json
│   ├── diarization.json
│   └── transcript.json
├── notes/                    NOUVEAU
│   ├── brief.md              (créé si generate a été appelé au niveau brief)
│   ├── synthese.md
│   └── detaillee.md
├── meta.json                 (schéma étendu §8)
├── job.json                  (nouveau step .notes)
└── transcript.md
```

Seuls les `notes/<level>.md` effectivement générés existent. Un meeting généré uniquement en `synthese` aura juste `notes/synthese.md`.

---

## 9. Settings, UI, Onboarding

### SettingsStore (nouveaux champs)

```swift
public struct AppSettings: Codable {
    public var meetingsFolder: URL              // Chantier 1
    // NOUVEAU :
    public var autoTriggerEnabled: Bool         // default true, kill switch global
    public var enabledCalendarIds: [String]     // whitelist EKCalendar identifiers
    public var autoNotesEnabled: Bool           // default true
    public var defaultNoteLevel: NoteLevel      // default .synthese
    public var claudeBinaryPath: String?        // résolu à l'onboarding
    public var detectionMeetEnabled: Bool       // default true
    public var detectionHuddleEnabled: Bool     // default true
}
```

Persisté en JSON dans `Application Support/Onyx/settings.json` (existant).

### SettingsWindow (sections)

Une fenêtre, tabs :

- **General** — meetings folder (existant).
- **Calendar** — checkbox par calendrier disponible (via EventKit), toggle "Enable auto-trigger from calendar", toggle "Show opt-out notification".
- **Detection** — toggle Meet, toggle Slack Huddle, ligne de doc "Meets in Firefox and Slack Web are not detected v1".
- **Notes** — toggle "Auto-generate notes after recording", picker default level, champ path `claude` binary + bouton "Test" (exécute `--version`).
- **Advanced** — kill switch `autoTriggerEnabled`, chemin meetings folder (déjà en General), reset onboarding.

### MenuBarView (évolution)

Structure :

```
● Idle  |  Start recording  (⌘⇧R)
─────────────
Recent Meetings ▸
  ▸ 12:17 — Design review
      ▸ Open folder
      ▸ Open transcript.md
      ▸ Regenerate notes as ▸ brief | synthese | detaillee
  ▸ 09:30 — Standup
      …
─────────────
Settings…
Quit
```

- Le sous-menu "Recent Meetings" liste les **5 derniers** via `MeetingIndexer.recentMeetings(limit: 5)` (à ajouter au `MeetingIndexer` existant).
- Généré à chaque ouverture du menu (pas de background refresh).
- "Open folder" → `NSWorkspace.shared.open(paths.root)`.
- "Open transcript.md" → `NSWorkspace.shared.open(paths.transcriptMd)`.
- "Regenerate notes as X" → invoque `noteGenerator.generate(paths, level: X)` en background, notif à la fin.

### Onboarding (évolution)

Séquence complète après le Chantier 1 (Permissions mic/audio + download modèles) :

1. **Calendar access** : `EKEventStore.requestFullAccessToEvents()`. Refus → skip, banner permanent dans Settings > Calendar.
2. **Calendar picker** : liste checkbox des calendriers disponibles. Pré-coché : calendriers dont le nom contient "Work" ou "Travail" ; sinon tous décochés (l'utilisateur choisit).
3. **Browser automation permissions** : un `tell application "<Browser>" to get URL of active tab of front window` par navigateur détecté (bundles installés). macOS pop la popup d'automation. L'utilisateur clique OK pour ceux qui l'intéressent, ignore les autres.
4. **Détection binaire `claude`** : résolution automatique. Trouvé → passe silencieusement. Non trouvé → banner "Claude Code binary not found — auto notes will be disabled. Configure path in Settings." (`autoNotesEnabled` forcé à `false`).

Persisté : `onboardingV2Done: true` dans les defaults (distinct du Chantier 1 pour permettre une réinvitation ciblée aux utilisateurs qui ont juste fait le Chantier 1).

---

## 10. Impacts sur le code existant

### Recorder

- Ajout d'une méthode `cancel()` (pour l'opt-out ≤30s) : arrête la capture sans déclencher le pipeline, delete le dossier meeting. Le pipeline en cours (s'il y en a un d'un meeting précédent) n'est pas affecté.

### Pipeline

- Nouveau step `.notes` (idempotent). L'appel à `noteGenerator` est conditionnel sur `settings.autoNotesEnabled`.

### AppState

- Instancie `AutoTriggerOrchestrator`, `CalendarWatcher`, `DetectionCoordinator`.
- Lance leurs boucles au démarrage.
- Passe l'orchestrator les callbacks de start/stop (qui délèguent à `toggleRecording` existant, adapté pour accepter une source + une meta pré-remplie).

### MeetingIndexer

- Nouveau champ `title` dans la table SQLite `meetings` (nullable).
- Nouvelle méthode `recentMeetings(limit: Int) -> [MeetingListing]` triée par `startedAt DESC`.

---

## 11. Non-fonctionnels

### Perf

- `CalendarWatcher` : poll 60s, requête EventKit dans un horizon 15min ≈ dizaines d'events max, cost négligeable.
- `MeetDetector` : JXA toutes les 5s, 4 bundles max = ~20 appels/min ≈ ~0.1% CPU en steady state (mesuré par expérience équivalente).
- `SlackHuddleDetector` : `CGWindowListCopyWindowInfo` toutes les 5s si Slack running ; sinon 0 poll.
- `ClaudeNoteGenerator` : bloque le step notes du pipeline ~30s-2min selon longueur transcript et niveau. Pipeline reste asynchrone au reste de l'app (déjà le cas Chantier 1).

### Permissions macOS ajoutées

- **Calendar (EventKit)** : demandée pendant l'onboarding.
- **Automation (Apple Events)** : pour chaque navigateur ciblé, demandée pendant l'onboarding.
- **Notifications** (`UNUserNotificationCenter.requestAuthorization`) : demandée à la première notification si pas encore accordée.

### Offline / dégradation

- Pas d'accès EventKit → `.autoTriggerEnabled` off, banner Settings. App reste utilisable.
- Pas d'accès automation Chrome → Meets via Chrome non détectés. Fallback = manual.
- `claude` binary absent → auto notes off, banner. Transcript reste produit.
- Erreur EventKit runtime → log + skip ce cycle de poll, retry au suivant.
- Erreur détecteur → log + reset l'état interne, continue.

### Safety cap

`recording` en cours depuis > **3 heures** → force stop + notif. Évite les enregistrements runaway si tous les détecteurs foirent (Slack ferme sans notifier, Meet reste ouvert en background). Configurable via `Settings.maxRecordingDurationMinutes` (default 180).

---

## 12. Tests

### Unit tests (RecorderCoreTests)

Nouveaux fichiers :

- `CalendarWatcherTests` — mock `EKEventStore`, vérifie les règles de match (whitelist, participants, no-rec, meet URL parsing), idempotence du cache.
- `DetectionCoordinatorTests` — mock des détecteurs (implémentations `AsyncStream` fixtures), vérifie le merge + debounce 3s sur `.ended`.
- `AutoTriggerOrchestratorTests` — mock `Recorder` + fixtures de streams, joue les scénarios de la table §6 un par un + le cas "leave→join" + safety 3h (temps virtuel).
- `ClaudeNoteGeneratorTests` — remplace le path binaire par un script bash de test qui echo un output prévisible, vérifie le round-trip (stdin composé, stdout capturé, notes/<level>.md écrit, timeout respecté).
- `NoteLevelTests` — decode / encode + rétro-compat MeetingMetadata.

### End-to-end manuel

Une checklist reproductible ajoutée à la fin du plan d'implémentation :

1. Créer un event Meet dans 2 min dans un calendrier whitelisté. Attendre. Vérifier l'auto-start + notif + le meeting est correctement nommé.
2. Créer un huddle Slack spontané. Vérifier l'auto-start + notif.
3. Meet en cours + un autre event calendar arrive → notif "ignored".
4. Leave Meet → l'enregistrement stoppe → pipeline complet + notes générées.
5. Kill l'app pendant le step notes → relance → notes régénérées.
6. "Regenerate notes as brief" depuis le menu → `notes/brief.md` apparaît.
7. Renommer temporairement `claude` binary → auto-generate step échoue → notif → transcript reste OK → réactiver le binary → regenerate manuel marche.

---

## 13. Décisions ouvertes / itérations futures

- Détection Zoom / Teams / Discord → ajout de détecteurs additionnels dans `DetectionCoordinator` si besoin.
- Détection Meet dans Firefox → nécessite une extension Firefox, hors scope.
- Frontmatter YAML dans `notes/*.md` → utile pour Chantier 3, à ajouter à ce moment-là.
- Choix de langue des notes → si à un jour des meetings en anglais deviennent réguliers, ajouter un `NoteLanguage` en Settings + variantes de prompts.
- Prompt tuning via Settings → si les prompts hardcodés produisent des notes qui déçoivent, exposer un éditeur.
- Sync automatique des notes vers Notion/Slack → post-Chantier 3.
