import Foundation

/// Trouve les réunions dont les notes ont été perdues à cause d'une
/// déconnexion du CLI, pour les régénérer une fois l'authentification
/// rétablie.
public enum NotesCatchUp {
    /// Motifs cherchés dans l'erreur enregistrée dans `job.json`. Cette erreur
    /// est le `String(describing:)` d'une erreur Swift, donc on reconnaît :
    /// - le nom du cas (`authFailed`) pour les échecs postérieurs au correctif
    /// - les messages bruts du CLI, au cas où ils arrivent par un autre cas
    ///   d'erreur (ex. `nonZeroExit` qui embarque désormais stdout)
    ///
    /// Les trois marqueurs bruts sont cherchés dans toute l'erreur sérialisée,
    /// sortie du CLI incluse : un faux positif est donc possible (un échec
    /// sans lien dont stdout contiendrait « not logged in »). Coût assumé —
    /// une régénération de trop, qui réussit ou se re-marque en échec.
    private static let markers = [
        "authfailed",
        "not logged in",
        "please run /login",
        "oauth session expired",
    ]

    /// Slugs à rattraper, en ordre chronologique (le slug est daté, donc l'ordre
    /// lexicographique *est* l'ordre chronologique).
    ///
    /// Chronologique et non arbitraire : le rattrapage est séquentiel, et une
    /// réunion de continuation dépend de l'absorption de son parent.
    ///
    /// Coût : un balayage du dossier de réunions + une lecture de `job.json`
    /// par réunion, en synchrone (~90 réunions aujourd'hui). Acceptable à
    /// cette échelle, mais l'appelant ne doit pas le faire sur le main actor
    /// dans une boucle — et il faudra passer par l'index SQLite si le nombre
    /// de réunions devient grand.
    public static func pendingSlugs(storage: MeetingStorage) throws -> [String] {
        let listings = try storage.listMeetings()
        var out: [String] = []
        for listing in listings {
            let paths = MeetingPaths(root: storage.root, slug: listing.slug)
            // Un job illisible est ignoré : un dossier abîmé ne doit pas
            // empêcher le rattrapage des autres.
            guard let job = try? storage.loadJob(paths) else { continue }
            guard let record = job.steps[.notes], record.status == .failed,
                  let error = record.error?.lowercased() else { continue }
            if markers.contains(where: error.contains) { out.append(listing.slug) }
        }
        return out.sorted()
    }
}
