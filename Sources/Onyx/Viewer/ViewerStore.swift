import Foundation
import Combine
import RecorderCore

/// Single source of truth for the viewer window. Uses `ObservableObject` for
/// broad macOS-13 compatibility (rather than `@Observable`, which is macOS 14+).
@MainActor
public final class ViewerStore: ObservableObject {
    // Selection + navigation
    @Published public var selectedMeetingId: String?
    @Published public var activeNoteLevel: NoteLevel = .synthese
    @Published public var searchQuery: String = ""
    @Published public var searchResults: [SearchHit] = []
    /// Meetings whose generated notes have been opened at least once. A meeting
    /// is only added once its `notes/synthese.md` exists, so a meeting first
    /// visited *during* recording (no notes yet) still gets the automatic
    /// switch to Synthèse on its first post-generation open.
    @Published public private(set) var openedNoteMeetingIds: Set<String> = []

    // Layout
    @Published public var notesToTranscriptRatio: Double = 0.6
    @Published public var transcriptPanelHidden: Bool = false
    /// Notes area display mode: false = Markdown source (editable), true =
    /// rendered preview (read-only). Session-scoped, shared across tabs and
    /// meetings — a reading mode, not a per-note property.
    @Published public var notesPreviewMode: Bool = false

    // Data
    @Published public var meetings: [MeetingListing] = []
    @Published public var currentTranscript: [TranscriptSegment] = []
    @Published public var currentNotes: String = ""
    @Published public var currentLiveNotes: String = ""
    @Published public var notesEditedSinceGeneration: Bool = false
    /// Duration of the selected meeting, read from `meta.json` when it is
    /// selected. Published rather than read on demand because the header needs
    /// it inside a SwiftUI body, and a `loadMetadata` call there would do file
    /// IO on every single render pass.
    @Published public var currentDurationSeconds: Int?
    /// Listing for the selected meeting — the index row when there is one, else
    /// one synthesized from `meta.json` (see `resolveListing`). Published rather
    /// than computed in a view body for the same reason as
    /// `currentDurationSeconds`: resolving the fallback does file IO.
    @Published public var currentListing: MeetingListing?
    /// Peak array for the scrubber. Empty when the meeting has no waveform and
    /// none can be derived — the scrubber then shows an empty track rather than
    /// disappearing.
    @Published public var currentWaveform: [Float] = []
    /// Live per-meeting status, pushed by AppState from the pipeline's state
    /// observer (and set to `.recording` while recording). This is what makes
    /// the sidebar badge say "Transcription…" / "Génération des notes…" in
    /// real time. Slugs absent from the dict are simply not being processed.
    @Published public var pipelineStates: [String: JobOverallState] = [:]
    /// Transcription progress per slug (0…1), pushed by the chunker after
    /// each chunk. Absent for the full-file fallback (no measurable position)
    /// — the badge then shows the plain label.
    @Published public var pipelineProgress: [String: Double] = [:]
    /// When each slug entered its current pipeline state — the basis of the
    /// notes step's *estimated* percentage (a single `claude -p` call reports
    /// no progress, so elapsed-over-typical-duration is the honest best).
    private var stateStartedAt: [String: Date] = [:]
    /// 1 Hz tick while a notes generation is running, so its estimated
    /// percentage advances on screen without any pipeline event.
    private var progressTicker: AnyCancellable?

    // Recording controls, wired by AppState (the store cannot reach the
    // orchestrator itself — the dependency points the other way). Nil in
    // tests and previews: the corresponding buttons then do nothing.
    /// Start an ad-hoc recording (the sidebar's "+" button): not tied to any
    /// Meet/Huddle/calendar event — a free note-taking session around a table.
    public var onStartRecording: (() -> Void)?
    /// Stop the recording in progress (the sidebar row's stop button).
    public var onStopRecording: (() -> Void)?
    /// True while some meeting is being recorded — drives the "+" button's
    /// disabled state and the row-level stop affordance.
    public var isRecordingActive: Bool {
        pipelineStates.values.contains(.recording)
    }

    // Generation feedback.
    //
    // Both exist because their absence was a real bug: `regenerateActiveNote`
    // used to return silently on a nil binary and swallow every error in an
    // empty catch, so when the `claude` binary moved during a Claude Code
    // update, every "Générer" button in the viewer looked dead — no spinner,
    // no message, nothing in the logs.
    //
    // Keyed by (meeting, level) rather than a single global flag so each note
    // level is an independent generation session: launching "brief" must not
    // grey out the "synthèse" and "détaillée" buttons, and up to three
    // `claude -p` subprocesses can run in parallel (they write disjoint files,
    // `notes/<level>.md`, so they cannot race each other).
    /// One `claude -p` generation key per (meeting, level).
    public struct NoteGenerationKey: Hashable {
        public let meetingId: String
        public let level: NoteLevel
    }
    /// Keys of the generation subprocesses currently running. Drives each
    /// tab's disabled state and in-progress indicator independently.
    @Published public private(set) var generatingNotes: Set<NoteGenerationKey> = []
    /// Human-readable reason the last generation attempt failed, per key.
    /// Scoped to its own (meeting, level): the error shows only on the tab it
    /// belongs to, so it can never linger over another note's tab.
    @Published public var generationErrors: [NoteGenerationKey: String] = [:]

    /// True while a generation is running for the *visible* (meeting, level).
    /// Convenience over `generatingNotes` for the views and tests.
    public var isGeneratingNote: Bool {
        guard let key = activeGenerationKey else { return false }
        return generatingNotes.contains(key)
    }
    /// Error of the *visible* (meeting, level), if any. Setting `nil` (the
    /// status bar's "OK" button) dismisses that tab's error only.
    public var generationError: String? {
        get {
            guard let key = activeGenerationKey else { return nil }
            return generationErrors[key]
        }
        set {
            guard let key = activeGenerationKey else { return }
            generationErrors[key] = newValue
        }
    }
    private var activeGenerationKey: NoteGenerationKey? {
        guard let id = selectedMeetingId else { return nil }
        return NoteGenerationKey(meetingId: id, level: activeNoteLevel)
    }
    /// Whether `level` is generating for the selected meeting — lets the tab
    /// strip show a spinner on backgrounded generations, not just the visible one.
    public func isGenerating(level: NoteLevel) -> Bool {
        guard let id = selectedMeetingId else { return false }
        return generatingNotes.contains(NoteGenerationKey(meetingId: id, level: level))
    }

    // Audio
    //
    // Both are `let`, NOT `@Published`: they are `ObservableObject`s in their own
    // right and views observe them directly. Publishing them here would forward
    // every 10 Hz player tick into `ViewerStore.objectWillChange` and redraw the
    // entire viewer — sidebar, notes editor and all — ten times a second.
    let audioPlayer = AudioPlayer()
    /// Quantised playhead the transcript follows. See `TranscriptPlayhead`.
    let playhead = TranscriptPlayhead()

    /// Bumped by every audio load so a load that finishes after the user has
    /// moved on publishes nothing.
    private var audioGeneration = 0
    /// Seek requested by a search hit, applied once that meeting's audio is open.
    private var pendingSeekSeconds: TimeInterval?

    // Dependencies
    public let storage: MeetingStorage
    public let indexer: MeetingIndexer
    public let claudeBinary: () -> URL?
    /// Model alias for `claude --model`; nil/empty = the CLI's default. A
    /// closure (like `claudeBinary`) so a Settings change applies to the very
    /// next generation without rebuilding the store.
    public let claudeModel: () -> String?
    private let persistence: ViewerStatePersistence

    // Debounce holders
    private var notesSaveTask: Task<Void, Never>?
    private var liveSaveTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    public init(storage: MeetingStorage,
                indexer: MeetingIndexer,
                claudeBinary: @escaping () -> URL?,
                claudeModel: @escaping () -> String? = { nil },
                persistence: ViewerStatePersistence = ViewerStatePersistence()) {
        self.storage = storage
        self.indexer = indexer
        self.claudeBinary = claudeBinary
        self.claudeModel = claudeModel
        self.persistence = persistence

        // Feed the transcript's playhead from the player. Deliberately a callback
        // rather than a Combine subscription on `$currentTime`: the point is that
        // nothing observes the player's 10 Hz publisher except the scrubber bar.
        let head = self.playhead
        self.audioPlayer.onTimeChanged = { t in head.update(t) }

        let s = persistence.load()
        self.selectedMeetingId = s.lastMeetingId
        self.activeNoteLevel = NoteLevel(rawValue: s.activeNoteLevel) ?? .synthese
        self.notesToTranscriptRatio = s.notesToTranscriptRatio
        self.transcriptPanelHidden = s.transcriptPanelHidden
        self.searchQuery = s.lastSearchQuery
        self.openedNoteMeetingIds = Set(s.openedNoteMeetingIds ?? [])

        // Persist layout changes with debounce. The sink builds the state from
        // the values the publisher hands it rather than from `self`, so it needs
        // no main-actor hop at all: `ViewerStatePersistence` is Sendable and
        // `scheduleSave` is queue-safe from any thread. That also makes the
        // scheduling *synchronous* with the mutation, which is what lets
        // `flushState()` (called at terminate, when we cannot await anything)
        // see the very latest state.
        let persist = persistence
        Publishers.CombineLatest4($selectedMeetingId, $activeNoteLevel,
                                  $notesToTranscriptRatio, $transcriptPanelHidden)
            .combineLatest($searchQuery, $openedNoteMeetingIds)
            .sink { combined in
                let ((id, level, ratio, hidden), query, opened) = combined
                persist.scheduleSave(ViewerState(
                    lastMeetingId: id,
                    activeNoteLevel: level.rawValue,
                    notesToTranscriptRatio: ratio,
                    transcriptPanelHidden: hidden,
                    lastSearchQuery: query,
                    openedNoteMeetingIds: Array(opened)
                ))
            }
            .store(in: &cancellables)
    }

    // MARK: - Meetings

    /// Fire-and-forget: the SQLite query runs off the main actor (see
    /// `offMain`), then `meetings` is republished on it. Callers must not
    /// assume `meetings` is populated when this returns.
    ///
    /// Also folds in meetings that exist on disk but have no index row yet —
    /// i.e. the one being recorded or transcribed right now. Without this the
    /// live meeting was invisible in the sidebar until its pipeline finished.
    public func refreshMeetings() {
        let indexer = self.indexer
        let storage = self.storage
        Task { [weak self] in
            let listings = await Self.offMain {
                var rows = (try? indexer.listAllGrouped()) ?? []
                let indexed = Set(rows.map(\.id))
                let onDisk = (try? storage.listMeetings()) ?? []
                for entry in onDisk where !indexed.contains(entry.slug) {
                    let paths = MeetingPaths(root: storage.root, slug: entry.slug)
                    if let synth = Self.synthesizeListing(storage: storage,
                                                          id: entry.slug, paths: paths) {
                        rows.append(synth)
                    }
                }
                rows.sort { $0.startedAt > $1.startedAt }
                return rows
            }
            guard let self else { return }
            self.meetings = listings
            // Re-resolve the header's listing: a selection restored at init had
            // no `meetings` to match against, and a meeting whose pipeline just
            // finished must switch from the synthesized in-progress listing to
            // its real index row.
            if let id = self.selectedMeetingId {
                let paths = MeetingPaths(root: self.storage.root, slug: id)
                self.currentListing = self.resolveListing(id: id, paths: paths)
                // The selected meeting can vanish mid-session: a continuation
                // segment absorbed into its parent, or a part folded into a
                // manual merge. Follow it there instead of dropping the user
                // into the empty state.
                if self.currentListing == nil,
                   let meta = try? self.storage.loadMetadata(paths),
                   meta.absorbed == true,
                   let parent = meta.mergedInto ?? meta.continuationOf {
                    self.selectMeeting(parent)
                }
            }
            // The selection is restored from disk at init, but its content is
            // not: `loadCurrentMeetingContent` needs `meetings` to resolve the
            // listing, and that only arrives here. Without this the viewer opens
            // on a meeting with a filled-in header and blank notes/transcript.
            if self.selectedMeetingId != nil, self.currentTranscript.isEmpty,
               self.currentNotes.isEmpty {
                self.loadCurrentMeetingContent()
            }
        }
    }

    public func selectMeeting(_ id: String) {
        // First open of a meeting whose generated notes exist → land on the
        // first generated level in `NoteLevel.generatable` order (brief →
        // synthèse → détaillée) instead of whatever tab was left active
        // (typically Direct right after a recording). Checking the files on
        // disk rather than `defaultNoteLevels` deliberately: settings may have
        // changed since this meeting was generated. Only marked as opened once
        // a note file exists, so a meeting visited while still recording gets
        // the switch on its first open *after* generation.
        if !openedNoteMeetingIds.contains(id) {
            let paths = MeetingPaths(root: storage.root, slug: id)
            let fm = FileManager.default
            if let level = NoteLevel.generatable
                .first(where: { fm.fileExists(atPath: paths.notesFile($0).path) }) {
                openedNoteMeetingIds.insert(id)
                activeNoteLevel = level
            }
        }
        selectedMeetingId = id
        loadCurrentMeetingContent()
    }

    /// Open the live-notes editor on the meeting identified by `slug` — the one
    /// currently being recorded.
    ///
    /// `slug` is passed in rather than inferred because the store has no idea
    /// what is being recorded, and the in-progress meeting is **not** in
    /// `meetings`: `MeetingIndexer.upsert` is only ever called by `RescanRunner`,
    /// so a meeting gets an index row at the earliest when its pipeline has
    /// finished. Selecting by slug alone works because `MeetingPaths` needs only
    /// the meetings root plus the slug.
    ///
    /// A `nil`/empty slug means "nothing is being recorded". In that case we must
    /// NOT switch to `.live`: doing so pointed the editor at whatever meeting the
    /// user had last selected, and the next keystroke overwrote *that* meeting's
    /// `notes/live.md`. Returning `false` lets the caller stay silent rather than
    /// destroy data.
    @discardableResult
    public func focusLiveNotes(slug: String?) -> Bool {
        guard let slug, !slug.isEmpty else { return false }
        if selectedMeetingId != slug { selectMeeting(slug) }
        setActiveNoteLevel(.live)
        return true
    }

    /// Resolves the listing for `selectedMeetingId`, preferring the index row and
    /// falling back to one synthesized from `meta.json` + `job.json`.
    ///
    /// The fallback is what makes the in-progress recording reachable at all:
    /// `MainPanel` keys the whole right-hand side off a listing, so without it a
    /// meeting that has no index row rendered the "nothing selected" empty state —
    /// hiding the live notes exactly while they are being taken.
    private func resolveListing(id: String, paths: MeetingPaths) -> MeetingListing? {
        if let row = meetings.first(where: { $0.id == id }) { return row }
        return Self.synthesizeListing(storage: storage, id: id, paths: paths)
    }

    /// Listing built straight from `meta.json` + `job.json`, for meetings the
    /// index does not know yet (recording or mid-pipeline). `nonisolated` so
    /// `refreshMeetings` can call it from its off-main closure.
    private nonisolated static func synthesizeListing(
        storage: MeetingStorage, id: String, paths: MeetingPaths
    ) -> MeetingListing? {
        guard let meta = try? storage.loadMetadata(paths) else { return nil }
        // Absorbed continuation segments live inside their parent's transcript;
        // resurfacing them here would undo their removal from the index.
        guard meta.absorbed != true else { return nil }
        // Same mapping RescanRunner uses, so the synthesized state and the one
        // that lands in the index later cannot disagree.
        let state: String
        switch try? storage.loadJob(paths).state {
        case .done:   state = "done"
        case .failed: state = "failed"
        default:      state = "in_progress"
        }
        return MeetingListing(id: id, startedAt: meta.startedAt, title: meta.title,
                              folderPath: paths.root, transcriptState: state,
                              source: meta.source, detectedApp: meta.detectedApp)
    }

    // MARK: - Live pipeline status

    /// Pushes a live status for `slug` (nil clears it). Also mirrors the
    /// terminal states into the in-memory listings so placeholder texts and
    /// "Régénérer" affordances react without waiting for a re-query.
    public func setPipelineState(slug: String, state: JobOverallState?) {
        if let state, state != .done {
            if pipelineStates[slug] != state { stateStartedAt[slug] = Date() }
            pipelineStates[slug] = state
        } else {
            pipelineStates.removeValue(forKey: slug)
            pipelineProgress.removeValue(forKey: slug)
            stateStartedAt.removeValue(forKey: slug)
        }
        refreshProgressTicker()
        let coarse: String?
        switch state {
        case .some(.done):   coarse = "done"
        case .some(.failed): coarse = "failed"
        case .some:          coarse = "in_progress"
        case .none:          coarse = nil
        }
        if let coarse {
            if let i = meetings.firstIndex(where: { $0.id == slug }) {
                meetings[i].transcriptState = coarse
            }
            if currentListing?.id == slug {
                currentListing?.transcriptState = coarse
            }
        }
        // A pipeline that just finished has fresh transcript + notes on disk;
        // reload them if the user is currently looking at that meeting.
        if state == .done, selectedMeetingId == slug {
            loadCurrentMeetingContent()
        }
    }

    /// Visual family of a sidebar status badge — the row picks the color.
    public enum RowStatusKind { case recording, processing, waiting, failed }

    /// Status badge for a sidebar row. Live pipeline pushes win; otherwise
    /// falls back to the *persisted* state, so a meeting recorded but not yet
    /// transcribed (pipeline queued, or interrupted and waiting for the
    /// resume at next launch) is distinguishable from a finished one.
    public func rowStatus(for m: MeetingListing) -> (label: String, kind: RowStatusKind)? {
        if let live = liveStatusLabel(for: m.id) {
            let kind: RowStatusKind = pipelineStates[m.id] == .recording ? .recording
                : pipelineStates[m.id] == .failed ? .failed : .processing
            return (live, kind)
        }
        switch m.transcriptState {
        case "in_progress": return ("En attente de transcription", .waiting)
        case "failed":      return ("Échec du traitement", .failed)
        default:            return nil
        }
    }

    /// Human label for the sidebar badge, nil when the meeting is not live.
    /// Transcription carries a measured percentage (chunk position over total
    /// audio); notes carry an estimated one (elapsed over typical duration).
    public func liveStatusLabel(for slug: String) -> String? {
        guard let s = pipelineStates[slug] else { return nil }
        switch s {
        case .recording:       return "Enregistrement…"
        case .normalizing:     return "Préparation audio…"
        case .transcribing:
            if let p = pipelineProgress[slug] {
                return "Transcription… \(Int((p * 100).rounded())) %"
            }
            return "Transcription…"
        case .diarizing:       return "Identification des voix…"
        case .merging, .rendering, .cleanup:
                               return "Assemblage…"
        case .generatingNotes:
            let elapsed = stateStartedAt[slug].map { Date().timeIntervalSince($0) } ?? 0
            return "Génération des notes… \(Self.notesProgressPercent(elapsed: elapsed)) %"
        case .failed:          return "Échec du traitement"
        case .done:            return nil
        }
    }

    /// Estimated notes progress: a `claude -p` run reports nothing, so this
    /// maps elapsed time onto the typical duration (~75 s measured), slowing
    /// down as it approaches the cap so it never reaches 100 % before the
    /// real completion event.
    nonisolated static func notesProgressPercent(elapsed: TimeInterval,
                                                 typical: TimeInterval = 75) -> Int {
        guard elapsed > 0 else { return 0 }
        // Saturating curve: 63 % at `typical`, ~86 % at 2×, ~95 % at 3×.
        let fraction = 1 - exp(-elapsed / typical)
        return min(99, Int((fraction * 100).rounded()))
    }

    /// Runs a 1 Hz repaint while (and only while) a notes generation is in
    /// flight — its percentage is time-based, nothing else would refresh it.
    private func refreshProgressTicker() {
        let needsTick = pipelineStates.values.contains(.generatingNotes)
        if needsTick, progressTicker == nil {
            progressTicker = Timer.publish(every: 1, on: .main, in: .common)
                .autoconnect()
                .sink { [weak self] _ in self?.objectWillChange.send() }
        } else if !needsTick {
            progressTicker = nil
        }
    }

    private func loadCurrentMeetingContent() {
        // No index row required: `MeetingPaths` resolves from root + slug and
        // `MeetingStorage` reads `meta.json` directly, so a meeting still being
        // recorded (which nothing has indexed yet) loads just like any other.
        guard let id = selectedMeetingId else {
            currentTranscript = []; currentNotes = ""; currentLiveNotes = ""
            notesEditedSinceGeneration = false
            currentDurationSeconds = nil
            currentListing = nil
            currentMergedParts = []
            // Releases the player and clears the waveform (`selectedMeetingId`
            // is nil, so it does nothing else).
            loadAudioForCurrentMeeting()
            return
        }
        let paths = MeetingPaths(root: storage.root, slug: id)
        currentListing = resolveListing(id: id, paths: paths)
        currentTranscript = (try? AtomicJSON.read([TranscriptSegment].self,
                                                  from: paths.transcriptJson)) ?? []
        currentLiveNotes = (try? String(contentsOf: paths.liveNotes, encoding: .utf8)) ?? ""
        let meta = try? storage.loadMetadata(paths)
        currentDurationSeconds = meta?.durationSeconds
        // Published rather than read from a view body: resolving it is file IO,
        // same reason as `currentDurationSeconds`.
        currentMergedParts = (meta?.mergedParts?.count ?? 0) > 1 ? meta!.mergedParts! : []
        loadActiveNote(paths: paths)
        loadAudioForCurrentMeeting()
    }

    // MARK: - Audio

    /// Loads the selected meeting's audio and waveform.
    ///
    /// Fire-and-forget like `refreshMeetings`: opening the file and (worst case)
    /// generating a waveform are both seconds of blocking work for a long
    /// recording, so they go through `offMain`. The synchronous part — clearing
    /// the previous meeting's player and waveform — happens immediately so the
    /// scrubber can never show meeting A's waveform under meeting B's header.
    public func loadAudioForCurrentMeeting() {
        audioGeneration += 1
        let generation = audioGeneration
        pendingSeekSeconds = nil
        audioPlayer.stop()
        playhead.reset()
        currentWaveform = []

        guard let id = selectedMeetingId else { return }
        let paths = MeetingPaths(root: storage.root, slug: id)
        let storage = self.storage
        Task { [weak self] in
            // A merged meeting plays its parts through one transport, each at
            // its own offset; a plain meeting is the single-part case of the
            // same code.
            let slots = await Self.offMain { Self.audioSlots(storage: storage, paths: paths) }
            guard slots.contains(where: { !$0.sources.urls.isEmpty })
            else { return }   // No playable audio: inert scrubber, no waveform.
            guard let self, generation == self.audioGeneration else { return }

            // Both streams when both exist (the full conversation, mixed and
            // time-aligned), one when only one exists.
            await self.audioPlayer.load(parts: slots.map {
                AudioPlayer.Part(urls: $0.sources.urls, offset: $0.offset)
            })
            guard generation == self.audioGeneration else { return }
            if let t = self.pendingSeekSeconds {
                self.pendingSeekSeconds = nil
                self.audioPlayer.seek(t)
            }

            let peaks = await Self.offMain { Self.peaks(slots: slots) }
            guard generation == self.audioGeneration else { return }
            self.currentWaveform = peaks
        }
    }

    /// One entry per stretch of the meeting's timeline: where it starts, how
    /// long its slot is, and which files to play for it.
    ///
    /// Exactly one entry for an ordinary meeting. For a merged one, the offsets
    /// and durations are read from `meta.mergedParts` and never recomputed —
    /// they are the same numbers the transcript was shifted by, so reading them
    /// back is what keeps the playhead on the right words.
    nonisolated struct AudioSlot {
        let paths: MeetingPaths
        let offset: TimeInterval
        /// Slot length on the timeline, used to pad the waveform of a part whose
        /// mic stream is shorter than its slot. Zero = unknown (single-part).
        let duration: TimeInterval
        let sources: AudioSourceResolver.Sources
    }

    private nonisolated static func audioSlots(storage: MeetingStorage,
                                               paths: MeetingPaths) -> [AudioSlot] {
        let meta = try? storage.loadMetadata(paths)
        guard let parts = meta?.mergedParts, parts.count > 1 else {
            return [AudioSlot(paths: paths, offset: 0, duration: 0,
                              sources: AudioSourceResolver.resolveSources(paths: paths))]
        }
        return parts.map { part in
            let partPaths = part.slug == paths.slug
                ? paths : MeetingPaths(root: storage.root, slug: part.slug)
            return AudioSlot(paths: partPaths, offset: part.offsetSeconds,
                             duration: part.durationSeconds,
                             sources: AudioSourceResolver.resolveSources(paths: partPaths))
        }
    }

    /// `waveform.json` if the pipeline wrote one, else generated on the fly.
    ///
    /// The fallback matters for meetings recorded before chantier 3, and it has
    /// to work on the file that actually survives `.cleanup` — an `.m4a`, not a
    /// WAV. `WaveformGenerator` goes through `AVAudioFile`, whose
    /// `processingFormat` is float32 PCM for compressed inputs too, so a
    /// compressed source works (pinned down by
    /// `ViewerStoreAudioTests.test_waveformGeneratorWorksOnAnM4a`).
    ///
    /// Runs off the main actor — it is a full decode of the recording.
    /// Peaks for the whole timeline: one part's peaks, or every part's peaks
    /// concatenated.
    ///
    /// Concatenation is exact here and only here: parts are butted end-to-end
    /// (no silence between them) and every waveform in the app uses the same
    /// 50 ms bucket, so appending the arrays lines up with the composition —
    /// after padding each part to its slot, since a part whose mic stream is
    /// shorter than its slot (mic-less stretch, system-only) would otherwise
    /// pull every later part's peaks to the left of what is heard.
    private nonisolated static func peaks(slots: [AudioSlot]) -> [Float] {
        guard slots.count > 1 else {
            guard let only = slots.first else { return [] }
            return peaks(paths: only.paths, sources: only.sources)
        }
        var out: [Float] = []
        for slot in slots {
            var part = peaks(paths: slot.paths, sources: slot.sources)
            let buckets = Int((slot.duration * 1000 / Double(Self.waveformBucketMs)).rounded())
            if buckets > 0 {
                if part.count > buckets { part = Array(part.prefix(buckets)) }
                else if part.count < buckets {
                    part += Array(repeating: 0, count: buckets - part.count)
                }
            }
            out += part
        }
        return out
    }

    /// Bucket width of every waveform in the app (`Pipeline`'s render step and
    /// the on-the-fly fallback both use it). Concatenating parts' peaks is only
    /// valid because it is the same everywhere.
    nonisolated static let waveformBucketMs = 50

    private nonisolated static func peaks(paths: MeetingPaths,
                                          sources: AudioSourceResolver.Sources) -> [Float] {
        // The waveform stays mic-drawn: playback now mixes mic + system, so
        // whenever the mix *includes* the mic stream the mic waveform still
        // describes (the user's half of) what is audible — same convention as
        // the pipeline's `waveform.json`. Only a mic-less meeting draws from
        // the system file instead.
        guard let source = sources.mic ?? sources.system else { return [] }
        let isMic = AudioSourceResolver.isMicSource(source, paths: paths)
        // Only reusable for a mic source: the pipeline computes it from
        // `mic_normalized.wav`, so drawing it over a system-only meeting would
        // show a waveform unrelated to what is audible.
        if isMic, let wf = try? WaveformFile.read(from: paths.waveformJson),
           !wf.peaks.isEmpty {
            return wf.peaks
        }
        guard let wf = try? WaveformGenerator.generate(from: source, bucketSizeMs: 50)
        else { return [] }   // Unreadable audio: no waveform, scrubber still works.
        // Cache it so the next open of this meeting is instant. Only for a mic
        // source, so we never leave a system-derived waveform where the pipeline
        // and everything else expect a mic-derived one.
        if isMic { try? wf.write(to: paths.waveformJson) }
        return wf.peaks
    }

    /// Move the playhead. Used by the transcript's click-to-seek.
    ///
    /// With no audio loaded there is nothing to seek, but the highlight must
    /// still move — that was the pre-audio behaviour and losing it would make
    /// clicking a turn in an audio-less meeting look broken.
    public func seek(to t: TimeInterval) {
        guard audioPlayer.hasAudio else {
            playhead.update(t)
            return
        }
        audioPlayer.seek(t)   // Feeds `playhead` through `onTimeChanged`.
    }

    /// Select the meeting a search hit belongs to and jump to the matching
    /// passage.
    ///
    /// `approximateTimestamp` is optional (the FTS row may carry no `start_ms`)
    /// and the meeting may have no audio at all; both cases degrade to a plain
    /// selection.
    public func selectSearchHit(_ hit: SearchHit) {
        let sameMeeting = (selectedMeetingId == hit.meetingId)
        if !sameMeeting { selectMeeting(hit.meetingId) }
        guard let t = hit.approximateTimestamp, t.isFinite, t >= 0 else { return }
        if sameMeeting, audioPlayer.hasAudio {
            audioPlayer.seek(t)
        } else {
            // The audio is still opening; `loadAudioForCurrentMeeting` applies
            // this once it is ready, and drops it if the selection moves on.
            pendingSeekSeconds = t
            playhead.update(t)
        }
    }

    /// Change the visible note tab **and** load that tab's content.
    ///
    /// Assigning `activeNoteLevel` on its own is not enough: nothing observes it
    /// to reload, so the previous level's text would stay on screen. Every
    /// caller that changes the level (the tab strip, ⌘⇧L) must go through here.
    ///
    /// `.live` is handled by `loadActiveNote`, which reads `liveNotes` into
    /// `currentLiveNotes` and disarms `notesEditedSinceGeneration`.
    public func setActiveNoteLevel(_ level: NoteLevel) {
        activeNoteLevel = level
        guard let id = selectedMeetingId else {
            currentNotes = ""; currentLiveNotes = ""
            notesEditedSinceGeneration = false
            return
        }
        loadActiveNote(paths: MeetingPaths(root: storage.root, slug: id))
    }

    public func loadActiveNote(paths: MeetingPaths) {
        // `.live` is NOT a generated note. `paths.notesFile(.live)` happens to
        // resolve to the very same file as `paths.liveNotes` (notes/live.md),
        // so reading it through the generated-notes path would (a) copy the
        // user's own notes into `currentNotes` — from where `onNotesEdited`
        // would write them back through the wrong channel — and (b) run the
        // "modified after job.json" freshness heuristic on a file that is
        // *always* user-authored, permanently showing the "regenerate?" banner.
        // Refresh `currentLiveNotes` instead and leave `currentNotes` alone.
        guard activeNoteLevel != .live else {
            currentLiveNotes = (try? String(contentsOf: paths.liveNotes,
                                            encoding: .utf8)) ?? ""
            notesEditedSinceGeneration = false
            return
        }
        currentNotes = (try? String(contentsOf: paths.notesFile(activeNoteLevel),
                                    encoding: .utf8)) ?? ""
        notesEditedSinceGeneration = notesModifiedAfterJob(paths: paths, level: activeNoteLevel)
    }

    private func notesModifiedAfterJob(paths: MeetingPaths, level: NoteLevel) -> Bool {
        let fm = FileManager.default
        guard let noteAttr = try? fm.attributesOfItem(atPath: paths.notesFile(level).path),
              let jobAttr  = try? fm.attributesOfItem(atPath: paths.job.path),
              let noteMTime = noteAttr[.modificationDate] as? Date,
              let jobMTime  = jobAttr[.modificationDate]  as? Date
        else { return false }
        // Small buffer so the write done by the pipeline itself doesn't trip us.
        return noteMTime.timeIntervalSince(jobMTime) > 5.0
    }

    // MARK: - Notes editing (auto-save debounce)

    public func onNotesEdited(_ new: String) {
        // Guard: this is the *generated* notes channel. `.live` must go through
        // `onLiveNotesEdited` — otherwise `notesFile(.live)` (== live.md) gets
        // written here and `notesEditedSinceGeneration` is falsely set.
        guard activeNoteLevel != .live else { return }
        currentNotes = new
        guard let id = selectedMeetingId else { return }
        let paths = MeetingPaths(root: storage.root, slug: id)
        let level = activeNoteLevel
        notesSaveTask?.cancel()
        // This Task inherits the main actor (the class is @MainActor), which is
        // what serialises cancel-then-replace correctly. Only the blocking file
        // write is pushed off the main thread.
        let indexer = self.indexer
        notesSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            let target = paths.notesFile(level)
            await Self.offMain {
                try? new.data(using: .utf8)?.write(to: target, options: .atomic)
                // Keep the search index in step with the edit — otherwise
                // hand-written additions are unfindable until the next rescan.
                try? indexer.updateNote(id: paths.slug, kind: level.rawValue, text: new)
            }
            self?.notesEditedSinceGeneration = true
        }
    }

    public func onLiveNotesEdited(_ new: String) {
        currentLiveNotes = new
        guard let id = selectedMeetingId else { return }
        let paths = MeetingPaths(root: storage.root, slug: id)
        liveSaveTask?.cancel()
        let indexer = self.indexer
        liveSaveTask = Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            let target = paths.liveNotes
            await Self.offMain {
                try? new.data(using: .utf8)?.write(to: target, options: .atomic)
                try? indexer.updateNote(id: paths.slug, kind: "live", text: new)
            }
        }
    }

    // MARK: - Search

    public func onSearchQueryChanged(_ q: String) {
        searchQuery = q
        // Checkboxes live on the browse list only; the search results list has
        // no rows to tick. Leaving selection mode armed under a search would
        // show a "Supprimer (n)" footer over a list where nothing is visibly
        // checked — so a real query cancels it.
        if !q.trimmingCharacters(in: .whitespaces).isEmpty { endSelecting() }
        searchTask?.cancel()
        let indexer = self.indexer
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            // FTS5 query off the main thread. GRDB serialises access to its
            // DatabaseWriter internally, so this is safe to call concurrently.
            let hits = await Self.offMain { (try? indexer.search(q, limit: 100)) ?? [] }
            guard let self, !Task.isCancelled else { return }
            // Stale-result guard. While the query is genuinely off-actor, an
            // older search can now finish *after* a newer one; only the result
            // for the query currently in the field may be published.
            guard self.searchQuery == q else { return }
            self.searchResults = hits
        }
    }

    // MARK: - Regeneration

    public func regenerateActiveNote() async {
        await regenerateNote(level: activeNoteLevel)
    }

    /// Generate one note level for the *currently selected* meeting.
    ///
    /// Meeting and level are captured synchronously at the call (this class is
    /// @MainActor, so nothing can change them before the first `await`): the
    /// user can switch tab or meeting while the subprocess runs and the result
    /// still lands in the right file. Generations of *different* keys run in
    /// parallel — only a re-entrant click on the same (meeting, level) is
    /// ignored, because two subprocesses would race for the same output file.
    public func regenerateNote(level: NoteLevel) async {
        // `.live` is user-authored; asking Claude to regenerate it would
        // destroy the user's notes (the generator also refuses, with
        // GenerationError.liveIsNotGeneratable). Refuse before we get anywhere
        // near the generator so the UI never shows a pointless error.
        guard level != .live else { return }
        guard let id = selectedMeetingId else { return }
        let key = NoteGenerationKey(meetingId: id, level: level)
        // Re-entrancy: a second click while THIS note is generating must not
        // spawn a second subprocess racing the first for the same output file.
        guard !generatingNotes.contains(key) else { return }
        guard let bin = claudeBinary() else {
            generationErrors[key] = "Le chemin du binaire Claude n'est pas configuré "
                                  + "(Réglages → Notes)."
            return
        }
        // Validate existence up front: `Process.run` reports a missing
        // executable as a Cocoa error, and the stored path silently rots when a
        // Claude Code update relocates the install (this happened — the setting
        // pointed at ~/.local/bin/claude after the binary moved under nvm).
        guard FileManager.default.fileExists(atPath: bin.path) else {
            generationErrors[key] = "Binaire Claude introuvable : \(bin.path)\n"
                                  + "Mets à jour le chemin dans Réglages → Notes."
            return
        }
        let paths = MeetingPaths(root: storage.root, slug: id)
        // Titre auto, synthèse uniquement : calendar garde le titre de
        // l'événement ; huddle/sauvage se font titrer par Claude tant que
        // l'utilisateur n'a pas écrit le sien (wantsTitleDetection).
        let detectTitle = level == .synthese
            && ((try? storage.loadMetadata(paths))?.wantsTitleDetection ?? false)
        generatingNotes.insert(key)
        generationErrors[key] = nil
        defer { generatingNotes.remove(key) }
        do {
            let result = try await ClaudeNoteGenerator().generate(
                paths: paths, level: level, binary: bin,
                model: claudeModel(), detectTitle: detectTitle)
            if let title = result.detectedTitle {
                applyTitle(title, autoDetected: true, meetingId: id, paths: paths)
            }
            // Refresh the editor only if the user is still looking at this
            // (meeting, level) — reloading the active note for a generation
            // that finished on another tab would clobber what they're reading.
            if selectedMeetingId == id, activeNoteLevel == level {
                loadActiveNote(paths: paths)
            }
        } catch {
            generationErrors[key] = Self.describe(generationFailure: error)
        }
    }

    // MARK: - Deletion

    /// A meeting can be deleted unless it is being recorded or its pipeline is
    /// running — deleting the folder under an active pipeline would make every
    /// subsequent step write into a directory that no longer exists. `.failed`
    /// is deletable: nothing is running, the user is cleaning up a wreck.
    public func canDeleteMeeting(_ id: String) -> Bool {
        switch pipelineStates[id] {
        case .none, .some(.failed): return true
        default:                    return false
        }
    }

    /// Moves the meeting's folder to the Trash (recoverable, not a hard
    /// delete), drops its index row + search entries, and removes it from the
    /// UI. If it was the selected meeting, the selection is cleared first so
    /// the player never holds an open file inside a folder being trashed.
    public func deleteMeeting(_ id: String) { deleteMeetings([id]) }

    /// Batch version, behind the sidebar's checkbox selection mode.
    ///
    /// Ids that `canDeleteMeeting` refuses are skipped rather than aborting the
    /// whole batch: between ticking a box and pressing "Supprimer", a meeting
    /// can have started recording or entered its pipeline, and that must not
    /// cost the user the other deletions.
    public func deleteMeetings(_ ids: [String]) {
        // Deduplicated, order-preserving — a repeated id would trash the same
        // folder twice (the second attempt failing on a missing path).
        var seen = Set<String>()
        let deletable = ids.filter { canDeleteMeeting($0) && seen.insert($0).inserted }
        guard !deletable.isEmpty else { return }
        let set = Set(deletable)
        if let selected = selectedMeetingId, set.contains(selected) {
            audioPlayer.stop()
            selectedMeetingId = nil
            loadCurrentMeetingContent()
        }
        meetings.removeAll { set.contains($0.id) }
        for id in deletable {
            pipelineStates.removeValue(forKey: id)
            pipelineProgress.removeValue(forKey: id)
        }
        checkedMeetingIds.subtract(set)
        let root = storage.root
        let indexer = self.indexer
        Task {
            await Self.offMain {
                for id in deletable {
                    try? indexer.removeMeeting(id: id)
                    // Trash after the index drop: a failed trash leaves a
                    // rescan-able folder (the meeting reappears at next rescan),
                    // whereas the reverse order could leave a ghost index row
                    // pointing at nothing.
                    try? FileManager.default.trashItem(
                        at: MeetingPaths(root: root, slug: id).root,
                        resultingItemURL: nil)
                }
            }
        }
    }

    // MARK: - Multi-selection (sidebar checkbox mode)

    /// True while the sidebar shows a checkbox on every row. A dedicated mode
    /// rather than always-on checkboxes so an ordinary click stays "open this
    /// meeting" — and so the destructive footer only exists when asked for.
    @Published public private(set) var isSelecting: Bool = false
    /// Ticked meetings. Only ever contains deletable ids (see `toggleChecked`),
    /// but `deleteCheckedMeetings` re-filters anyway: a meeting can start
    /// recording while its box is ticked.
    @Published public private(set) var checkedMeetingIds: Set<String> = []

    /// Ticked ids that are still deletable, in sidebar order — what the footer
    /// counts and what "Supprimer" acts on.
    public var deletableCheckedIds: [String] {
        meetings.map(\.id).filter { checkedMeetingIds.contains($0) && canDeleteMeeting($0) }
    }

    public func beginSelecting() {
        isSelecting = true
        checkedMeetingIds = []
    }

    /// Leaves selection mode and drops every tick — an abandoned selection must
    /// not silently come back the next time the mode is entered.
    public func endSelecting() {
        isSelecting = false
        checkedMeetingIds = []
    }

    /// Ticks/unticks one row. A meeting being recorded or processed cannot be
    /// ticked at all, which is what keeps the footer's count honest.
    public func toggleChecked(_ id: String) {
        guard canDeleteMeeting(id) else { return }
        if checkedMeetingIds.contains(id) {
            checkedMeetingIds.remove(id)
        } else {
            checkedMeetingIds.insert(id)
        }
    }

    public func isChecked(_ id: String) -> Bool { checkedMeetingIds.contains(id) }

    /// "Tout" — every *deletable* meeting, so the recording in progress is not
    /// swept into a batch delete by one click.
    public func checkAllDeletable() {
        checkedMeetingIds = Set(meetings.map(\.id).filter { canDeleteMeeting($0) })
    }

    public func uncheckAll() { checkedMeetingIds = [] }

    /// Trashes every ticked meeting and leaves selection mode.
    public func deleteCheckedMeetings() {
        deleteMeetings(deletableCheckedIds)
        endSelecting()
    }

    // MARK: - Merge

    /// Ticked meetings that can be merged, oldest first — the order the parts
    /// will end up in, so the confirmation can show it as-is.
    ///
    /// Same busy rule as deletion (`canDeleteMeeting`) plus "its pipeline
    /// actually finished": merging a `.failed` meeting is meaningless, it has no
    /// transcript to contribute.
    public var mergeableCheckedIds: [String] {
        let byId = Dictionary(meetings.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return deletableCheckedIds
            .compactMap { byId[$0] }
            .filter { $0.transcriptState == "done" }
            .sorted { $0.startedAt < $1.startedAt }
            .map(\.id)
    }

    /// A merge needs at least two parts.
    public var canMergeChecked: Bool { mergeableCheckedIds.count >= 2 }

    /// True while a merge is running. Drives the footer's progress state — the
    /// notes regeneration inside it is a `claude -p` call per level, i.e. tens
    /// of seconds during which the button must not be pressable again.
    @Published public private(set) var isMerging = false
    /// French message for a merge that could not be done, shown in the sidebar.
    @Published public var mergeError: String?

    /// Merges the ticked meetings into their oldest member: concatenated
    /// transcript, concatenated live notes, regenerated notes, one row left in
    /// the sidebar. The absorbed meetings' folders stay on disk (hidden), which
    /// is what makes the merged audio playable without rewriting any file.
    public func mergeCheckedMeetings() async {
        let ids = mergeableCheckedIds
        guard ids.count >= 2, !isMerging else { return }
        isMerging = true
        mergeError = nil
        defer { isMerging = false }

        let storage = self.storage
        let indexer = self.indexer
        // Regenerate exactly the levels this meeting already has notes for:
        // the merge must refresh what exists, not invent levels the user never
        // asked for. `titleCarrier`/`wantsTitleDetection` are handled downstream.
        let levels = NoteLevel.generatable.filter { level in
            ids.contains { id in
                FileManager.default.fileExists(
                    atPath: MeetingPaths(root: storage.root, slug: id).notesFile(level).path)
            }
        }
        let cfg = NoteGenerationConfig(binary: claudeBinary(), levels: levels,
                                       model: claudeModel())
        let result: MeetingMerger.MergeResult
        do {
            result = try await MeetingMerger(storage: storage, notes: cfg).merge(slugs: ids)
        } catch {
            mergeError = Self.describe(mergeFailure: error)
            return
        }

        // Index: the absorbed rows must go, the carrier's row must pick up its
        // new duration/title and its concatenated transcript for search.
        await Self.offMain {
            for slug in result.absorbed { try? indexer.removeMeeting(id: slug) }
            RescanRunner(storage: storage, indexer: indexer).reindex(slug: result.target)
        }
        endSelecting()
        refreshMeetings()
        // Land the user on the result, reloading transcript, notes and the
        // freshly multi-part audio.
        selectMeeting(result.target)
    }

    private static func describe(mergeFailure error: Error) -> String {
        switch error {
        case MeetingMerger.MergeError.needsAtLeastTwoMeetings:
            return "Il faut au moins deux meetings terminés pour fusionner."
        case MeetingMerger.MergeError.notFinished(let slug):
            return "« \(slug) » n'est pas terminé (enregistrement ou traitement en cours)."
        case MeetingMerger.MergeError.alreadyMerged(let slug):
            return "« \(slug) » fait déjà partie d'une fusion."
        case MeetingMerger.MergeError.cannotAbsorbMergedMeeting(let slug):
            return "« \(slug) » est déjà un meeting fusionné : il ne peut être fusionné "
                 + "qu'avec des meetings plus récents que lui."
        default:
            return "La fusion a échoué : \(error.localizedDescription)"
        }
    }

    /// Parts of the selected meeting when it is a merged one, else `[]`. Empty
    /// for every ordinary meeting, so the UI can key a "N parties" badge off it.
    @Published public private(set) var currentMergedParts: [MeetingMetadata.MergedPart] = []

    // MARK: - Title

    /// Manual rename from the header. An empty string removes the title
    /// ("Sans titre"); a manual title disarms auto-detection for good.
    public func renameSelectedMeeting(_ newTitle: String) {
        guard let id = selectedMeetingId else { return }
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        applyTitle(trimmed.isEmpty ? nil : trimmed, autoDetected: false,
                   meetingId: id, paths: MeetingPaths(root: storage.root, slug: id))
    }

    /// Writes a title everywhere it lives: `meta.json` (source of truth), the
    /// SQLite index (sidebar + search), and the in-memory listings so the UI
    /// updates without waiting for a rescan.
    private func applyTitle(_ title: String?, autoDetected: Bool,
                            meetingId: String, paths: MeetingPaths) {
        try? storage.patchMetadata({ m in
            m.title = title
            m.titleAutoDetected = autoDetected
        }, at: paths)
        let indexer = self.indexer
        Task { await Self.offMain { try? indexer.updateTitle(id: meetingId, title: title) } }
        if let i = meetings.firstIndex(where: { $0.id == meetingId }) {
            meetings[i].title = title
        }
        if currentListing?.id == meetingId {
            currentListing?.title = title
        }
    }

    /// French, actionable messages for the failure modes a user can actually
    /// hit. The output tail matters: `claude -p` prints its own diagnostics
    /// on stdout (login expired, rate limit, …) and truncating them to a
    /// generic message would send the user hunting through Console.app.
    private static func describe(generationFailure error: Error) -> String {
        switch error {
        case ClaudeNoteGenerator.GenerationError.transcriptMissing:
            return "Impossible de générer : le transcript n'existe pas encore "
                 + "(traitement en cours ou échoué)."
        case ClaudeNoteGenerator.GenerationError.timedOut:
            return "La génération a dépassé le délai maximal (5 min) et a été interrompue."
        case ClaudeNoteGenerator.GenerationError.emptyOutput:
            return "Claude n'a produit aucune sortie. Réessaie, ou vérifie le binaire "
                 + "dans Réglages → Notes."
        case ClaudeNoteGenerator.GenerationError.authFailed(let failure, _):
            switch failure {
            case .sessionExpired:
                return "Session Claude expirée : reconnecte-toi dans Réglages → Notes."
            case .notLoggedIn:
                return "Claude n'est pas connecté : reconnecte-toi dans Réglages → Notes."
            }
        case ClaudeNoteGenerator.GenerationError.nonZeroExit(let code, let stdout, let stderr):
            // Les deux flux, stdout d'abord : le CLI y met l'essentiel de ses
            // diagnostics, stderr est souvent vide.
            let joined = (stdout + "\n" + stderr)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // The tail, not the head: the CLI's actual diagnostic (login
            // expired, rate limit, …) arrives at the end of its output.
            let tail = joined.suffix(300)
            return tail.isEmpty
                ? "Claude a échoué (code \(code))."
                : "Claude a échoué (code \(code)) : \(tail)"
        default:
            return "La génération a échoué : \(error.localizedDescription)"
        }
    }

    // MARK: - Layout

    public func toggleTranscriptPanel() { transcriptPanelHidden.toggle() }
    public func setSplitRatio(_ r: Double) {
        notesToTranscriptRatio = max(0.3, min(0.85, r))
    }

    // MARK: - Window lifecycle

    /// The viewer window was hidden (the user "closed" it — see
    /// `ViewerWindowController`, which only calls `orderOut`).
    ///
    /// Pauses playback. Without this, audio kept running with the transport off
    /// screen and no way to stop it short of quitting the app. Deliberately
    /// `pause()` and not `stop()`: the window is never really closed, so the
    /// media stays open and reopening the viewer resumes from the same position.
    public func viewerDidHide() {
        audioPlayer.pause()
    }

    // MARK: - Off-main work

    /// Runs `body` on a detached (non-main) executor and awaits its result.
    ///
    /// The whole class is `@MainActor`, so a plain `Task { }` here *inherits*
    /// the main actor and moves nothing off it — synchronous SQLite queries and
    /// file writes would still block the UI. `Task.detached` does not inherit
    /// the actor, so `body` genuinely runs on the cooperative pool; the caller
    /// suspends (it does not block) and resumes back on the main actor.
    private static func offMain<T: Sendable>(
        priority: TaskPriority = .userInitiated,
        _ body: @escaping @Sendable () -> T
    ) async -> T {
        await Task.detached(priority: priority) {
            // Not decoration: this is what makes "genuinely off the main thread"
            // a property the test suite verifies rather than one we assert in a
            // comment. Compiled out in release.
            assert(!Thread.isMainThread,
                   "ViewerStore.offMain body must not run on the main thread")
            return body()
        }.value
    }

    // MARK: - Persistence

    /// Cancels the persistence debounce and writes the latest state now.
    ///
    /// `nonisolated` on purpose: the callers are AppKit hooks that fire on the
    /// main *thread* at a point where nothing can be awaited (terminate would
    /// not wait for a `Task`), and macOS 13 has no `MainActor.assumeIsolated`.
    /// This is safe because it touches no isolated state — the Combine sink in
    /// `init` has already handed the current state to `persistence`
    /// synchronously, and `ViewerStatePersistence` is thread-safe.
    public nonisolated func flushState() {
        persistence.flush()
    }
}
