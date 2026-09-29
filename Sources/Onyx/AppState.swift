import Foundation
import AppKit
import SwiftUI
import Combine
import RecorderCore

@MainActor
public final class AppState: ObservableObject {
    public enum UIState { case idle, recording, transcribing }
    /// Émise par le `ClaudeAuthMonitor` à chaque *transition* de statut — donc
    /// une seule fois par déconnexion, pas une par réunion en échec.
    ///
    /// `nonisolated` : `AppState` est `@MainActor`, donc ce membre statique
    /// l'est aussi par défaut, et le handler du monitor qui le lit est une
    /// closure `@Sendable` appelée hors du main actor. Un simple nom de
    /// notification est immuable et sûr à lire de partout.
    public nonisolated static let claudeAuthDidChange =
        Notification.Name("onyx.claudeAuthDidChange")
    @Published public var uiState: UIState = .idle
    /// Slug of the recording in flight, mirrored from `Recorder.paths` (the only
    /// authoritative source — see `refreshCurrentSlug`). `nil` when idle.
    ///
    /// Kept as a published mirror purely so the menu bar can show it inside a
    /// SwiftUI body; anything that must not be wrong reads
    /// `activeRecordingSlug()` instead.
    @Published public var currentSlug: String?
    @Published public var lastError: String?
    /// État d'authentification du CLI `claude`, miroir du `ClaudeAuthMonitor`
    /// pour que les vues SwiftUI (bannière, menu, réglages) puissent le lire.
    @Published public var claudeAuthStatus: ClaudeAuthStatus = .unknown
    /// Progression du rattrapage des notes perdues : (fait, total). `nil` quand
    /// aucun rattrapage n'est en cours.
    @Published public var notesCatchUpProgress: (done: Int, total: Int)?
    /// Posé de façon synchrone, avant toute suspension : `notesCatchUpProgress`
    /// n'est écrit qu'après la découverte des slugs, donc s'en servir comme
    /// garde laisserait passer deux déclenchements arrivés dans le même tour
    /// de boucle (lancement + transition « reconnecté »).
    private var catchUpInFlight = false

    public let settings = SettingsStore()
    public let storage: MeetingStorage
    public let indexer: MeetingIndexer
    public let calendarWatcher: CalendarWatcher
    /// Single instance of the viewer window (chantier 3).
    public let viewerController: ViewerWindowController
    /// The viewer's store, kept here so recording/pipeline events can be
    /// pushed into the UI in real time (live sidebar, status badges).
    public let viewerStore: ViewerStore
    private let recorder: Recorder
    private let pipeline: Pipeline
    public let claudeAuthMonitor: ClaudeAuthMonitor
    /// One Whisper instance for the whole app: the live chunker and the
    /// pipeline share it, so the model is loaded once per recording session
    /// and stays resident across chunks AND the post-stop pipeline. Released
    /// via `unloadWhisperIfIdle()` when nothing needs it anymore (~3-4 GB).
    private let sharedWhisper: WhisperTranscriber
    private let detectionCoordinator: DetectionCoordinator
    private let orchestrator: AutoTriggerOrchestrator
    /// Single settings window. Owned here (like `viewerController`) because the
    /// SwiftUI `Settings` scene's opener relied on the private
    /// `showSettingsWindow:` selector, which recent macOS releases dropped —
    /// clicking "Settings…" did nothing.
    private var settingsWindow: NSWindow?
    private var settingsCloseDelegate: SettingsWindowDelegate?
    private var cancellables: Set<AnyCancellable> = []

    public init() {
        storage = MeetingStorage(root: settings.meetingsFolder)
        sharedWhisper = WhisperTranscriber(
            model: ModelManifest.whisperAsset(id: settings.whisperModel))
        let dbURL = FileManager.default.urls(for: .applicationSupportDirectory,
                                             in: .userDomainMask)[0]
            .appendingPathComponent("Onyx/index.sqlite")
        try? FileManager.default.createDirectory(at: dbURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        do {
            indexer = try MeetingIndexer(dbPath: dbURL)
        } catch {
            // H13: If the DB is corrupt, delete it and retry with a fresh one.
            Log.pipeline.error("MeetingIndexer init failed: \(error). Deleting corrupt DB and retrying.")
            try? FileManager.default.removeItem(at: dbURL)
            if let fresh = try? MeetingIndexer(dbPath: dbURL) {
                indexer = fresh
            } else {
                // Last resort: fall back to a transient in-memory index so the
                // app keeps running (meetings won't be searchable this session).
                // try! is safe here: DatabaseQueue() with no path is pure in-memory.
                indexer = try! MeetingIndexer.inMemory()
            }
        }
        // Viewer window (chantier 3). Bind to a local first: capturing
        // `settings` directly in the closure inside init() can trigger "self
        // used before all stored properties are initialized".
        let settingsLocal = settings
        let vStore = ViewerStore(storage: storage, indexer: indexer,
                                 claudeBinary: {
            settingsLocal.claudeBinaryPath.isEmpty
                ? nil : URL(fileURLWithPath: settingsLocal.claudeBinaryPath)
        },
                                 claudeModel: {
            settingsLocal.claudeModel.isEmpty ? nil : settingsLocal.claudeModel
        })
        viewerStore = vStore
        viewerController = ViewerWindowController(store: vStore)
        vStore.refreshMeetings()

        // Viewer state (selection, note level, split ratio) is persisted through
        // a 500 ms debounce. "Quit Onyx" calls NSApplication.terminate directly,
        // so without this a change made in the last half-second before quitting
        // is silently dropped. `flushState()` is nonisolated and synchronous,
        // which is what makes it usable from a terminate hook (there is nothing
        // left to await by then).
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main
        ) { _ in vStore.flushState() }

        recorder = Recorder(storage: storage)

        // Même dossier que index.sqlite — c'est là que vit l'état applicatif
        // qui n'appartient à aucune réunion.
        let authStateURL = FileManager.default.urls(for: .applicationSupportDirectory,
                                                    in: .userDomainMask)[0]
            .appendingPathComponent("Onyx/claude-auth.json")
        // Le handler ne peut pas capturer `self` (pas encore initialisé) : il
        // passe par NotificationCenter, et `init` s'y abonne juste après.
        claudeAuthMonitor = ClaudeAuthMonitor(stateFile: authStateURL) { status in
            NotificationCenter.default.post(name: AppState.claudeAuthDidChange,
                                            object: nil,
                                            userInfo: ["status": status])
        }

        // Build pipeline with optional notes config. `whisper` is the shared
        // resident instance — see `sharedWhisper`.
        pipeline = Pipeline(storage: storage, whisper: sharedWhisper,
                            notes: Self.notesConfig(from: settings,
                                                     authMonitor: claudeAuthMonitor))

        calendarWatcher = CalendarWatcher()

        var detectors: [any MeetingAppDetector] = []
        if settings.detectionMeetEnabled { detectors.append(MeetDetector()) }
        if settings.detectionHuddleEnabled { detectors.append(SlackHuddleDetector()) }
        detectionCoordinator = DetectionCoordinator(detectors: detectors)

        let session = RecorderSession(recorder: recorder, storage: storage, pipeline: pipeline)
        // Live chunked transcription (Settings → Advanced). Read at each
        // recording start, so toggling/resizing applies to the next one.
        let whisperLocal = sharedWhisper
        session.chunkingConfig = { @Sendable in
            guard settingsLocal.chunkedTranscriptionEnabled else { return nil }
            return RecorderSession.ChunkingConfig(
                chunkSeconds: Double(settingsLocal.chunkMinutes) * 60,
                whisper: whisperLocal)
        }
        // Chunk-by-chunk transcription progress → sidebar badge percentage.
        let vStoreForProgress = vStore
        session.onTranscriptionProgress = { slug, fraction in
            Task { @MainActor in
                vStoreForProgress.pipelineProgress[slug] = fraction
            }
        }
        orchestrator = AutoTriggerOrchestrator(session: session)

        // Bridge pipeline completion back to the UI: without this the .transcribing
        // state was never observed (see toggleRecording) and pipeline failures were
        // swallowed silently. Wired AFTER `orchestrator` init so `self` is fully
        // initialized and can be captured weakly.
        session.onPipelineFinished = { [weak self] slug, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.uiState == .transcribing { self.uiState = .idle }
                if let error {
                    self.lastError = "Pipeline failed (\(slug)): \(String(describing: error))"
                    OptOutNotificationCenter.shared.showNotesFailed(slug: slug)
                }
                // Real-time sidebar: index this one meeting NOW. Before this,
                // a finished meeting only appeared after the next full rescan
                // — i.e. an app restart or a manual "Rescan meetings".
                let storage = self.storage
                let indexer = self.indexer
                let vStore = self.viewerStore
                Task.detached(priority: .userInitiated) {
                    let runner = RescanRunner(storage: storage, indexer: indexer)
                    runner.reindex(slug: slug)
                    // A continuation segment rewrote its parent's transcript
                    // and notes (absorb step) — the parent's row is stale too.
                    let paths = MeetingPaths(root: storage.root, slug: slug)
                    if let meta = try? storage.loadMetadata(paths),
                       let parent = meta.continuationOf {
                        runner.reindex(slug: parent)
                    }
                    await MainActor.run { vStore.refreshMeetings() }
                }
                self.unloadWhisperIfIdle()
            }
        }

        // Live pipeline status → viewer. Each overall-state transition
        // (transcribing, diarizing, generating notes, done/failed) is pushed
        // into the store, which drives the sidebar badge and, on .done,
        // reloads the meeting the user is looking at.
        let vStoreForPipeline = vStore
        let pipelineForObserver = pipeline
        Task {
            await pipelineForObserver.setStateObserver { slug, state in
                Task { @MainActor in
                    vStoreForPipeline.setPipelineState(slug: slug, state: state)
                }
            }
        }

        // H1: Wire orchestrator state transitions to the UI so that
        // auto-triggered recordings (calendar, detection) update the menu bar
        // icon, not just manual recordings from toggleRecording().
        let uiOrch = orchestrator
        // Recording gate: a live recording must never compete with
        // post-processing for CPU/ANE (whisper + diarization jobs running
        // during back-to-back calls caused CoreML timeouts and false
        // detector-driven stops). `.stopping` keeps the gate closed — only a
        // full return to `.idle` reopens it. The flips must reach the
        // pipeline in transition order — one unstructured Task per flip has
        // no FIFO guarantee (a reordered pair could leave the gate stuck
        // closed while idle, or open during a recording) — so the handler
        // yields into a stream drained by a single consumer loop, same
        // pattern as the calendar/detection loops in bootAutotrigger().
        var gateCont: AsyncStream<Bool>.Continuation!
        let gateStream = AsyncStream<Bool> { gateCont = $0 }
        let gateFlips = gateCont!
        let gatePipeline = pipeline
        let gateWhisper = sharedWhisper
        Task.detached {
            for await active in gateStream {
                await gatePipeline.setRecordingActive(active)
                // Same flag on the transcriber: disables the ANE-timeout
                // CPU+GPU fallback while recording (it would load a second
                // multi-GB model on an already saturated machine). Flipped
                // in the SAME consumer to keep transition ordering.
                await gateWhisper.setRecordingActive(active)
            }
        }
        Task {
            await uiOrch.setTransitionHandler { [weak self] newState in
                switch newState {
                case .starting, .recording:
                    gateFlips.yield(true)
                case .idle:
                    gateFlips.yield(false)
                case .stopping:
                    break
                }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    switch newState {
                    case .idle:
                        if self.uiState != .idle { self.uiState = .idle }
                        self.currentSlug = nil
                        // A cancelled recording leaves no meeting behind:
                        // drop its "Enregistrement…" badge (the pipeline
                        // overwrites it on a normal stop) and refresh so the
                        // synthesized sidebar row disappears too.
                        self.viewerStore.pipelineStates = self.viewerStore
                            .pipelineStates.filter { $0.value != .recording }
                        self.viewerStore.refreshMeetings()
                    case .starting:
                        self.uiState = .recording
                        // No slug yet: `.starting` is claimed *before*
                        // `session.start()`, so the folder does not exist.
                    case .recording(_, let meta):
                        self.uiState = .recording
                        self.refreshCurrentSlug()
                        // Temps réel : la session apparaît immédiatement dans
                        // la sidebar avec son badge "Enregistrement…", et le
                        // viewer s'ouvre sur l'onglet Direct pour la prise de
                        // notes pendant la réunion — quel que soit le
                        // déclencheur (manuel, calendrier, Meet/Huddle).
                        self.viewerStore.setPipelineState(slug: meta.id,
                                                          state: .recording)
                        self.viewerStore.refreshMeetings()
                        self.viewerController.focusLiveNotes(slug: meta.id)
                    case .stopping:
                        self.uiState = .transcribing
                        self.currentSlug = nil
                    }
                }
            }
        }

        // Wire opt-out notification.
        let localOrch = orchestrator
        OptOutNotificationCenter.shared.optOutHandler = {
            try? await localOrch.optOut()
        }
        OptOutNotificationCenter.shared.configureIfNeeded()

        // Route the WAV size-cap event (a writer refused samples because the
        // data chunk would overflow UInt32) through the orchestrator so its
        // state stays coherent with the recorder's. Without this the app
        // would silently keep "recording" forever while the writer drops
        // every buffer.
        let capOrch = orchestrator
        let capRecorder = recorder
        Task {
            await capRecorder.setSizeCapHandler {
                Task { @MainActor in
                    try? await capOrch.manualStop()
                }
            }
        }

        // Boot auto-trigger loops AND pick up any incomplete meetings eagerly
        // at app launch — do NOT wait for the MenuBarExtra content view to
        // first appear (which only happens when the user clicks the menu bar
        // icon; if the icon is hidden in the menu bar overflow, the callbacks
        // would never fire).
        bootAutotrigger()
        bootClaudeAuth()
        resumePendingJobs()
        backfillIndexIfStale()

        // Sync the login-item registration with the setting. Done here and not
        // in SettingsStore.init: only the real app may register itself (see
        // `launchAtLogin` in SettingsStore).
        SettingsStore.applyLaunchAtLogin(settings.launchAtLogin)

        // Diagnostic: dump EK calendar list at boot for the E2E harness to
        // cross-check the whitelist UID. Written to Meetings/.onyx-diag.json.
        dumpDiagnosticInfo()

        // Hot-reload the pipeline's notes config whenever a notes-related
        // setting changes. `reloadNotesConfig()` existed but nothing called
        // it, so Settings edits only took effect after an app restart.
        Publishers.CombineLatest4(settings.$claudeBinaryPath, settings.$autoNotesEnabled,
                                  settings.$defaultNoteLevels, settings.$claudeModel)
            .dropFirst()   // init-time replay: the pipeline was just built from these
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.reloadNotesConfig() }
            .store(in: &cancellables)

        // Whisper variant switch: applies to the very next transcription (the
        // resident model is dropped if the variant actually changed).
        let whisperForModel = sharedWhisper
        settings.$whisperModel
            .dropFirst()
            .removeDuplicates()
            .sink { id in
                Task { await whisperForModel.setModel(ModelManifest.whisperAsset(id: id)) }
            }
            .store(in: &cancellables)

        // Apply the persisted theme once NSApp is fully up (AppState is built
        // during App.init, where NSApp.appearance assignment is not reliable).
        let settingsForAppearance = settings
        DispatchQueue.main.async { settingsForAppearance.applyAppearance() }

        // Dock icon lifecycle: the app is LSUIElement (no Dock icon while it
        // is just a menu-bar item), but as soon as a real window opens it must
        // behave like a normal app — Dock icon, ⌘⇥. The viewer reports every
        // visibility change; the settings window does the same via its close
        // delegate in `showSettings()`.
        viewerController.onVisibilityChanged = { [weak self] in
            self?.refreshDockIcon()
        }

        // Sidebar recording controls ("+" to start an ad-hoc session, stop on
        // the live row). Both funnel through toggleRecording(), i.e. the same
        // orchestrator paths as the menu bar and ⌘⇧R — with a state guard so
        // a stale click can never invert the intended action.
        vStore.onStartRecording = { [weak self] in
            guard let self, self.uiState != .recording else { return }
            self.toggleRecording()
        }
        vStore.onStopRecording = { [weak self] in
            guard let self, self.uiState == .recording else { return }
            self.toggleRecording()
        }

        NotificationCenter.default.publisher(for: AppState.claudeAuthDidChange)
            .compactMap { $0.userInfo?["status"] as? ClaudeAuthStatus }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in self?.applyClaudeAuthStatus(status) }
            .store(in: &cancellables)

        // Affecté en tout dernier : le viewer n'a pas besoin d'AppState avant
        // d'être ouvert, et à ce stade toutes les propriétés stockées le sont.
        viewerController.app = self
    }

    /// Releases the resident Whisper model (~3-4 GB) once nothing needs it:
    /// no recording in progress and no pipeline still running. The next
    /// recording (or pipeline resume) reloads it transparently.
    private func unloadWhisperIfIdle() {
        guard uiState == .idle else { return }
        let busy = viewerStore.pipelineStates.values.contains { $0 != .failed }
        guard !busy else { return }
        let whisper = sharedWhisper
        Task { await whisper.unload() }
    }

    /// `.regular` (Dock icon + ⌘⇥) while any Onyx window is open or minimised,
    /// `.accessory` (menu-bar only) otherwise. Centralised so the viewer and
    /// settings windows can never disagree about the policy.
    public func refreshDockIcon() {
        let settingsPresent = (settingsWindow?.isVisible ?? false)
            || (settingsWindow?.isMiniaturized ?? false)
        let anyWindow = viewerController.isWindowPresent || settingsPresent
        let target: NSApplication.ActivationPolicy = anyWindow ? .regular : .accessory
        guard NSApp.activationPolicy() != target else { return }
        NSApp.setActivationPolicy(target)
        if anyWindow { NSApp.activate(ignoringOtherApps: true) }
    }

    // MARK: - Settings window

    /// Shows the settings window, creating it on first use — same
    /// create-once-then-reuse pattern as `ViewerWindowController`.
    public func showSettings() {
        defer { refreshDockIcon() }
        if let w = settingsWindow {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let host = NSHostingController(rootView: SettingsWindow(
            settings: settings, app: self, storage: storage, indexer: indexer))
        let w = NSWindow(contentViewController: host)
        w.title = "Onyx — Settings"
        w.styleMask = [.titled, .closable]
        // Hidden, not destroyed, on close: `isReleasedWhenClosed = false` keeps
        // `settingsWindow` a valid reference so the next click just reopens it.
        w.isReleasedWhenClosed = false
        // The Dock icon must drop back to menu-bar-only when the last window
        // goes away; the delegate reports the close. (Weakly referenced by the
        // window, hence retained in `settingsCloseDelegate`.)
        let delegate = SettingsWindowDelegate { [weak self] in
            self?.refreshDockIcon()
        }
        settingsCloseDelegate = delegate
        w.delegate = delegate
        w.center()
        settingsWindow = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The index migrations (v2 FTS rebuild, v3 `source`/`detected_app` columns)
    /// invalidate existing rows by nulling `indexed_at`. Nothing else repopulates
    /// them, so without this an upgrading user's search silently returns zero
    /// results until they happen to find "Rescan meetings" in the menu.
    /// `onlyStale: true` visits just the invalidated rows, so this is a no-op on
    /// an already-current index.
    private func backfillIndexIfStale() {
        let storage = self.storage
        let indexer = self.indexer
        Task.detached(priority: .utility) {
            let runner = RescanRunner(storage: storage, indexer: indexer)
            guard (try? runner.needsRescan()) == true else { return }
            Log.pipeline.info("Index is stale after migration — backfilling")
            try? await runner.rescan(onlyStale: true)
        }
    }

    /// Writes ~/Meetings/.onyx-diag.json with the EK calendar list + settings.
    /// Called at boot for E2E diagnostics.
    private func dumpDiagnosticInfo() {
        Task.detached { [weak self] in
            guard let self else { return }
            let watcher = await self.calendarWatcher
            let root = await self.storage.root
            let enabled = await self.settings.enabledCalendarIds
            let cals = watcher.availableCalendars()
            let entries: [[String: String]] = cals.map { c in
                [
                    "identifier": c.calendarIdentifier,
                    "title": c.title,
                    "type": String(c.type.rawValue),
                    "whitelisted": enabled.contains(c.calendarIdentifier) ? "true" : "false",
                    "allowsContentModifications": c.allowsContentModifications ? "true" : "false",
                ]
            }
            let payload: [String: Any] = [
                "calendars": entries,
                "whitelistedIds": enabled,
                "autoTriggerEnabled": await self.settings.autoTriggerEnabled,
                "autoNotesEnabled": await self.settings.autoNotesEnabled,
                "claudeBinaryPath": await self.settings.claudeBinaryPath,
            ]
            try? FileManager.default.createDirectory(at: root,
                                                    withIntermediateDirectories: true)
            let out = root.appendingPathComponent(".onyx-diag.json")
            if let data = try? JSONSerialization.data(withJSONObject: payload,
                                                      options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: out, options: .atomic)
            }
        }
    }

    // MARK: - Active recording identity

    /// The slug of the recording currently in flight, or `nil` if none.
    ///
    /// `Recorder.paths` is the authoritative source and the *only* correct one:
    /// the on-disk slug is minted by `MeetingStorage.createMeeting`, which
    /// appends a `_2`/`_3` suffix on a same-minute collision. The orchestrator's
    /// `State.recording(meta:)` carries its own `meta.id` computed from the clock
    /// **before** the folder is created, so it can disagree with the directory
    /// that actually holds `notes/live.md`. All three trigger paths (manual,
    /// calendar, detection) funnel through `AutoTriggerOrchestrator` →
    /// `RecorderSession.start` → `recorder.start()`, so this covers all of them;
    /// `Recorder` nils `paths` out in both `stop()` and `cancel()`, so a stale
    /// slug cannot survive the end of a recording.
    public func activeRecordingSlug() async -> String? {
        await recorder.paths?.slug
    }

    private func refreshCurrentSlug() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.currentSlug = await self.activeRecordingSlug()
        }
    }

    /// ⌘⇧L. Opens the viewer on the **in-progress** meeting's `notes/live.md`.
    ///
    /// The slug is resolved here and passed down explicitly: the viewer cannot
    /// infer it (nothing indexes a meeting until its pipeline has finished, so
    /// the in-progress meeting is absent from `ViewerStore.meetings`), and
    /// guessing would point the editor at an unrelated meeting whose live notes
    /// the next keystroke would destroy.
    public func openLiveNotes() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let slug = await self.activeRecordingSlug()
            self.currentSlug = slug
            if !self.viewerController.focusLiveNotes(slug: slug) {
                self.lastError = "No recording in progress — there are no live notes to open."
            }
        }
    }

    public func toggleRecording() {
        Task {
            do {
                switch uiState {
                case .idle:
                    try await orchestrator.manualStart()
                    uiState = .recording
                case .recording:
                    try await orchestrator.manualStop()
                    // Stay in .transcribing until RecorderSession.onPipelineFinished
                    // fires and flips us back to .idle. This preserves the yellow
                    // hourglass in the menu bar and the "Transcribing…" label.
                    uiState = .transcribing
                case .transcribing:
                    try await orchestrator.manualStart()
                    uiState = .recording
                }
            } catch {
                lastError = String(describing: error)
                uiState = .idle
            }
        }
    }

    public func bootAutotrigger() {
        guard settings.autoTriggerEnabled else { return }

        let orch = orchestrator
        let watcher = calendarWatcher
        let coordinator = detectionCoordinator
        let enabledIds = settings.enabledCalendarIds

        // Calendar loop.
        Task.detached {
            let matcher = CalendarMatcher(whitelistedCalendarIds: enabledIds)
            for await match in watcher.matches(matcher: matcher) {
                await MainActor.run {
                    OptOutNotificationCenter.shared.showRecordingStarted(title: match.title)
                }
                try? await orch.onCalendarEvent(match)
            }
        }

        // Detection loop.
        Task.detached {
            for await ev in coordinator.events() {
                if ev.kind == .started {
                    await MainActor.run {
                        OptOutNotificationCenter.shared.showRecordingStarted(title: "Meet/Huddle detected")
                    }
                }
                try? await orch.onCallEvent(ev)
            }
        }
    }

    /// Applique une transition de statut : met à jour l'UI, notifie une seule
    /// fois en cas de déconnexion, lance le rattrapage en cas de reconnexion.
    private func applyClaudeAuthStatus(_ status: ClaudeAuthStatus) {
        let wasDisconnected = claudeAuthStatus.isDisconnected
        claudeAuthStatus = status
        switch status {
        case .disconnected(let failure, _):
            OptOutNotificationCenter.shared.showClaudeDisconnected(failure)
        case .connected:
            // Rattrapage seulement au retour d'une déconnexion : au démarrage
            // normal, `bootClaudeAuth` s'en charge séparément.
            if wasDisconnected { catchUpNotes() }
        case .unknown:
            break
        }
    }

    /// Lit le statut persisté au lancement et rattrape ce qui traîne. Appelé
    /// depuis `App.swift` au même endroit que `bootAutotrigger()`.
    public func bootClaudeAuth() {
        let monitor = claudeAuthMonitor
        Task {
            let status = await monitor.status
            self.claudeAuthStatus = status
            if !status.isDisconnected { self.catchUpNotes() }
        }
    }

    /// Sonde explicite (bouton « Tester » des réglages / de la bannière).
    /// - Returns: un message affichable, décrivant le résultat.
    public func checkClaudeAuth() async -> String {
        let path = settings.claudeBinaryPath
        guard !path.isEmpty else { return "Chemin du binaire Claude non configuré." }
        let binary = URL(fileURLWithPath: path)
        guard FileManager.default.isExecutableFile(atPath: path) else {
            return "Le binaire est introuvable ou non exécutable : \(path)"
        }
        let model = settings.claudeModel.isEmpty ? nil : settings.claudeModel
        let outcome = await claudeAuthMonitor.probe(binary: binary, model: model)
        // Le monitor a déjà appliqué (ou non) la transition ; on resynchronise
        // l'état publié pour le cas `inconclusive`, qui ne déclenche rien.
        claudeAuthStatus = await claudeAuthMonitor.status
        switch outcome {
        case .connected:
            return "Connecté — Claude a répondu."
        case .disconnected(let failure):
            return failure == .sessionExpired
                ? "Session expirée : reconnecte-toi."
                : "Non connecté : reconnecte-toi."
        case .inconclusive(let why):
            return "Vérification impossible : \(why)"
        }
    }

    /// Régénère séquentiellement les notes des réunions perdues pendant une
    /// déconnexion.
    ///
    /// Passe par `pipeline.run` plutôt que par un chemin de génération dédié :
    /// tous les autres steps étant `.done`, seule l'étape `.notes` s'exécute, et
    /// on hérite gratuitement du `waitWhileRecording` du pipeline — donc aucune
    /// rafale d'appels `claude` pendant une réunion (charge ANE).
    public func catchUpNotes() {
        // Posé de façon synchrone, avant toute suspension : `notesCatchUpProgress`
        // n'est écrit qu'après la découverte des slugs, donc s'en servir comme
        // garde laisserait passer deux déclenchements arrivés dans le même tour
        // de boucle (lancement + transition « reconnecté »).
        guard !catchUpInFlight else { return } // déjà en cours
        catchUpInFlight = true
        let storage = self.storage
        let root = storage.root
        let pipeline = self.pipeline
        let indexer = self.indexer
        let monitor = self.claudeAuthMonitor
        Task {
            // `catchUpInFlight` doit être relâché sur toute sortie, y compris le
            // retour anticipé "aucune réunion en retard" ci-dessous — l'ordre de
            // ce `defer` (posé avant le retour anticipé) est ce qui garantit ça.
            defer { self.catchUpInFlight = false }
            // Découverte hors du main actor : `pendingSlugs` fait une lecture
            // de `job.json` par réunion (~90 aujourd'hui), en synchrone. La
            // laisser sur le main actor gèlerait l'UI au lancement — le
            // `Task {}` d'une classe `@MainActor` hérite du main actor, il ne
            // change pas de contexte tout seul.
            let slugs = await Task.detached {
                (try? NotesCatchUp.pendingSlugs(storage: MeetingStorage(root: root))) ?? []
            }.value
            guard !slugs.isEmpty else { return }
            Log.ui.info("Notes catch-up: \(slugs.count, privacy: .public) meeting(s)")
            self.notesCatchUpProgress = (done: 0, total: slugs.count)
            defer { self.notesCatchUpProgress = nil }
            let runner = RescanRunner(storage: storage, indexer: indexer)
            for (i, slug) in slugs.enumerated() {
                // Une nouvelle déconnexion en cours de route arrête tout :
                // enchaîner des appels condamnés n'aide personne.
                if await monitor.status.isDisconnected {
                    Log.ui.info("Notes catch-up aborted — Claude disconnected again")
                    break
                }
                let paths = MeetingPaths(root: storage.root, slug: slug)
                try? await pipeline.run(paths: paths)
                runner.reindex(slug: slug)
                self.notesCatchUpProgress = (done: i + 1, total: slugs.count)
            }
        }
    }

    public func regenerateNotes(for slug: String, level: NoteLevel) {
        // `.live` is the user's own notes/live.md — never a generation target.
        // Refuse here too so the user gets a meaningful message instead of a
        // generic "Regenerate failed: liveIsNotGeneratable".
        guard level != .live else {
            lastError = "Live notes are yours — they can't be regenerated."
            return
        }
        Task {
            let path = settings.claudeBinaryPath
            guard !path.isEmpty else {
                self.lastError = "Claude binary path not configured"
                return
            }
            let binary = URL(fileURLWithPath: path)
            let paths = MeetingPaths(root: storage.root, slug: slug)
            let gen = ClaudeNoteGenerator()
            do {
                try await gen.generate(paths: paths, level: level, binary: binary,
                                       model: settings.claudeModel.isEmpty
                                              ? nil : settings.claudeModel)
            } catch {
                self.lastError = "Regenerate failed: \(String(describing: error))"
                OptOutNotificationCenter.shared.showNotesFailed(slug: slug)
            }
        }
    }

    /// Notes config derived from settings — shared by the pipeline's initial
    /// construction and every hot-reload so the two can never disagree.
    private static func notesConfig(from settings: SettingsStore,
                                    authMonitor: ClaudeAuthMonitor?)
        -> NoteGenerationConfig? {
        let binaryURL: URL? = settings.claudeBinaryPath.isEmpty
            ? nil : URL(fileURLWithPath: settings.claudeBinaryPath)
        // A stale/hand-edited "live" preference must never become a pipeline
        // generation target (SettingsStore already filters, belt-and-braces).
        let levels = settings.defaultNoteLevels.filter { $0 != .live }
        guard settings.autoNotesEnabled, binaryURL != nil, !levels.isEmpty else { return nil }
        return NoteGenerationConfig(binary: binaryURL, levels: levels,
                                    model: settings.claudeModel.isEmpty
                                           ? nil : settings.claudeModel,
                                    authMonitor: authMonitor)
    }

    /// Rebuilds the notes config from current settings and hot-reloads it into
    /// the pipeline, so new recordings pick up the updated configuration.
    /// Driven automatically by the Combine subscription in `init` — it had a
    /// manual-call contract before, and the call site simply didn't exist, so
    /// changing any notes setting silently did nothing until app restart.
    public func reloadNotesConfig() {
        let cfg = Self.notesConfig(from: settings, authMonitor: claudeAuthMonitor)
        let pipeline = self.pipeline
        Task { await pipeline.setNotesConfig(cfg) }
    }

    public func resumePendingJobs() {
        let storage = self.storage
        let pipeline = self.pipeline
        Task {
            let listings = (try? storage.listMeetings()) ?? []
            // Chronological order (the slug is date-formatted): a continuation
            // segment's absorb step waits for its parent's pipeline, and this
            // loop is sequential — resuming the child first would stall it
            // behind a parent that never gets its turn.
            let indexer = self.indexer
            let vStore = self.viewerStore
            for listing in listings.sorted(by: { $0.slug < $1.slug }) {
                let paths = MeetingPaths(root: storage.root, slug: listing.slug)
                guard let job = try? storage.loadJob(paths), job.isResumable else { continue }
                try? await pipeline.run(paths: paths)
                // Same post-pipeline refresh as onPipelineFinished. This path
                // (kill/crash mid-pipeline, resume at boot) used to skip it, so
                // the meeting's index row — written while it was still
                // in_progress — kept saying "waiting for transcription" with an
                // empty title forever.
                let runner = RescanRunner(storage: storage, indexer: indexer)
                runner.reindex(slug: listing.slug)
                if let meta = try? storage.loadMetadata(paths),
                   let parent = meta.continuationOf {
                    runner.reindex(slug: parent)
                }
                await MainActor.run { vStore.refreshMeetings() }
            }
        }
    }
}

/// Reports settings-window visibility transitions to `refreshDockIcon()`.
/// The refresh is dispatched async on purpose: `windowWillClose` fires while
/// `isVisible` is still true, so recomputing synchronously would conclude a
/// window is open and keep the Dock icon alive forever.
private final class SettingsWindowDelegate: NSObject, NSWindowDelegate {
    private let onVisibilityChanged: () -> Void
    init(onVisibilityChanged: @escaping () -> Void) {
        self.onVisibilityChanged = onVisibilityChanged
        super.init()
    }
    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { self.onVisibilityChanged() }
    }
    func windowDidMiniaturize(_ notification: Notification) {
        onVisibilityChanged()
    }
    func windowDidDeminiaturize(_ notification: Notification) {
        onVisibilityChanged()
    }
}
