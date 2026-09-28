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

    /// Did the user actually say (or type) this name? True if it, or something close to it, appears in any
    /// of `texts`: same letters ignoring case and accents, spelled out ("A-H-M-E-D"), a small typo, or
    /// a same-sounding spelling (Soundex: "Siobhan" / "Shivon"). Loose on purpose: it only has to catch
    /// names nobody said, which the voice model can "hear" in background noise.
    public static func nameWasHeard(_ name: String, in texts: [String]) -> Bool {
        let parts = fold(name).split(whereSeparator: { !$0.isLetter }).map(String.init).filter { $0.count >= 2 }
        guard let target = parts.first else { return true }
        for text in texts {
            var words = fold(text).split(whereSeparator: { !$0.isLetter }).map(String.init)
            // Spelled out letter by letter ("A-H-M-E-D", "a h m e d"): join runs of single letters.
            var run = ""
            for w in words + [""] {
                if w.count == 1 { run += w } else { if run.count >= 2 { words.append(run) }; run = "" }
            }
            for word in words where word.count >= 2 {
                if levenshtein(word, target) <= (target.count <= 4 ? 1 : 2) { return true }
                if target.count >= 5, word.first == target.first, let a = soundex(word), a == soundex(target) { return true }
            }
        }
        return false
    }

    static func fold(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil).lowercased()
    }

    /// Classic American Soundex for Latin letters (nil for other scripts).
    static func soundex(_ s: String) -> String? {
        let codes: [Character: Character] = [
            "b": "1", "f": "1", "p": "1", "v": "1",
            "c": "2", "g": "2", "j": "2", "k": "2", "q": "2", "s": "2", "x": "2", "z": "2",
            "d": "3", "t": "3", "l": "4", "m": "5", "n": "5", "r": "6",
        ]
        let letters = Array(fold(s).filter { $0.isASCII && $0.isLetter })
        guard let first = letters.first else { return nil }
        var out = String(first)
        var last = codes[first]
        for c in letters.dropFirst() {
            let code = codes[c]
            if let code, code != last { out.append(code) }
            if c != "h" && c != "w" { last = code }
            if out.count == 4 { break }
        }
        return out.padding(toLength: 4, withPad: "0", startingAt: 0)
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
