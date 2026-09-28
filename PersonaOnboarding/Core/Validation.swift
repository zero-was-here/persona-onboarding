import Foundation

/// Deterministic guardrails around what the LLM extracts. The model is good at understanding
/// messy language; code is responsible for never storing garbage.
public enum Validation {
    private static let junkNames: Set<String> = [
        "none", "null", "nil", "n/a", "na", "no", "nope", "idk", "dunno", "whatever", "nothing", "no one",
        "nobody", "anonymous", "skip", "pass", "user", "assistant", "ai", "bot", "unknown", "test", "name",
        "my name", "your name", "none of your business", "not telling", "?"
    ]

    /// Cleans a spoken/typed name. Returns nil if it isn't a usable name.
    public static func cleanName(_ raw: String?) -> String? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        // Strip surrounding quotes/punctuation the model sometimes keeps.
        let strip = CharacterSet(charactersIn: "\"'“”‘’.,!?;:()[]{}<>*_~`")
        s = s.trimmingCharacters(in: strip.union(.whitespacesAndNewlines))
        // Drop lead-ins like "call me", "it's", "my name is".
        let leadIns = ["my name is ", "call me ", "it's ", "its ", "i'm ", "im ", "i am ", "name's ", "you can call me "]
        let lower = s.lowercased()
        for lead in leadIns where lower.hasPrefix(lead) {
            s = String(s.dropFirst(lead.count))
            break
        }
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        guard !s.isEmpty, s.count <= 40 else { return nil }
        guard !junkNames.contains(s.lowercased()) else { return nil }
        // Must contain at least one letter (any script — Arabic, Latin, CJK…).
        guard s.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) else { return nil }
        // Only letters, marks, spaces and a little punctuation: no markup, code, emails or URLs.
        let allowed = CharacterSet.letters.union(.nonBaseCharacters).union(.whitespaces).union(CharacterSet(charactersIn: "-'’."))
        guard s.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        // Names are short: at most 4 words.
        guard s.split(separator: " ").count <= 4 else { return nil }
        // Capitalize the first letter of each word if the user typed all lowercase.
        if s == s.lowercased() {
            s = s.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        }
        return s
    }

    /// Cleans a help-need summary. Keeps it short and non-empty.
    public static func cleanHelpNeed(_ raw: String?) -> String? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        let lower = s.lowercased()
        let vague: Set<String> = ["idk", "nothing", "none", "null", "n/a", "not sure", "dunno", "whatever", "everything", "anything", "stuff", "help"]
        guard !vague.contains(lower), s.count >= 3 else { return nil }
        if s.count > 160 { s = String(s.prefix(157)) + "…" }
        return s.prefix(1).uppercased() + s.dropFirst()
    }

    /// Speech-to-text often mangles names ("Ayman" → "Amen") even when the voice model heard them right.
    /// Once the name is known, swap the closest-sounding word in a caption for it. Returns nil if nothing fits.
    public static func replacingSimilarName(in text: String, with name: String) -> String? {
        let target = name.lowercased()
        guard target.count >= 3, !text.lowercased().contains(target) else { return nil }
        let cues: Set<String> = ["me", "i'm", "im", "is", "name", "call", "it's", "c'est", "appelle", "suis", "llamo", "soy", "sono"]
        let tokens = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        var best: (index: Int, distance: Int)?
        for (i, raw) in tokens.enumerated() {
            let word = raw.trimmingCharacters(in: .punctuationCharacters).lowercased()
            guard word.count >= 3, word.allSatisfy(\.isLetter) else { continue }
            let d = levenshtein(word, target)
            let previous = i > 0 ? tokens[i - 1].trimmingCharacters(in: .punctuationCharacters).lowercased() : ""
            // Right after "call me" / "I'm" / "my name is", the next word is almost surely the name.
            let cued = cues.contains(previous)
            let limit = (word.first == target.first ? 2 : 1) + (cued ? 1 : 0) + (cued && abs(word.count - target.count) <= 1 ? 1 : 0)
            if d <= limit, d < (best?.distance ?? .max) { best = (i, d) }
        }
        guard let hit = best else { return nil }
        var out = tokens
        let raw = tokens[hit.index]
        let leading = raw.prefix(while: { $0.isPunctuation })
        let trailing = String(raw.reversed().prefix(while: { $0.isPunctuation }).reversed())
        out[hit.index] = leading + name + trailing
        return out.joined(separator: " ")
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }

    public static func isValidEmail(_ raw: String) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = "^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}$"
        return s.range(of: pattern, options: .regularExpression) != nil
    }

    public static func normalizedEmail(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return isValidEmail(s) ? s : nil
    }
}
