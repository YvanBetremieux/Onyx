import Foundation
import EventKit

public enum CalendarAccess: Equatable, Sendable {
    case notDetermined
    case denied
    case granted
}

/// Obtient l'accès en lecture aux calendriers, y compris après un refus.
///
/// Une décision enregistrée par TCC (refus, ou accès « écriture seule ») ne
/// redonne jamais le dialogue système, et Réglages Système ne permet pas
/// d'ajouter une app à la main dans la liste Calendriers : la seule issue est
/// d'effacer la décision d'Onyx (`tccutil reset`) avant de redemander.
public struct CalendarAccessFlow: Sendable {
    public var status: @Sendable () -> CalendarAccess
    public var resetDecision: @Sendable () async -> Void
    public var request: @Sendable () async -> Bool

    public init(status: @escaping @Sendable () -> CalendarAccess,
                resetDecision: @escaping @Sendable () async -> Void,
                request: @escaping @Sendable () async -> Bool) {
        self.status = status
        self.resetDecision = resetDecision
        self.request = request
    }

    /// Le statut final, une fois le dialogue éventuel répondu.
    public func ensureAccess() async -> CalendarAccess {
        switch status() {
        case .granted:
            return .granted
        case .denied:
            await resetDecision()
            _ = await request()
            return status()
        case .notDetermined:
            _ = await request()
            return status()
        }
    }

    /// Par valeur brute : `.fullAccess`/`.writeOnly` n'existent qu'à partir de
    /// macOS 14 alors que la cible est macOS 13 (3 = authorized = fullAccess).
    static func map(rawStatus: Int) -> CalendarAccess {
        switch rawStatus {
        case 0: return .notDetermined
        case 3: return .granted
        default: return .denied   // restricted, denied, writeOnly, inconnu
        }
    }

    public static func currentStatus() -> CalendarAccess {
        map(rawStatus: EKEventStore.authorizationStatus(for: .event).rawValue)
    }

    /// L'implémentation réelle (TCC + EventKit) pour l'app `bundleIdentifier`.
    public static func live(bundleIdentifier: String) -> CalendarAccessFlow {
        CalendarAccessFlow(
            status: { currentStatus() },
            resetDecision: { await resetTCC(service: "Calendar", bundleIdentifier: bundleIdentifier) },
            request: { await CalendarWatcher().requestAccess() })
    }

    /// `tccutil reset <service> <bundle id>` : n'efface que la décision de
    /// cette app, sans droits admin. Bloquant → hors du pool coopératif.
    static func resetTCC(service: String, bundleIdentifier: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
                process.arguments = ["reset", service, bundleIdentifier]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                if (try? process.run()) != nil { process.waitUntilExit() }
                continuation.resume()
            }
        }
    }
}
