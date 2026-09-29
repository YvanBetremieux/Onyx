import AppKit
import Foundation
import RecorderCore

/// Ouvre un vrai terminal sur `claude /login`. Le flux de login est interactif
/// (TUI + navigateur) : Onyx ne peut pas le faire à sa place, seulement
/// l'amorcer.
@MainActor
enum ClaudeReconnectLauncher {
    enum Outcome {
        /// Terminal ouvert : à l'utilisateur de finir le login.
        case launched
        /// Aucun terminal n'a pu être ouvert, la commande est dans le
        /// presse-papier.
        case copiedToClipboard(String)
    }

    static func launch(binary: URL) async -> Outcome {
        let command = "\(shellQuoted(binary.path)) /login"

        // 1. AppleScript. Onyx utilise déjà osascript (détection Meet) et
        //    déclare NSAppleEventsUsageDescription.
        //
        //    `NSAppleScript.executeAndReturnError` est synchrone et peut
        //    bloquer plusieurs secondes (lancement de Terminal, ou boîte de
        //    dialogue d'autorisation Automation en attente) : on la sort du
        //    MainActor pour éviter le beachball, même pattern que
        //    `BrowserAutomationView` pour ses appels osascript.
        //
        //    Cas limite tracé en revue : un chemin de binaire contenant un
        //    retour à la ligne littéral rendrait la source AppleScript
        //    invalide et ferait échouer cet appel — sans risque, puisque ça
        //    retombe simplement sur le repli .command, où le guillemet
        //    simple du shell gère ce caractère sans problème.
        let appleScriptSource = """
            tell application "Terminal"
                activate
                do script "\(appleScriptQuoted(command))"
            end tell
            """
        let terminalOpened = await Task.detached {
            runAppleScript(appleScriptSource)
        }.value
        if terminalOpened {
            return .launched
        }

        // 2. Repli : un script .command ouvert par le Finder. Aucune
        //    autorisation Automation requise — c'est ce qui sauve la situation
        //    quand l'utilisateur a refusé la permission une fois pour toutes.
        if let script = writeCommandScript(command) {
            NSWorkspace.shared.open(script)
            return .launched
        }

        // 3. Dernier recours : la commande, à coller soi-même.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        return .copiedToClipboard(command)
    }

    // MARK: - Détails

    /// `nonisolated` : appelée depuis `Task.detached` en dehors du
    /// MainActor, précisément pour ne pas bloquer l'UI pendant l'attente
    /// éventuelle d'une autorisation Automation.
    nonisolated private static func runAppleScript(_ source: String) -> Bool {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return false }
        script.executeAndReturnError(&error)
        if let error {
            // -1743 = l'utilisateur n'a pas accordé l'autorisation Automation.
            Log.ui.warning(
                "Terminal AppleScript failed: \(String(describing: error), privacy: .public)")
            return false
        }
        return true
    }

    private static func writeCommandScript(_ command: String) -> URL? {
        // Nom fixe, réécrit à chaque appel : ce bouton peut être cliqué
        // plusieurs fois (ex. après un premier login raté), et un nom
        // aléatoire par appel laisserait s'accumuler des scripts orphelins
        // dans le répertoire temporaire sans qu'aucune ancienne copie n'ait
        // de valeur à conserver.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-claude-login.command")
        let body = """
        #!/bin/bash
        echo "Onyx : reconnexion à Claude. Termine le login, puis ferme cette fenêtre."
        \(command)
        """
        do {
            try body.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                  ofItemAtPath: url.path)
            return url
        } catch {
            Log.ui.error(
                "Could not write .command fallback: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Échappe un chemin pour le shell (le binaire vit sous
    /// ~/.nvm/versions/node/…, mais un chemin à espaces doit marcher).
    private static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Échappe pour une chaîne littérale AppleScript.
    private static func appleScriptQuoted(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
