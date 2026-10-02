import SwiftUI
import AppKit
import EventKit
import RecorderCore

struct SettingsWindow: View {
    @ObservedObject var settings: SettingsStore
    /// Nécessaire pour la ligne d'état Claude et la sonde d'authentification —
    /// les deux vivent dans AppState, seul détenteur du ClaudeAuthMonitor.
    @ObservedObject var app: AppState
    let storage: MeetingStorage
    let indexer: MeetingIndexer

    @State private var claudeTestResult: String = ""
    @State private var claudeTesting = false
    @State private var claudeDetecting = false
    @State private var availableCalendars: [EKCalendar] = []
    @State private var calendarAccess: CalendarAccess = CalendarAccessFlow.currentStatus()
    @State private var calendarRequesting = false

    /// Install state of each Whisper variant, keyed by asset id.
    enum ModelRowState: Equatable {
        case notInstalled
        case installed(sizeBytes: Int64)
        case downloading(progress: Double)
        case failed(message: String)
    }
    @State private var modelStates: [String: ModelRowState] = [:]

    var body: some View {
        TabView {
            generalTab.tabItem { Label("General", systemImage: "gearshape") }
            calendarTab.tabItem { Label("Calendar", systemImage: "calendar") }
            detectionTab.tabItem { Label("Detection", systemImage: "waveform") }
            notesTab.tabItem { Label("Notes", systemImage: "doc.text") }
            advancedTab.tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
        }
        .frame(width: 560, height: 460)
        .onAppear { loadCalendars(); refreshModelStates() }
        // Retour dans Onyx (p. ex. depuis Réglages Système) : l'accès a pu changer.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in loadCalendars() }
    }

    // MARK: - Tabs

    @ViewBuilder private var generalTab: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $settings.appearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
            }
            Section("Language") {
                Picker("Transcription language", selection: $settings.language) {
                    Text("Français").tag("fr")
                    Text("English").tag("en")
                    Text("Auto").tag("auto")
                }
            }
            Section("Storage") {
                LabeledContent("Meetings folder", value: settings.meetingsFolder.path)
                Button("Choose folder…") { pickFolder() }
                Button("Rescan meetings folder") {
                    let storage = self.storage
                    let indexer = self.indexer
                    Task { try? await RescanRunner(storage: storage, indexer: indexer).rescan() }
                }
            }
            Section("Startup") {
                Toggle("Open Onyx at login", isOn: $settings.launchAtLogin)
            }
            Section("Updates") {
                Toggle("Check for updates automatically", isOn: $settings.autoUpdateEnabled)
                LabeledContent("Version installée", value: app.installedVersion)
                Button("Rechercher des mises à jour…") { app.checkForUpdates() }
            }
        }
        .padding(16)
    }

    @ViewBuilder private var calendarTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Enable auto-trigger from calendar", isOn: $settings.autoTriggerEnabled)
            Text("Calendars to watch:").font(.headline)
            HStack {
                Text(calendarAccessLabel).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(calendarRequesting ? "Demande en cours…"
                                          : "Autoriser l'accès et détecter les calendriers") {
                    requestCalendarAccess()
                }
                .disabled(calendarRequesting)
            }
            if availableCalendars.isEmpty {
                Text("Aucun calendrier à afficher.")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            } else {
                ScrollView {
                    VStack(alignment: .leading) {
                        ForEach(availableCalendars, id: \.calendarIdentifier) { cal in
                            Toggle(cal.title, isOn: Binding(
                                get: { settings.enabledCalendarIds.contains(cal.calendarIdentifier) },
                                set: { on in
                                    var s = settings.enabledCalendarIds
                                    if on {
                                        if !s.contains(cal.calendarIdentifier) { s.append(cal.calendarIdentifier) }
                                    } else {
                                        s.removeAll { $0 == cal.calendarIdentifier }
                                    }
                                    settings.enabledCalendarIds = s
                                }
                            ))
                        }
                    }
                }
                .frame(maxHeight: 200)
            }
        }
        .padding(16)
    }

    @ViewBuilder private var detectionTab: some View {
        Form {
            Toggle("Detect Google Meet in browser", isOn: $settings.detectionMeetEnabled)
            Toggle("Detect Slack Huddles", isOn: $settings.detectionHuddleEnabled)
            Text("Note: Firefox and Slack web app are not detected v1.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
    }

    @ViewBuilder private var notesTab: some View {
        Form {
            Toggle("Auto-generate notes after recording", isOn: $settings.autoNotesEnabled)
            Section("Default levels") {
                // Checkboxes, not a picker: several levels can be generated at
                // once (each is its own parallel `claude -p` session).
                // `generatable`, not `allCases`: `.live` is not a level the
                // pipeline can auto-generate.
                ForEach(NoteLevel.generatable, id: \.self) { l in
                    Toggle(l.rawValue.capitalized, isOn: Binding(
                        get: { settings.defaultNoteLevels.contains(l) },
                        set: { on in
                            var s = settings.defaultNoteLevels
                            if on {
                                if !s.contains(l) { s.append(l) }
                            } else {
                                s.removeAll { $0 == l }
                            }
                            settings.defaultNoteLevels = s
                        }
                    ))
                }
                if settings.defaultNoteLevels.isEmpty {
                    Text("No level selected: nothing will be generated automatically.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Claude") {
                Picker("Model", selection: $settings.claudeModel) {
                    Text("CLI default").tag("")
                    Text("Haiku").tag("haiku")
                    Text("Sonnet").tag("sonnet")
                    Text("Opus").tag("opus")
                }
                HStack(spacing: 6) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(app.claudeAuthStatus.indicatorColor)
                    Text(app.claudeAuthStatus.shortLabel).bold()
                    Text("— \(app.claudeAuthStatus.detailLabel)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    TextField("Claude binary path", text: $settings.claudeBinaryPath)
                    // Un seul bouton, qui teste le binaire ET l'authentification.
                    // L'ancien « Test » ne lançait que `--version`, qui réussit
                    // même déconnecté : c'est ce faux positif qui a laissé
                    // l'incident du 2026-09-07 passer inaperçu deux jours.
                    Button(claudeDetecting ? "Recherche…" : "Auto-détecter") { detectClaude() }
                        .disabled(claudeDetecting || claudeTesting)
                    Button(claudeTesting ? "Test…" : "Tester") { testClaude() }
                        .disabled(claudeTesting || claudeDetecting)
                }
                if !claudeTestResult.isEmpty {
                    Text(claudeTestResult).font(.caption).foregroundStyle(.secondary)
                }
                Button("Se reconnecter à Claude…") { reconnectClaude() }
                    .disabled(settings.claudeBinaryPath.isEmpty)
            }
        }
        .padding(16)
    }

    @ViewBuilder private var advancedTab: some View {
        Form {
            Section("Micro") {
                Toggle("Annulation d'écho (traitement de la voix d'Apple)",
                       isOn: $settings.micEchoCancellation)
                Text("Retire de ton micro le son des haut-parleurs. Déconseillé : sur "
                     + "certains Mac, ça baisse le micro de toutes les autres apps "
                     + "(Meet, Slack…) pendant l'enregistrement. Sans, les doublons "
                     + "d'écho sont filtrés dans le transcript ; avec un casque, aucun écho.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Transcription") {
                Picker("Whisper model", selection: $settings.whisperModel) {
                    Text("Large-v3 Turbo — rapide (recommandé)")
                        .tag(ModelManifest.whisperLargeV3Turbo.id)
                    Text("Large-v3 — qualité maximale")
                        .tag(ModelManifest.whisperLargeV3.id)
                }
                Text("Turbo est ~4-6× plus rapide pour une qualité quasi "
                     + "identique. Un modèle absent est de toute façon "
                     + "téléchargé automatiquement à la première transcription.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(ModelLibrary.whisperVariants, id: \.id) { asset in
                    modelRow(asset)
                }
            }
            Section("Live transcription") {
                Toggle("Transcribe in chunks while recording",
                       isOn: $settings.chunkedTranscriptionEnabled)
                if settings.chunkedTranscriptionEnabled {
                    HStack {
                        Slider(value: Binding(
                            get: { Double(settings.chunkMinutes) },
                            set: { settings.chunkMinutes = Int($0.rounded()) }
                        ), in: 1...20, step: 1) {
                            Text("Chunk duration")
                        }
                        Text("\(settings.chunkMinutes) min")
                            .font(.system(size: 12, design: .monospaced))
                            .frame(width: 52, alignment: .trailing)
                    }
                    Text("Whisper reste chargé pendant l'enregistrement et chaque "
                         + "tranche est transcrite en direct : le transcript est prêt "
                         + "quelques minutes après la fin au lieu de ~0,5× la durée. "
                         + "Machine modeste : monte la durée des chunks pour alléger "
                         + "la charge pendant la réunion.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Toggle("Auto-trigger master switch", isOn: $settings.autoTriggerEnabled)
            Button("Reset onboarding (V1 + V2)") {
                UserDefaults.standard.removeObject(forKey: "onboardingDone")
                UserDefaults.standard.removeObject(forKey: "onboardingV2Done")
            }
        }
        .padding(16)
    }

    // MARK: - Model management

    private static let sizeFmt: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    private func shortName(_ asset: ModelAsset) -> String {
        asset.id == ModelManifest.whisperLargeV3Turbo.id ? "Large-v3 Turbo" : "Large-v3"
    }

    @ViewBuilder private func modelRow(_ asset: ModelAsset) -> some View {
        let state = modelStates[asset.id] ?? .notInstalled
        HStack(spacing: 8) {
            Text(shortName(asset)).font(.system(size: 12))
            if settings.whisperModel == asset.id {
                Text("actif")
                    .font(.system(size: 9.5, weight: .semibold))
                    .padding(.horizontal, 5).padding(.vertical, 1.5)
                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    .foregroundStyle(Color.accentColor)
            }
            Spacer()
            switch state {
            case .installed(let size):
                Text(Self.sizeFmt.string(fromByteCount: size))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                Button("Supprimer") { deleteModel(asset) }
                    .controlSize(.small)
            case .notInstalled:
                Text("Non téléchargé")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                Button("Télécharger") { downloadModel(asset) }
                    .controlSize(.small)
            case .downloading(let p):
                ProgressView(value: p).frame(width: 90)
                Text("\(Int(p * 100)) %")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Text(message)
                    .font(.system(size: 10.5)).foregroundStyle(.red)
                    .lineLimit(1).help(message)
                Button("Réessayer") { downloadModel(asset) }
                    .controlSize(.small)
            }
        }
    }

    private func refreshModelStates() {
        for asset in ModelLibrary.whisperVariants {
            // Never clobber an in-flight download's progress display.
            if case .downloading = modelStates[asset.id] ?? .notInstalled { continue }
            if let size = ModelLibrary.installedSizeBytes(asset) {
                modelStates[asset.id] = .installed(sizeBytes: size)
            } else {
                modelStates[asset.id] = .notInstalled
            }
        }
    }

    private func downloadModel(_ asset: ModelAsset) {
        modelStates[asset.id] = .downloading(progress: 0)
        Task {
            do {
                try await ModelLibrary.downloadWhisperIfNeeded(asset) { p in
                    Task { @MainActor in
                        if case .downloading = modelStates[asset.id] ?? .notInstalled {
                            modelStates[asset.id] = .downloading(progress: p)
                        }
                    }
                }
                await MainActor.run {
                    modelStates[asset.id] = nil
                    refreshModelStates()
                }
            } catch {
                await MainActor.run {
                    modelStates[asset.id] = .failed(
                        message: "Échec : \(error.localizedDescription)")
                }
            }
        }
    }

    private func deleteModel(_ asset: ModelAsset) {
        try? ModelLibrary.delete(asset)
        refreshModelStates()
    }

    // MARK: - Actions

    private func pickFolder() {
        let p = NSOpenPanel()
        p.canChooseFiles = false; p.canChooseDirectories = true
        p.allowsMultipleSelection = false
        if p.runModal() == .OK, let url = p.url { settings.meetingsFolder = url }
    }

    private func loadCalendars() {
        calendarAccess = CalendarAccessFlow.currentStatus()
        // Best-effort — returns empty if permission not granted, which is fine.
        availableCalendars = EKEventStore().calendars(for: .event)
    }

    private var calendarAccessLabel: String {
        switch calendarAccess {
        case .granted:
            return availableCalendars.isEmpty
                ? "Accès accordé, mais aucun calendrier sur ce Mac (comptes : Réglages Système → Comptes internet)."
                : "Accès aux calendriers accordé."
        case .notDetermined: return "Onyx n'a pas encore demandé l'accès aux calendriers."
        case .denied: return "Accès aux calendriers refusé."
        }
    }

    /// Redemande l'accès — y compris après un refus, en effaçant d'abord la
    /// décision enregistrée (voir `CalendarAccessFlow`) — puis recharge la liste.
    private func requestCalendarAccess() {
        calendarRequesting = true
        let bundleId = Bundle.main.bundleIdentifier ?? "com.yvanbetremieux.onyx"
        Task {
            _ = await CalendarAccessFlow.live(bundleIdentifier: bundleId).ensureAccess()
            loadCalendars()
            calendarRequesting = false
        }
    }

    /// Cherche le binaire (chemins connus puis PATH du shell de l'utilisateur).
    /// Trouvé → on remplit le champ et on enchaîne sur le test complet, pour
    /// que le résultat affiché dise aussi si la connexion Claude est bonne.
    private func detectClaude() {
        claudeDetecting = true
        claudeTestResult = "Recherche du binaire Claude…"
        Task {
            let found = await ClaudeBinaryLocator().locate()
            claudeDetecting = false
            guard let found else {
                claudeTestResult = "Claude introuvable — colle le chemin manuellement "
                                 + "(`which claude` dans un terminal)."
                return
            }
            settings.claudeBinaryPath = found.path
            testClaude()
        }
    }

    /// Vérifie d'abord que le binaire répond (`--version`), puis que
    /// l'authentification passe (vraie mini-requête). Les deux comptent : un
    /// binaire présent mais déconnecté ne génère aucune note.
    private func testClaude() {
        let path = settings.claudeBinaryPath
        guard !path.isEmpty else { claudeTestResult = "Chemin vide."; return }
        claudeTesting = true
        claudeTestResult = "Vérification du binaire…"
        Task {
            let version = await Self.claudeVersion(at: path)
            switch version {
            case .failure(let message):
                claudeTestResult = message
                claudeTesting = false
            case .success(let v):
                claudeTestResult = "Binaire OK (\(v)) — vérification de la connexion…"
                let authMessage = await app.checkClaudeAuth()
                claudeTestResult = "Binaire OK (\(v)). \(authMessage)"
                claudeTesting = false
            }
        }
    }

    /// Swift's `Result` requires its failure type to conform to `Error`, which
    /// plain `String` does not — so this uses a small local enum instead of
    /// `Result<String, String>` (as written in the plan) to carry a
    /// human-readable failure message without wrapping it in an `Error`.
    private enum ClaudeVersionOutcome {
        case success(String)
        case failure(String)
    }

    private static func claudeVersion(at path: String) async -> ClaudeVersionOutcome {
        await Task.detached { () -> ClaudeVersionOutcome in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = ["--version"]
            let out = Pipe(); p.standardOutput = out; p.standardError = out
            do {
                try p.run()
                p.waitUntilExit()
                let data = (try? out.fileHandleForReading.readToEnd()) ?? Data()
                let s = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return p.terminationStatus == 0
                    ? .success(s)
                    : .failure("Exit \(p.terminationStatus) : \(s)")
            } catch {
                return .failure("Lancement impossible : \(error.localizedDescription)")
            }
        }.value
    }

    private func reconnectClaude() {
        let binary = URL(fileURLWithPath: settings.claudeBinaryPath)
        // `launch` est `async` : l'AppleScript qui pilote Terminal peut bloquer
        // plusieurs secondes (dialogue d'autorisation Automation, lancement de
        // Terminal), et le faire sur le main actor gèlerait toute l'app.
        Task {
            switch await ClaudeReconnectLauncher.launch(binary: binary) {
            case .launched:
                claudeTestResult = "Terminal ouvert : termine le login, puis clique « Tester »."
            case .copiedToClipboard(let cmd):
                claudeTestResult = "Commande copiée : \(cmd) — lance-la dans un terminal."
            }
        }
    }
}
