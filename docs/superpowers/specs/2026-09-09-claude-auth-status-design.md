# État de connexion Claude : indicateur, reconnexion, bannière, rattrapage

Date : 2026-09-09
Statut : design validé, prêt pour plan d'implémentation

## Contexte — l'incident qui motive ce travail

Le CLI `claude` s'est déconnecté le 2026-09-07 à 10h12 (heure locale). Les transcripts des
sessions lancées par Onyx (`~/.claude/projects/-Users-yvan-betremieux-Meetings-*`) en gardent la
trace exacte :

| Horodatage | Message du CLI |
|---|---|
| 2026-09-07T08:12:54Z | `Failed to authenticate: OAuth session expired and could not be refreshed` |
| 2026-09-07T11:12:35Z → 2026-09-08T13:50:06Z | `Not logged in · Please run /login` (11 réunions) |

Conséquence : 11 réunions transcrites sans aucun résumé, pendant deux jours, **sans le moindre
signal**. Trois défauts se sont additionnés :

1. `ClaudeNoteGenerator.runClaude` ne conserve que `stderr` dans `GenerationError.nonZeroExit`.
   Le CLI écrit ses erreurs d'authentification sur **stdout**. `job.json` n'a donc enregistré que
   `nonZeroExit(code: 1, stderr: "")` — le message réel a été jeté.
2. `Pipeline.runStepSoft` journalise l'échec et remet `state = .done` (par conception : une note
   manquante ne doit pas invalider un transcript). Aucune notification, aucun indicateur.
3. Le bouton « Test » des Paramètres ne lance que `claude --version`, qui **réussit même
   déconnecté** — il donnait donc une fausse assurance.

## Objectifs

- Afficher dans les Paramètres si le CLI est connecté, et depuis quand l'information est connue.
- Offrir un bouton de reconnexion en un clic.
- Signaler activement la déconnexion (bannière + notification), pas seulement dans un log.
- Régénérer automatiquement les notes perdues pendant une déconnexion, une fois reconnecté.

## Hors périmètre

- Notifier les échecs de notes **non liés à l'auth** (transcript manquant, timeout, quota). La
  classification les distingue, mais seul le cas auth déclenche bannière et notification : c'est
  le seul qui touchera systématiquement toutes les réunions suivantes.
- Gérer l'auth par clé API (`ANTHROPIC_API_KEY`). Onyx reste sur le CLI OAuth de l'utilisateur.
- Sonder l'auth périodiquement en arrière-plan (écarté : coûte des tokens sans garantir l'état au
  moment où la vraie génération tourne).

## Architecture

### 1. Classification de l'erreur — `RecorderCore/Notes/ClaudeAuthError.swift`

Fonction pure, sans I/O, cœur testable du dispositif :

```swift
public enum ClaudeAuthFailure: Equatable, Sendable {
    case notLoggedIn        // "Not logged in · Please run /login"
    case sessionExpired     // "OAuth session expired and could not be refreshed"
}

public enum ClaudeAuthClassifier {
    /// nil = l'échec n'est pas un problème d'authentification.
    public static func classify(exitCode: Int32, stdout: String, stderr: String)
        -> ClaudeAuthFailure?
}
```

Reconnaissance par motifs, insensible à la casse, sur stdout **et** stderr (le CLI peut changer
de canal d'une version à l'autre ; ne pas parier sur stdout seul). `Invalid API key`,
`Credit balance too low` et les quotas retournent `nil` : ce ne sont pas des déconnexions et ils
ne doivent pas afficher « reconnecte-toi ».

### 2. Correctif du générateur — `RecorderCore/Notes/ClaudeNoteGenerator.swift`

- `GenerationError.nonZeroExit(code:stdout:stderr:)` — stdout ajouté au cas existant. Sans ça,
  rien n'est diagnosticable ni classifiable.
- Nouveau cas `GenerationError.authFailed(ClaudeAuthFailure, output: String)`, levé quand
  `ClaudeAuthClassifier.classify` reconnaît une déconnexion.
- `runClaude` collecte déjà stdout et stderr en continu (`DataCollector`) : seul le chemin
  `guard proc.terminationStatus == 0 else` change.

C'est une modification d'API publique : les appelants (`Pipeline`, `AppState.regenerateNotes`,
`ClaudeNoteGeneratorTests`) sont mis à jour dans le même mouvement.

### 3. État persistant — `RecorderCore/Notes/ClaudeAuthMonitor.swift`

```swift
public enum ClaudeAuthStatus: Codable, Equatable, Sendable {
    case unknown
    case connected(checkedAt: Date)
    case disconnected(ClaudeAuthFailure, since: Date)
}

public actor ClaudeAuthMonitor {
    public init(stateFile: URL, onChange: (@Sendable (ClaudeAuthStatus) -> Void)?)
    public var status: ClaudeAuthStatus { get }

    /// Appelé par l'étape .notes du pipeline — source de vérité passive, coût zéro.
    public func reportSuccess() async
    public func reportFailure(_ error: Error) async

    /// Sonde à la demande : vrai `claude -p` minimal, timeout 30 s.
    public func probe(binary: URL, model: String?) async -> ClaudeAuthStatus
}
```

- Persistance via `AtomicJSON` dans `~/Library/Application Support/Onyx/claude-auth.json`, au
  même endroit que `index.sqlite`. L'état survit au relancement : la bannière est correcte dès
  l'affichage, sans attendre une première réunion.
- `onChange` n'est appelé **que sur changement effectif** de statut (pas à chaque report). C'est
  ce qui garantit une notification unique au lieu de onze.
- `reportFailure` avec une erreur non-auth ne modifie **pas** le statut : un timeout ne doit pas
  faire croire à une déconnexion.
- `probe` envoie un prompt minimal (`Réponds uniquement: OK`) et interprète le résultat par la
  même `classify` — un seul chemin de décision pour la sonde et pour la production.

### 4. Report depuis le pipeline — `RecorderCore/Pipeline/Pipeline.swift`

`NoteGenerationConfig` gagne un champ `authMonitor: ClaudeAuthMonitor?` (l'actor est `Sendable`).
Le corps de l'étape `.notes` encadre son `withThrowingTaskGroup` d'un `do/catch` : report du
succès ou de l'échec au monitor, puis `throw` inchangé pour que `runStepSoft` conserve son
comportement actuel (marquage `failed`, `state` remis à `.done`).

`runStepSoft` n'est pas modifié — sa sémantique de soft-fail reste exactement celle documentée.

### 5. Sélection des retards — `RecorderCore/Notes/NotesCatchUp.swift`

```swift
public enum NotesCatchUp {
    /// Slugs dont l'étape .notes a échoué sur un problème d'auth, en ordre chronologique.
    public static func pendingSlugs(storage: MeetingStorage) throws -> [String]
}
```

Parcourt `storage.listMeetings()`, retient les réunions dont `job.steps[.notes].status ==
.failed` et dont l'`error` enregistré est classé auth. La chaîne d'erreur en base est le
`String(describing:)` de l'erreur Swift : la détection se fait sur `authFailed` (nouveau format)
**et** sur les motifs bruts (`Not logged in`, `OAuth session expired`) pour rattraper les
`job.json` déjà écrits — les 11 réunions des 7 et 8 septembre portent `nonZeroExit(code: 1,
stderr: "")` et ne sont donc **pas** récupérables par motif.

**Conséquence assumée** : ces 11 réunions ne seront pas détectées automatiquement, puisque le
message réel a été perdu à l'écriture. Le plan d'implémentation inclut donc une étape unique de
régénération manuelle pour ces 11 slugs, une fois le reste en place. Toute déconnexion future
sera, elle, rattrapée automatiquement.

### 6. Pilotage du rattrapage — `Sources/Onyx/AppState.swift`

Une méthode `catchUpNotes()`, calquée sur `resumePendingJobs()` :

- Pour chaque slug de `NotesCatchUp.pendingSlugs`, en ordre chronologique et **séquentiellement**,
  appelle `pipeline.run(paths:)`. Tous les autres steps étant `.done`, seule l'étape `.notes`
  s'exécute — pas de nouveau chemin de génération à maintenir, et `waitWhileRecording` du
  pipeline s'applique gratuitement : aucune rafale d'appels `claude` pendant une réunion (charge
  ANE).
- Puis `RescanRunner.reindex(slug:)`, comme `resumePendingJobs`, pour que le titre éventuellement
  détecté remonte dans l'index.
- **Interruption au premier échec d'auth** : si le statut du monitor repasse `disconnected` en
  cours de route, la boucle s'arrête. Onze appels condamnés d'affilée sont inutiles.
- Déclenchement : à la transition `disconnected → connected` (via `onChange`), et au lancement si
  le statut est `connected` et qu'il reste des retards.

### 7. Lancement de la reconnexion — `Sources/Onyx/Notes/ClaudeReconnectLauncher.swift`

```swift
@MainActor enum ClaudeReconnectLauncher {
    static func launch(binary: URL) -> Result<Void, ReconnectError>
}
```

Chaîne de replis, parce qu'un bouton mort serait pire que pas de bouton :

1. `osascript` → `tell application "Terminal" to do script "<binaire> /login"` + `activate`.
   Onyx utilise déjà `osascript` (détection Meet) et déclare `NSAppleEventsUsageDescription`.
2. Si l'autorisation Automation est refusée (erreur AppleScript `-1743`) ou si Terminal est
   absent : écriture d'un script `.command` temporaire (`chmod 0700`) ouvert via
   `NSWorkspace.shared.open` — aucune permission requise.
3. Si les deux échouent : la commande est copiée dans le presse-papier et l'UI affiche
   « Commande copiée — lance-la dans un terminal ».

Le chemin du binaire est échappé pour AppleScript (guillemets et antislashs).

### 8. UI

**Paramètres → Notes → section « Claude »** (`SettingsWindow.swift`)
- Ligne d'état : point coloré + libellé.
  - `● Connecté` (vert) — « vérifié à 11:42 »
  - `● Déconnecté` (orange) — « session expirée depuis lundi 10h12 » / « non connecté »
  - `● État inconnu` (gris) — « aucune génération depuis le dernier lancement »
- Le bouton « Test » devient **« Tester »** et fait les deux vérifications : `--version` (le
  binaire répond) puis `probe` (l'auth passe). Un seul bouton, plus de faux positif possible.
- Bouton **« Se reconnecter… »**, toujours présent, mis en avant seulement en état déconnecté.

**Bannière viewer** (`Sources/Onyx/Viewer/ClaudeAuthBanner.swift`, insérée en `VStack` au-dessus
du `HSplitView` de `ViewerRootView`)
- Visible uniquement en état `disconnected`, ou pendant un rattrapage en cours.
- Fond orange, texte « Claude déconnecté — les résumés ne sont plus générés », boutons
  « Se reconnecter… » et « Tester » (les mêmes actions qu'en Paramètres).
- Pendant le rattrapage : « Rattrapage des résumés — 3/11 », sans bouton.

**Menu de la barre de menus** (`MenuBarView.swift`)
- En état déconnecté seulement, un premier item `⚠ Claude déconnecté — se reconnecter…` qui
  appelle la même action. Rien d'affiché quand tout va bien.

**Notification macOS** (`OptOutNotificationCenter.swift`)
- `showClaudeDisconnected(_ failure:)` — titre « Claude déconnecté », corps « Les résumés de
  réunion ne sont plus générés. Reconnecte-toi dans les Paramètres d'Onyx. »
- Déclenchée par `onChange`, donc **une seule fois par transition**, pas une par réunion.

### Flux de données

```
claude -p (exit 1, message sur stdout)
  └─> ClaudeNoteGenerator : classify(stdout, stderr) → authFailed
        └─> étape .notes du Pipeline : monitor.reportFailure(error)
              ├─> claude-auth.json (persistance)
              └─> onChange (si le statut change vraiment)
                    └─> AppState.@Published claudeAuthStatus
                          ├─> bannière viewer
                          ├─> item du menu
                          └─> notification macOS (une fois)

Bouton « Se reconnecter… » → Terminal (claude /login) → l'utilisateur se connecte
Bouton « Tester » → monitor.probe → connected
      └─> onChange → AppState.catchUpNotes() → pipeline.run par réunion en retard
```

## Gestion des erreurs

| Situation | Comportement |
|---|---|
| Échec de notes non-auth (timeout, transcript manquant) | Statut inchangé, pas de bannière. Comportement soft-fail actuel préservé. |
| `claude-auth.json` absent ou corrompu | Statut `.unknown`, fichier réécrit au premier report. Jamais de crash. |
| Sonde en timeout (réseau coupé) | Statut inchangé (`.unknown` reste `.unknown`), l'UI affiche « Vérification impossible ». Une coupure réseau n'est pas une déconnexion. |
| Autorisation Automation refusée | Repli `.command`, puis presse-papier (§7). |
| Chemin du binaire vide ou invalide | « Tester » l'annonce avant toute sonde ; « Se reconnecter » est désactivé. |
| Déconnexion pendant le rattrapage | Boucle interrompue, bannière remise en « déconnecté ». |
| Rattrapage pendant un enregistrement | `waitWhileRecording` du pipeline le diffère jusqu'à la fin. |

## Tests — `Tests/RecorderCoreTests`

`ClaudeAuthClassifierTests`
- `Not logged in · Please run /login` → `.notLoggedIn` (chaîne réelle du 07/09)
- `Failed to authenticate: OAuth session expired and could not be refreshed` → `.sessionExpired`
- `Invalid API key`, `Credit balance too low`, stdout vide → `nil`
- Message présent sur stderr et non stdout → détecté quand même
- exit 0 → `nil` quel que soit le texte

`ClaudeNoteGeneratorTests` (complète l'existant)
- Faux binaire (script shell temporaire) sortant en 1 avec le message d'auth sur **stdout** →
  `authFailed(.notLoggedIn, _)` levé, et l'`output` conservé dans l'erreur
- Faux binaire sortant en 1 avec un message quelconque → `nonZeroExit` avec stdout **et** stderr
  renseignés

`ClaudeAuthMonitorTests`
- `reportFailure(authFailed)` → `.disconnected`, persisté sur disque, `onChange` appelé une fois
- Deux `reportFailure` consécutifs → `onChange` appelé **une seule** fois
- `reportSuccess` après déconnexion → `.connected`, `onChange` appelé
- `reportFailure(timedOut)` → statut inchangé, `onChange` non appelé
- Fichier d'état corrompu → `.unknown`, aucun throw

`NotesCatchUpTests`
- 3 réunions en dossiers temporaires (notes `.failed` auth, notes `.failed` timeout, notes
  `.done`) → seule la première est retournée
- Ordre chronologique respecté
- `job.json` illisible → réunion ignorée, pas de throw

Pas de test UI (`Tests/RecorderCoreTests` ne couvre que `RecorderCore`, conformément à
l'existant) : la logique testable est intégralement dans le cœur, les vues ne font que lire un
`@Published`.

## Fichiers touchés

Nouveaux
- `Sources/RecorderCore/Notes/ClaudeAuthError.swift`
- `Sources/RecorderCore/Notes/ClaudeAuthMonitor.swift`
- `Sources/RecorderCore/Notes/NotesCatchUp.swift`
- `Sources/Onyx/Notes/ClaudeReconnectLauncher.swift`
- `Sources/Onyx/Viewer/ClaudeAuthBanner.swift`
- `Tests/RecorderCoreTests/ClaudeAuthClassifierTests.swift`
- `Tests/RecorderCoreTests/ClaudeAuthMonitorTests.swift`
- `Tests/RecorderCoreTests/NotesCatchUpTests.swift`

Modifiés
- `Sources/RecorderCore/Notes/ClaudeNoteGenerator.swift` (stdout dans l'erreur, `authFailed`)
- `Sources/RecorderCore/Pipeline/Pipeline.swift` (`authMonitor` dans la config, report dans `.notes`)
- `Sources/Onyx/AppState.swift` (monitor, `@Published claudeAuthStatus`, `catchUpNotes()`)
- `Sources/Onyx/Settings/SettingsWindow.swift` (ligne d'état, « Tester », « Se reconnecter… »)
- `Sources/Onyx/Viewer/ViewerRootView.swift` (insertion de la bannière)
- `Sources/Onyx/Menu/MenuBarView.swift` (item d'alerte)
- `Sources/Onyx/Notifications/OptOutNotificationCenter.swift` (`showClaudeDisconnected`)
- `Tests/RecorderCoreTests/ClaudeNoteGeneratorTests.swift` (nouvelle signature d'erreur)

## Décisions et alternatives écartées

- **État passif plutôt que sonde périodique.** L'état vient de ce qui s'est réellement passé lors
  d'une vraie génération. Une sonde de fond coûterait des tokens sans garantir l'état au moment
  utile.
- **Pas de lecture du token en keychain.** Gratuit et instantané, mais format non documenté,
  invite d'accès keychain, et un token d'apparence valide peut être refusé côté serveur. La sonde
  coûte quelques tokens et dit la vérité.
- **Rattrapage via `pipeline.run` plutôt qu'un chemin de génération dédié.** L'étape `.notes`
  ignore déjà les niveaux dont le fichier existe et `runStepSoft` re-tente un step `.failed` :
  réutiliser le pipeline évite un second chemin à maintenir et hérite de `waitWhileRecording`.
- **Reconnexion par AppleScript** (choix utilisateur) plutôt que par script `.command`, ce dernier
  restant le repli quand l'autorisation Automation manque.
