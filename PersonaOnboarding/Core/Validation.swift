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
