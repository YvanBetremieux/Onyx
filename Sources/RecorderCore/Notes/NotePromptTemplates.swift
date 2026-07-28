import Foundation

public enum NotePromptTemplates {
    /// Returns the full prompt (system + instructions + transcript) for the given
    /// level, with `{{TRANSCRIPT}}` already replaced by the provided transcript.
    public static func prompt(for level: NoteLevel, transcript: String) -> String {
        let instructions: String
        switch level {
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

        return """
        Tu es un preneur de notes de meeting. Tu reçois la transcription d'un \
        meeting avec speakers identifiés :
        - "MOI" = moi-même (l'utilisateur d'Onyx)
        - "SPEAKER_N" = autres intervenants (N = 0, 1, 2, ...)

        Génère les notes en français, format Markdown.

        \(instructions)

        Transcript :
        \(transcript)
        """
    }
}
