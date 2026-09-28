import Foundation

/// A cheap, offline guess at the language someone is speaking, used to keep the voice agent in that
/// language after English system messages and tool results. Returns "English" only when English is
/// clearly dominant, and nil when there isn't enough signal (keep whatever we had).
public enum LanguageGuess {
    private static let markers: [(String, Set<String>)] = [
        ("French", ["je", "j'ai", "tu", "vous", "est", "et", "le", "la", "les", "des", "pour", "avec", "mes", "mon", "ma", "bonjour", "salut", "oui", "merci", "appelle", "m'appelle", "aide", "rendez", "c'est", "pas", "suis", "voudrais", "j'aimerais", "moi", "gérer", "ouais", "d'accord", "toi", "ça", "très", "bien", "aussi", "mais"]),
        ("Spanish", ["hola", "yo", "soy", "quiero", "necesito", "gracias", "mis", "por", "para", "llamo", "ayuda", "correo", "sí", "los", "las", "una", "que", "está", "bueno", "vale"]),
        ("German", ["ich", "bin", "heiße", "und", "nicht", "danke", "hallo", "bitte", "meine", "mein", "hilfe", "der", "die", "das", "ist", "ja", "genau"]),
        ("Portuguese", ["olá", "oi", "eu", "sou", "quero", "preciso", "obrigado", "obrigada", "meu", "minha", "ajuda", "chamo", "você", "não", "tudo", "bem"]),
        ("Italian", ["ciao", "sono", "chiamo", "voglio", "grazie", "aiuto", "della", "non", "io", "vorrei", "posso"]),
    ]
    private static let english: Set<String> = ["i", "i'm", "the", "and", "to", "my", "is", "it", "you", "with", "for", "me", "a", "of", "help", "want", "need", "yes", "no", "call", "name", "can", "just", "that", "what", "sure", "okay", "yeah", "please", "thanks"]

    public static func guess(_ text: String) -> String? {
        if text.unicodeScalars.contains(where: { (0x0600...0x06FF).contains($0.value) }) { return "Arabic" }
        let words = text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .split(whereSeparator: { !$0.isLetter && $0 != "'" })
            .map(String.init)
        guard words.count >= 2 else { return nil }
        let en = words.filter(english.contains).count
        var best: (lang: String, hits: Int)?
        for (lang, set) in markers {
            let hits = words.filter(set.contains).count
            if hits > (best?.hits ?? 0) { best = (lang, hits) }
        }
        if let b = best, b.hits >= 2, b.hits > en { return b.lang }
        if en >= 2, en > (best?.hits ?? 0) { return "English" }
        return nil
    }
}
