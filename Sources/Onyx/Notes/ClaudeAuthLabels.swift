import SwiftUI
import RecorderCore

/// Libellés français d'un `ClaudeAuthStatus`, partagés par les trois surfaces
/// d'UI (réglages, bannière, menu) pour qu'elles ne puissent pas se
/// contredire.
extension ClaudeAuthStatus {
    var shortLabel: String {
        switch self {
        case .unknown: return "État inconnu"
        case .connected: return "Connecté"
        case .disconnected: return "Déconnecté"
        }
    }

    var detailLabel: String {
        switch self {
        case .unknown:
            return "aucune génération de notes depuis le dernier lancement"
        case .connected(let checkedAt):
            return "vérifié \(Self.relative(checkedAt))"
        case .disconnected(let failure, let since):
            return "\(failure.frenchCause) depuis \(Self.relative(since))"
        }
    }

    var indicatorColor: Color {
        switch self {
        case .unknown: return .secondary
        case .connected: return .green
        case .disconnected: return .orange
        }
    }

    /// Formateur partagé plutôt que reconstruit à chaque rendu : `detailLabel`
    /// est lu par la bannière du viewer, qui se redessine à chaque publication
    /// de l'état. `fr_FR` en dur suit la convention du reste de l'app (voir
    /// `MeetingRow`, `MeetingsSidebar`, `MeetingHeaderView`) : l'UI d'Onyx est
    /// francophone, pas localisée.
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.unitsStyle = .full
        return f
    }()

    private static func relative(_ date: Date) -> String {
        relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}

extension ClaudeAuthFailure {
    /// Groupe nominal partagé par toutes les surfaces qui décrivent cet état
    /// (réglages, bannière, menu, notification). Une seule formulation par
    /// cause : sans ça, chaque surface réécrit la sienne et elles divergent au
    /// premier changement de libellé.
    var frenchCause: String {
        switch self {
        case .sessionExpired: return "session expirée"
        case .notLoggedIn: return "non connecté"
        }
    }
}
