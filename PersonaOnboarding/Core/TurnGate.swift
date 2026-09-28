import Foundation

/// Decides whether the voice agent should answer a finished caller turn.
///
/// Turn detection sometimes fires on background noise (a fan, a TV, the room around a Mac or an
/// iPhone on speaker). If the model answers that, it invents what it "heard": "Nice to meet you, Alex!"
/// with nobody talking. So the server doesn't answer turns by itself; the app asks for a reply only
/// once speech-to-text confirms real words. A turn with no words gets an honest "Sorry, I didn't catch
/// that?" (rate-limited), lets the agent pick up where it was cut off, or is ignored.
public struct TurnGate: Sendable {
    public enum Decision: Equatable, Sendable {
        /// Real words: answer normally.
        case respond
        /// No words, the caller seems to have tried: say you didn't catch it. Never guess.
        case sayUnclear
        /// No words, but it cut the agent off mid-sentence: carry on from there.
        case resume
        /// No words again (steady noise): stay quiet, don't treat it as the caller talking.
        case ignore
    }

    /// Wordless turns in a row since the caller last said something real.
    public private(set) var noiseStreak = 0
    private var lastUnclear: Date?

    /// Most wordless turns answered in a row (steady noise shouldn't make the agent chatter).
    public static let maxNoiseReplies = 2
    /// "Didn't catch that" at most this often.
    public static let unclearCooldown: TimeInterval = 15

    public init() {}

    /// True if speech-to-text returned actual words. Annotations like "[noise]" or "(coughs)" don't count,
    /// and neither does the multilingual gibberish it produces for unintelligible audio, which mixes
    /// writing systems inside a single word ("अबneamth wahمسل"). Normal code-switching ("salam, I'm
    /// Ahmed", "سلام I'm Ahmed") keeps each word in one script, so it still counts.
    public static func hasWords(_ heard: String) -> Bool {
        var s = heard
        for pattern in ["\\[[^\\]]*\\]", "\\([^)]*\\)", "\\*[^*]*\\*", "<[^>]*>"] {
            s = s.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        guard s.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) }) else { return false }
        var scriptsInUtterance = Set<Int>()
        for word in s.split(whereSeparator: { $0.isWhitespace }) {
            let scripts = Set(word.unicodeScalars.compactMap { script($0) })
            if scripts.count > 1 { return false }
            scriptsInUtterance.formUnion(scripts)
        }
        return scriptsInUtterance.count <= 2
    }

    /// A coarse writing-system id for a letter (nil for anything that isn't a letter).
    private static func script(_ u: Unicode.Scalar) -> Int? {
        guard CharacterSet.letters.contains(u) else { return nil }
        switch u.value {
        case 0x41...0x24F, 0x1E00...0x1EFF: return 1                                            // Latin
        case 0x370...0x3FF: return 2                                                            // Greek
        case 0x400...0x52F: return 3                                                            // Cyrillic
        case 0x590...0x5FF: return 4                                                            // Hebrew
        case 0x600...0x6FF, 0x750...0x77F, 0x8A0...0x8FF, 0xFB50...0xFDFF, 0xFE70...0xFEFF: return 5  // Arabic
        case 0x900...0x97F: return 6                                                            // Devanagari
        case 0xE00...0xE7F: return 7                                                            // Thai
        case 0x1100...0x11FF, 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF: return 8  // CJK
        default: return 100 + Int(u.value >> 7)
        }
    }

    /// `heard` is the transcript of the finished turn; `interruptedAgent` is whether it cut the agent off.
    public mutating func decide(heard: String, interruptedAgent: Bool, now: Date = Date()) -> Decision {
        decide(heardWords: Self.hasWords(heard), interruptedAgent: interruptedAgent, now: now)
    }

    public mutating func decide(heardWords: Bool, interruptedAgent: Bool, now: Date = Date()) -> Decision {
        if heardWords {
            noiseStreak = 0
            return .respond
        }
        noiseStreak += 1
        guard noiseStreak <= Self.maxNoiseReplies else { return .ignore }
        if interruptedAgent { return .resume }
        if let last = lastUnclear, now.timeIntervalSince(last) < Self.unclearCooldown { return .ignore }
        lastUnclear = now
        return .sayUnclear
    }
}

/// Caller turns on the line that haven't been answered yet, keyed by the server's item id
/// (shared by the app's RealtimeVoice and the call simulator, so both behave the same).
public struct PendingTurns: Sendable {
    public enum Heard: Equatable, Sendable { case pending, words, noWords }
    private var turns: [String: Heard] = [:]
    private var partial: [String: String] = [:]
    private var cutAgentOff = false

    public init() {}
    public var isEmpty: Bool { turns.isEmpty }

    /// Turn detection heard the caller start. Returns true if it's the first turn since the last answer.
    @discardableResult
    public mutating func started(_ item: String, agentBusy: Bool) -> Bool {
        let first = turns.isEmpty
        if first { cutAgentOff = false }
        if agentBusy { cutAgentOff = true }
        turns[item] = .pending
        return first
    }

    public mutating func partialTranscript(_ item: String, _ delta: String) {
        partial[item, default: ""] += delta
    }

    /// The turn's audio was committed. If live captions already caught words, no need to wait for the rest.
    public mutating func committed(_ item: String) {
        if turns[item] == .pending, TurnGate.hasWords(partial[item] ?? "") { turns[item] = .words }
    }

    /// Speech-to-text finished. Returns whether it heard words.
    @discardableResult
    public mutating func transcribed(_ item: String, _ text: String) -> Bool {
        partial[item] = nil
        let words = TurnGate.hasWords(text)
        if turns[item] != nil { turns[item] = words ? .words : .noWords }
        return words
    }

    /// Speech-to-text failed or is too slow: can't tell, so trust the voice model.
    public mutating func failed(_ item: String) {
        partial[item] = nil
        if turns[item] != nil { turns[item] = .words }
    }

    public mutating func timedOut() {
        for (item, heard) in turns where heard == .pending { turns[item] = .words }
    }

    /// Once nothing is waiting on speech-to-text: whether any turn had words, and whether one cut the
    /// agent off. Clears the turns. Nil while a transcript is still pending.
    public mutating func takeReady() -> (heardWords: Bool, cutAgentOff: Bool)? {
        guard !turns.isEmpty, !turns.values.contains(.pending) else { return nil }
        let result = (heardWords: turns.values.contains(.words), cutAgentOff: cutAgentOff)
        turns.removeAll()
        cutAgentOff = false
        return result
    }

    public mutating func reset() {
        turns.removeAll()
        partial.removeAll()
        cutAgentOff = false
    }
}
