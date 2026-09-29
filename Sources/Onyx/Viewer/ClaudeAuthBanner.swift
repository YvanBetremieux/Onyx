import SwiftUI
import RecorderCore

/// Bandeau d'alerte affiché en haut du viewer quand le CLI `claude` est
/// déconnecté, ou pendant le rattrapage des notes perdues.
///
/// Le viewer est l'endroit où l'absence de résumé se remarque — et c'est
/// précisément là qu'il ne se passait rien pendant l'incident du 2026-09-07.
struct ClaudeAuthBanner: View {
    @ObservedObject var app: AppState
    @State private var message: String?
    /// Statut pour lequel `message` a été écrit. La bannière garde son identité
    /// de vue tant que le viewer existe, donc sans cette paire un « Terminal
    /// ouvert : termine le login… » resterait en mémoire après résolution et
    /// réapparaîtrait, hors sujet, à la prochaine déconnexion — des semaines
    /// plus tard.
    @State private var messageStatus: ClaudeAuthStatus?

    /// Le message n'est affiché que s'il a été produit pour le statut courant.
    private var currentMessage: String? {
        guard messageStatus == app.claudeAuthStatus else { return nil }
        return message
    }

    private func show(_ text: String) {
        message = text
        messageStatus = app.claudeAuthStatus
    }

    var body: some View {
        if let progress = app.notesCatchUpProgress {
            row(icon: "arrow.triangle.2.circlepath", tint: .accentColor,
                text: "Rattrapage des résumés — \(progress.done)/\(progress.total)") {
                EmptyView()
            }
        } else if app.claudeAuthStatus.isDisconnected {
            row(icon: "exclamationmark.triangle.fill", tint: .orange,
                text: "Claude déconnecté — les résumés ne sont plus générés "
                    + "(\(app.claudeAuthStatus.detailLabel)).") {
                HStack(spacing: 8) {
                    Button("Se reconnecter…") { reconnect() }
                    Button("Tester") { test() }
                }
            }
        }
    }

    @ViewBuilder
    private func row<Actions: View>(icon: String, tint: Color, text: String,
                                    @ViewBuilder actions: () -> Actions) -> some View {
        VStack(spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(tint)
                Text(text).font(.callout)
                Spacer()
                actions()
            }
            if let currentMessage {
                HStack {
                    Text(currentMessage).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(tint.opacity(0.12))
    }

    private func reconnect() {
        let path = app.settings.claudeBinaryPath
        guard !path.isEmpty else {
            show("Chemin du binaire Claude non configuré (Réglages → Notes).")
            return
        }
        // `launch` est `async` — voir la note dans la tâche 8 : l'AppleScript
        // peut bloquer plusieurs secondes.
        Task {
            switch await ClaudeReconnectLauncher.launch(binary: URL(fileURLWithPath: path)) {
            case .launched:
                show("Terminal ouvert : termine le login, puis clique « Tester ».")
            case .copiedToClipboard(let cmd):
                show("Commande copiée : \(cmd)")
            }
        }
    }

    private func test() {
        show("Vérification…")
        // Le message est réattaché au statut d'après la sonde : celle-ci peut
        // justement faire basculer l'état, et le résultat doit rester lisible
        // à côté du nouveau statut plutôt que disparaître aussitôt.
        Task {
            let result = await app.checkClaudeAuth()
            show(result)
        }
    }
}
