import Foundation

/// Les deux façons dont le CLI `claude` annonce qu'il n'est plus authentifié.
/// Distinguées parce que le message affiché à l'utilisateur diffère : une
/// session expirée est passive (rien à se reprocher), un « not logged in »
/// signifie que les identifiants ont carrément disparu du trousseau.
public enum ClaudeAuthFailure: String, Codable, Equatable, Sendable {
    case notLoggedIn
    case sessionExpired
}

public enum ClaudeAuthClassifier {
    // Motifs observés sur `claude` 2.1.220 lors de l'incident du 2026-09-07.
    private static let expiredMarkers = [
        "oauth session expired",
        "failed to authenticate",
    ]
    private static let notLoggedInMarkers = [
        "not logged in",
        "please run /login",
        "please run `/login`",
    ]

    /// - Returns: `nil` quand l'échec n'est **pas** un problème
    ///   d'authentification (timeout, quota, clé invalide, sortie vide).
    ///
    /// Lit stdout **et** stderr : le CLI écrit ses diagnostics d'auth sur
    /// stdout aujourd'hui, mais ce détail a déjà changé et ne fait pas partie
    /// de son contrat public.
    ///
    /// Limite réelle : cette détection repose sur des sous-chaînes figées. Un
    /// vrai échec d'auth dont le libellé ne correspond à aucun marqueur
    /// retournera aussi `nil`, indiscernable d'un échec non lié à l'auth —
    /// exactement le mode de défaillance de l'incident d'origine (message non
    /// reconnu → traité comme un échec ordinaire). Mettre à jour les listes
    /// de marqueurs dès que le CLI change sa formulation.
    public static func classify(exitCode: Int32, stdout: String,
                                stderr: String) -> ClaudeAuthFailure? {
        guard exitCode != 0 else { return nil }
        let haystack = (stdout + "\n" + stderr).lowercased()
        // L'expiration d'abord : c'est le diagnostic le plus spécifique, et un
        // futur message pourrait contenir les deux familles de motifs.
        if expiredMarkers.contains(where: haystack.contains) { return .sessionExpired }
        if notLoggedInMarkers.contains(where: haystack.contains) { return .notLoggedIn }
        return nil
    }
}
