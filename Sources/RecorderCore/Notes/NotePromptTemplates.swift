import Foundation

public enum NotePromptTemplates {
    /// Backward-compatible signature (chantier 2 call sites unchanged).
    public static func prompt(for level: NoteLevel, transcript: String) -> String {
        return prompt(for: level, transcript: transcript, liveNotes: nil)
    }

    /// New signature with optional live notes injection (chantier 3).
    /// - Parameter liveNotes: content of `notes/live.md` if non-empty. When nil
    ///   or blank, the prompt is identical to the chantier-2 output.
    public static func prompt(for level: NoteLevel,
                              transcript: String,
                              liveNotes: String?) -> String {
        prompt(for: level, transcript: transcript, liveNotes: liveNotes, detectTitle: false)
    }

    /// - Parameter detectTitle: when true, the output must start with a
    ///   `TITRE: …` line naming the meeting — used for huddles and wild
    ///   meetings, which record with no title. `ClaudeNoteGenerator` strips
    ///   that line back out of the note (see `splitDetectedTitle`).
    public static func prompt(for level: NoteLevel,
                              transcript: String,
                              liveNotes: String?,
                              detectTitle: Bool) -> String {
        let instructions: String
        switch level {
        case .live:
            // .live is never a generation target — live.md is authored by the
            // user directly. This branch exists to satisfy exhaustiveness.
            instructions = ""
        case .brief:
            instructions = """
            Niveau demandé : BRIEF.
            3 à 5 bullets. TL;DR en une phrase, décisions prises, action items \
            (avec owner si mentionné). Zéro contexte, zéro détail. ~150 mots max.
            """
        case .synthese:
            instructions = """
            Niveau demandé : SYNTHESE.
            Sections en Markdown :
            ## Contexte (2-3 phrases)
            ## Décisions
            ## Points clés discutés
            ## Action items (owner + deadline si mentionnés)
            ## Questions ouvertes

            ~500 mots. Ton neutre. Pas de verbatim, tu reformules.
            """
        case .detaillee:
            instructions = """
            Niveau demandé : DETAILLE.
            Synthèse structurée (mêmes sections que le niveau SYNTHESE) suivie \
            d'une section :
            ## Détail par thème
            avec sous-sections thématiques. Utilise des quotes verbatim \
            (entre guillemets) pour les points-clés à citer. Ajoute des \
            timestamps `[MM:SS]` pour les moments notables.

            ~1500-2000 mots.
            """
        }

        let trimmedLive = liveNotes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let liveBlock: String
        if trimmedLive.isEmpty {
            liveBlock = ""
        } else {
            liveBlock = """

            Notes prises par l'utilisateur en direct pendant le meeting :
            ---
            \(trimmedLive)
            ---

            Ces notes reflètent ce que l'utilisateur a jugé important sur le \
            moment. Intègre-les dans ta synthèse : reprends les points, décisions \
            et actions qu'il a notées, corrige-les si le transcript les \
            contredit, et complète avec ce qui manque. Ne les recopie pas mot \
            pour mot, restructure-les proprement dans la sortie demandée.

            """
        }

        let titleBlock = detectTitle ? """

        Ce meeting n'a pas de titre. Déduis-en un du contenu de la discussion. \
        La TOUTE PREMIÈRE ligne de ta sortie doit être exactement :
        TITRE: <titre court et spécifique, 60 caractères max, sans guillemets>
        puis une ligne vide, puis les notes demandées. Le titre doit nommer le \
        sujet réel du meeting (pas « Réunion d'équipe » ou « Point divers »).

        """ : ""

        return """
        Tu es un preneur de notes de meeting. Tu reçois la transcription d'un \
        meeting avec speakers identifiés :
        - "MOI" = moi-même (l'utilisateur d'Onyx)
        - "SPEAKER_N" = autres intervenants (N = 0, 1, 2, ...)

        Génère les notes en français, format Markdown.

        \(instructions)
        \(titleBlock)\(liveBlock)
        Transcript :
        \(transcript)
        """
    }
}
