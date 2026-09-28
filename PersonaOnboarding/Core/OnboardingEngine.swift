import Foundation

public struct OnboardingState: Codable, Equatable, Sendable {
    public var profile = OnboardingProfile()
    public var phase: Phase = .naming
    public var call = CallInfo()
    public var transcript: [Message] = []
    public var gmailCardVisible = false
    public var gmailPromptCount = 0
    public var namingDeflections = 0
    public var skipRequests = 0
    public var graduatedEarly = false
    public var graduatedAt: Date?
    /// Non-English language the user is speaking (nil = English / not sure yet).
    public var spokenLanguage: String?
    /// Things the user asked for mid-onboarding that the agent promised to do in the chat afterwards.
    public var laterRequests: [String]?
    public var startedAt = Date()
    public var log: [String] = []

    public init() {}
}

public enum OnboardingEvent: Equatable, Sendable {
    case start
    case userMessage(String)
    case textBrainReplied(TextTurn)
    case textBrainFailed(String)
    case requestCall
    case callAnswered
    case callConnected
    case callDeclined
    case callMissed
    case micDenied
    case callFailed(String)
    case callEnded(CallEndReason)
    case voiceTranscript(role: Message.Role, text: String)
    /// What live captions have of the caller's current turn so far (checked before trusting a spoken name).
    case voiceCaption(String)
    case voiceToolCall(name: String, arguments: String, callID: String)
    case gmailConnected(GmailConnection)
    case gmailCancelled
    case skipRequested
    case reset
}

public enum OnboardingEffect: Equatable, Sendable {
    case runTextBrain(note: String?)
    case ring(after: Double)
    case connectVoice
    case disconnectVoice
    case hangUpAfterSpeaking(CallEndReason)
    case voiceToolResult(callID: String, output: String)
    case voiceSystemNote(String)
    case refreshVoiceInstructions
    case showGmailConnect
    case graduate
    case haptic(Haptic)

    public enum Haptic: String, Equatable, Sendable { case light, success, warning }
}

/// A small reducer: events in, state changes + effects out. No I/O, fully deterministic, so the
/// exact behavior under hang-ups, refusals, corrections and skips is unit-tested.
public final class OnboardingEngine {
    public private(set) var state: OnboardingState
    private let now: () -> Date

    public init(state: OnboardingState = OnboardingState(), now: @escaping () -> Date = Date.init) {
        self.state = state
        self.now = now
    }

    /// Language for the two fixed opening lines (the LLM mirrors the user's language after that).
    public var language = "en"

    public static let openingLines = openingLines(for: "en")

    public static func openingLines(for language: String) -> [String] {
        switch language {
        case "fr": return ["Salut ! Je suis ton nouvel assistant personnel.", "Première chose : comment veux-tu m'appeler ?"]
        case "es": return ["¡Hola! Soy tu nuevo asistente personal.", "Lo primero: ¿cómo te gustaría llamarme?"]
        case "ar": return ["أهلاً! أنا مساعدك الشخصي الجديد.", "أول شيء: بماذا تحب أن تسمّيني؟"]
        case "de": return ["Hey! Ich bin dein neuer persönlicher Assistent.", "Das Wichtigste zuerst: Wie möchtest du mich nennen?"]
        case "pt": return ["Oi! Eu sou seu novo assistente pessoal.", "Primeiro: como você gostaria de me chamar?"]
        default: return ["Hey there, I'm your new personal assistant.", "First things first: what would you like to call me?"]
        }
    }

    @discardableResult
    public func handle(_ event: OnboardingEvent) -> [OnboardingEffect] {
        switch event {
        case .start:
            guard state.transcript.isEmpty else { return [] }
            for line in Self.openingLines(for: language) { say(line, .text) }
            log("onboarding started")
            return []

        case .userMessage(let raw):
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return [] }
            state.transcript.append(Message(role: .user, text: text, channel: .text, date: now()))
            noteLanguage(text)
            return [.runTextBrain(note: nil)]

        case .textBrainReplied(let turn):
            return applyTextTurn(turn)

        case .textBrainFailed(let reason):
            log("text brain failed: \(reason)")
            say(fallbackLine(), .text)
            return []

        case .requestCall:
            guard Policy.canUserCall(state) else {
                if state.profile.agentName == nil {
                    say("Happy to call! First, what should I call myself, so you know who's ringing?", .text)
                }
                return []
            }
            state.call.userPrefersText = false
            return ring(after: 0.4, reason: "user asked for a call")

        case .callAnswered:
            guard state.call.status == .ringing else { return [] }
            state.call.status = .connecting
            log("call answered")
            return [.connectVoice]

        case .callConnected:
            guard state.call.status == .connecting || state.call.status == .ringing else { return [] }
            state.call.status = .active
            state.call.connectedAt = now()
            state.call.lastAliveAt = now()
            state.call.unheardName = nil
            state.call.unheardNameAt = nil
            state.call.unheardNameRejections = nil
            state.call.liveCaption = nil
            log("call connected")
            return [.haptic(.light)]

        case .callDeclined: return endCall(.declined)
        case .callMissed: return endCall(.missed)
        case .micDenied: return endCall(.micDenied)
        case .callFailed(let why):
            log("call failed: \(why)")
            return endCall(.failed)
        case .callEnded(let reason): return endCall(reason)

        case .voiceTranscript(let role, let text):
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return [] }
            state.transcript.append(Message(role: role, text: t, channel: .voice, date: now()))
            state.call.lastAliveAt = now()
            if role == .user {
                let before = state.spokenLanguage
                noteLanguage(t)
                if state.spokenLanguage != before, state.call.status == .active { return [.refreshVoiceInstructions] }
            }
            return []

        case .voiceCaption(let text):
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            state.call.liveCaption = t.isEmpty ? nil : t
            return []

        case .voiceToolCall(let name, let arguments, let callID):
            state.call.lastAliveAt = now()
            return handleVoiceTool(name: name, arguments: arguments, callID: callID)

        case .gmailConnected(let connection):
            state.profile.gmail = connection
            state.profile.declined.remove(.gmail)
            state.gmailCardVisible = false
            log("gmail connected: \(connection.email)")
            state.transcript.append(Message(role: .event, text: "Gmail connected · \(connection.email)", channel: currentChannel, date: now()))
            var effects: [OnboardingEffect] = [.haptic(.success)]
            var proof = ""
            if let count = connection.labelCount {
                let sample = (connection.sampleLabels ?? []).prefix(3).joined(separator: ", ")
                proof = " It's a real Google connection: their mailbox has \(count) labels" + (sample.isEmpty ? "" : " (their own include \(sample))") + ". You may mention one naturally so they can tell it's really connected."
            }
            if state.call.status == .active || state.call.status == .connecting {
                effects.append(.refreshVoiceInstructions)
                effects.append(.voiceSystemNote("The user just connected their Gmail (\(connection.email)).\(proof) Acknowledge it in a few words, in the user's language, and continue. \(Policy.voiceNextStep(state))\(languageReminder)"))
            } else if state.phase != .graduated {
                effects.append(.runTextBrain(note: "The user just connected their Gmail (\(connection.email)).\(proof) Acknowledge it briefly and continue."))
            }
            return effects

        case .gmailCancelled:
            log("gmail connect cancelled")
            if state.call.status == .active {
                return [.voiceSystemNote("The user closed the Gmail screen without connecting. Don't push. In the user's language, lightly ask if they'd like to try again or skip it for now (if they skip, call mark_declined).\(languageReminder)")]
            }
            if state.phase == .graduated { return [] }
            return [.runTextBrain(note: "The user closed the Gmail screen without connecting. Don't push; lightly ask if they'd like to try again or leave it for later.")]

        case .skipRequested:
            state.skipRequests += 1
            var effects: [OnboardingEffect] = []
            if state.call.status == .active || state.call.status == .connecting || state.call.status == .ringing {
                state.call.status = .ended
                state.call.lastEnd = .graduated
                effects.append(.disconnectVoice)
            }
            return effects + graduate(reason: "user tapped skip")

        case .reset:
            let wasOnCall = state.call.status != .idle && state.call.status != .ended
            state = OnboardingState()
            state.startedAt = now()
            for line in Self.openingLines(for: language) { say(line, .text) }
            log("reset")
            return wasOnCall ? [.disconnectVoice] : []
        }
    }

    // MARK: - Text turns

    private func applyTextTurn(_ turn: TextTurn) -> [OnboardingEffect] {
        var effects: [OnboardingEffect] = []
        let hadAgentName = state.profile.agentName != nil

        if state.phase == .graduated {
            say(Self.safeReply(turn.reply), .text)
            if turn.action == .showGmailConnect, state.profile.gmail == nil {
                state.gmailCardVisible = true
                effects.append(.showGmailConnect)
            }
            return effects
        }

        var reply = Self.safeReply(turn.reply)
        // The model wanted to take a name that validation refuses (markup, code, a URL…), or its reply carries
        // markup while it's still unnamed: never pretend it worked, never echo the payload back.
        let proposed = turn.agentName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let refusedName = !proposed.isEmpty && Validation.cleanName(proposed) == nil
        let replyHadMarkup = turn.reply.range(of: "<[A-Za-z/][^<>]{0,200}>", options: .regularExpression) != nil
        if state.profile.agentName == nil, Validation.cleanName(proposed) == nil, refusedName || replyHadMarkup {
            reply = "Ha, nice try, but that one won't work as a name. Something short and friendly? Nova, Juno or Atlas are all free."
            log("refused agent name: \((proposed.isEmpty ? turn.reply : proposed).prefix(40))")
        }
        applyFields(agentName: turn.agentName, userName: turn.userName, helpNeed: turn.helpNeed, category: turn.helpCategory)
        if let r = Self.cleanRequest(turn.rememberRequest) {
            state.laterRequests = (state.laterRequests ?? []) + [r]
            log("remembered for later: \(r)")
        }

        if turn.intent == .wantsSkip && state.profile.agentName == nil {
            // Skipping the naming: take a default name and stay in text (no surprise call for an impatient user).
            state.profile.agentName = Policy.defaultAgentName
            state.profile.agentNameIsDefault = true
            state.call.userPrefersText = true
        }

        switch turn.intent {
        case .refuseName: state.profile.declined.insert(.userName)
        case .refuseGmail:
            state.profile.declined.insert(.gmail)
            state.gmailCardVisible = false
        case .refuseCall: state.call.userPrefersText = true
        case .wantsSkip: state.skipRequests += 1
        default: break
        }

        var defaultedName = false
        if state.profile.agentName == nil && state.phase == .naming {
            state.namingDeflections += 1
            if state.namingDeflections >= 3 {
                // Never trap anyone on step one.
                state.profile.agentName = Policy.defaultAgentName
                state.profile.agentNameIsDefault = true
                defaultedName = true
                log("agent name defaulted to \(Policy.defaultAgentName)")
            }
        }

        say(reply, .text)
        if defaultedName {
            say("I'll go by \(Policy.defaultAgentName) for now. You can rename me anytime.", .text)
        }

        // Policy-gated actions. The model can only end onboarding early when the user asked to skip.
        let modelSaysDone = turn.action == .graduate && (Policy.isComplete(state.profile) || state.skipRequests >= 1)
        let wantsSkip = turn.intent == .wantsSkip || modelSaysDone
        if wantsSkip && Policy.canGraduate(state) {
            return effects + graduate(reason: "user wanted to skip ahead")
        }
        if wantsSkip && state.skipRequests >= 2 {
            return effects + graduate(reason: "user insisted on skipping")
        }
        if Policy.isComplete(state.profile) {
            return effects + graduate(reason: "everything collected")
        }

        let justNamed = !hadAgentName && state.profile.agentName != nil
        if (justNamed || turn.action == .startCall) && Policy.canAutoCall(state) {
            effects += ring(after: 1.6, reason: justNamed ? "agent was just named" : "brain offered a call")
        } else if turn.intent == .wantsCall && Policy.canUserCall(state) {
            state.call.userPrefersText = false
            effects += ring(after: 1.2, reason: "user asked for a call")
        } else if turn.action == .showGmailConnect || turn.intent == .agreeGmail,
                  state.profile.gmail == nil, !state.profile.declined.contains(.gmail) {
            state.gmailCardVisible = true
            state.gmailPromptCount += 1
            effects.append(.showGmailConnect)
        }
        return effects
    }

    // MARK: - Voice tools

    /// Voice only: the model can "hear" a name in background noise ("Nice to meet you, Alex!" with nobody
    /// talking). Accept a name the user said or typed at some point. So a real name can never get stuck
    /// when speech-to-text keeps mangling it, the same name proposed again after the user has spoken since
    /// is accepted, and after two misses anything is.
    private func voiceNameWasHeard(_ n: String) -> Bool {
        let said = state.transcript.filter { $0.role == .user }.map(\.text) + [state.profile.userName, state.call.liveCaption].compactMap { $0 }
        if Validation.nameWasHeard(n, in: said) { return true }
        if (state.call.unheardNameRejections ?? 0) >= 2 { return true }
        if let pending = state.call.unheardName, let asked = state.call.unheardNameAt,
           Validation.nameWasHeard(n, in: [pending]),
           state.transcript.contains(where: { $0.role == .user && $0.channel == .voice && $0.date > asked }) {
            return true
        }
        return false
    }

    private func handleVoiceTool(name: String, arguments: String, callID: String) -> [OnboardingEffect] {
        let args = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any] ?? [:]
        var result: [String: Any] = ["ok": true]
        var effects: [OnboardingEffect] = []
        log("tool \(name) \(arguments)")

        switch name {
        case "save_user_name":
            if let n = Validation.cleanName(args["name"] as? String), !voiceNameWasHeard(n) {
                // Nobody said it: the model "heard" a name in noise. Don't save it; ask once more.
                state.call.unheardName = n
                state.call.unheardNameAt = now()
                state.call.unheardNameRejections = (state.call.unheardNameRejections ?? 0) + 1
                log("name not heard in anything the user said: \(n)")
                result = ["ok": false, "error": "not_heard",
                          "note": "Nobody actually said that name: it didn't come through on the line. Don't use it or say it. Ask simply, once: \"Sorry, what should I call you?\""]
                effects.append(.voiceSystemNote("App note: the caller never said the name \(n); it came from noise on the line and wasn't saved. Don't use it. If you already said it, correct yourself in a few words (\"Sorry, I misheard\") and ask what to call them."))
            } else if let n = Validation.cleanName(args["name"] as? String) {
                state.profile.userName = n
                state.profile.declined.remove(.userName)
                result["saved"] = ["user_name": n]
                // The voice model heard the name right; fix the caption if speech-to-text mangled it.
                if let i = state.transcript.lastIndex(where: { $0.role == .user && $0.channel == .voice }),
                   let fixed = Validation.replacingSimilarName(in: state.transcript[i].text, with: n) {
                    state.transcript[i].text = fixed
                }
            } else {
                result = ["ok": false, "error": "That didn't sound like a name. Ask again lightly, or move on."]
            }
        case "rename_agent":
            if let n = Validation.cleanName(args["name"] as? String) {
                state.profile.agentName = n
                state.profile.agentNameIsDefault = false
                result["saved"] = ["agent_name": n]
                result["note"] = "From now on you are \(n)."
            } else {
                result = ["ok": false, "error": "That name didn't come through clearly. Ask them to repeat it."]
            }
        case "save_help_need":
            if let h = Validation.cleanHelpNeed(args["summary"] as? String) {
                state.profile.helpNeed = h
                state.profile.helpCategory = (args["category"] as? String).flatMap(HelpCategory.init(rawValue:)) ?? state.profile.helpCategory ?? .other
                state.profile.declined.remove(.helpNeed)
                result["saved"] = ["help_need": h]
            } else {
                result = ["ok": false, "error": "Too vague to act on. Ask for one concrete example."]
            }
        case "show_gmail_connect":
            if state.profile.gmail != nil {
                result["note"] = "Gmail is already connected (\(state.profile.gmail!.email))."
            } else {
                state.gmailCardVisible = true
                state.gmailPromptCount += 1
                state.profile.declined.remove(.gmail)
                effects.append(.showGmailConnect)
                result["note"] = "A Connect Gmail button is now on the user's screen. Tell them to tap it. Don't ask for passwords or codes. The app tells you privately when it's connected; never mention that."
            }
        case "mark_declined":
            if let what = (args["what"] as? String).flatMap(Field.init(rawValue:)), what != .agentName {
                state.profile.declined.insert(what)
                if what == .gmail { state.gmailCardVisible = false }
                result["note"] = "Respect it. Don't ask for \(what.rawValue) again on this call."
            }
        case "remember_request":
            if let r = Self.cleanRequest(args["request"] as? String) {
                state.laterRequests = (state.laterRequests ?? []) + [r]
                log("remembered for later: \(r)")
                result["note"] = "Noted: it'll be waiting in the chat right after the call. Say so in a few words, then carry on."
            } else {
                result = ["ok": false, "error": "Say what they asked for in a few words."]
            }
        case "finish_call":
            let reason: CallEndReason
            switch args["reason"] as? String {
            case "graduate": reason = Policy.canGraduate(state) ? .graduated : .switchedToText
            case "switch_to_text", "user_request": reason = .switchedToText
            default: reason = Policy.isComplete(state.profile) ? .completed : .switchedToText
            }
            result["note"] = "Say a very short goodbye if you haven't already. The call will end after you finish speaking."
            effects.append(.voiceToolResult(callID: callID, output: Self.json(result)))
            effects.append(.hangUpAfterSpeaking(reason))
            return effects
        default:
            result = ["ok": false, "error": "Unknown tool \(name)."]
        }

        result["still_needed"] = Policy.stillNeeded(state.profile).map(\.rawValue)
        result["next"] = Policy.voiceNextStep(state)
        if let lang = state.spokenLanguage { result["language"] = "Keep speaking \(lang)." }
        return [.voiceToolResult(callID: callID, output: Self.json(result)), .refreshVoiceInstructions] + effects
    }

    // MARK: - Calls

    private func ring(after delay: Double, reason: String) -> [OnboardingEffect] {
        state.call.status = .ringing
        state.call.attempts += 1
        state.phase = .onCall
        log("ringing (\(reason)), attempt \(state.call.attempts)")
        return [.ring(after: delay)]
    }

    private func endCall(_ reason: CallEndReason) -> [OnboardingEffect] {
        // Idempotent: a hang-up and the socket closing can both report the end of the same call.
        guard state.call.status != .idle && state.call.status != .ended else { return [] }
        let wasLive = state.call.status == .active || state.call.status == .connecting
        if let start = state.call.connectedAt {
            var end = now()
            // Nothing for over a minute means the app was killed or suspended mid-call: end at the last sign of life.
            if let alive = state.call.lastAliveAt, end.timeIntervalSince(alive) > 60 { end = alive.addingTimeInterval(2) }
            state.call.lastDuration = max(0, end.timeIntervalSince(start))
        }
        state.call.status = .ended
        state.call.lastEnd = reason
        state.call.connectedAt = nil
        log("call ended: \(reason.rawValue)")
        if reason == .declined { state.call.userPrefersText = true }

        var effects: [OnboardingEffect] = wasLive ? [.disconnectVoice] : []
        state.transcript.append(Message(role: .event, text: Self.eventLine(reason, duration: state.call.lastDuration), channel: .voice, date: now()))

        if reason == .graduated || reason == .completed, Policy.canGraduate(state) {
            return effects + graduate(reason: "call finished")
        }
        state.phase = state.phase == .graduated ? .graduated : .textFollowUp
        effects.append(.haptic(reason == .completed ? .light : .warning))
        effects.append(.runTextBrain(note: Self.callEndNote(reason, duration: state.call.lastDuration)))
        return effects
    }

    private func graduate(reason: String) -> [OnboardingEffect] {
        guard state.phase != .graduated else { return [] }
        if state.profile.agentName == nil {
            state.profile.agentName = Policy.defaultAgentName
            state.profile.agentNameIsDefault = true
        }
        state.graduatedEarly = !Policy.isComplete(state.profile)
        state.phase = .graduated
        state.graduatedAt = now()
        state.gmailCardVisible = false
        log("graduated (\(reason))\(state.graduatedEarly ? " early" : "")")
        var effects: [OnboardingEffect] = [.haptic(.success), .graduate]
        // Keep the promises made along the way ("I'll send you that code in the chat").
        if let asks = state.laterRequests, !asks.isEmpty {
            state.laterRequests = nil
            let list = asks.map { "\"\($0)\"" }.joined(separator: "; ")
            effects.append(.runTextBrain(note: "While getting set up, the user asked you for: \(list). You promised to do it here once they were in. Do it now, completely (a full draft or plan is fine), starting with a short line like \"As promised, here's…\"."))
        }
        return effects
    }

    /// Never show markup from the model (e.g. a `<script>` tag a user tried to inject), just its words.
    static func safeReply(_ text: String) -> String {
        let stripped = text.replacingOccurrences(of: "<[^<>]{1,200}>", with: "", options: .regularExpression)
        let tidy = stripped.replacingOccurrences(of: "[ \t]{2,}", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return tidy.isEmpty ? "Sorry, could you say that another way?" : tidy
    }

    static func cleanRequest(_ raw: String?) -> String? {
        guard let t = raw?.trimmingCharacters(in: .whitespacesAndNewlines), t.count >= 3 else { return nil }
        return String(t.prefix(300))
    }

    // MARK: - Helpers

    private var currentChannel: Channel { state.call.status == .active ? .voice : .text }

    private func applyFields(agentName: String?, userName: String?, helpNeed: String?, category: HelpCategory?) {
        if let n = Validation.cleanName(agentName) {
            state.profile.agentName = n
            state.profile.agentNameIsDefault = false
        }
        if let n = Validation.cleanName(userName) {
            state.profile.userName = n
            state.profile.declined.remove(.userName)
        }
        if let h = Validation.cleanHelpNeed(helpNeed) {
            state.profile.helpNeed = h
            state.profile.helpCategory = category ?? state.profile.helpCategory ?? .other
            state.profile.declined.remove(.helpNeed)
        } else if let category, state.profile.helpNeed != nil {
            state.profile.helpCategory = category
        }
    }

    private func say(_ text: String, _ channel: Channel) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        state.transcript.append(Message(role: .assistant, text: t, channel: channel, date: now()))
    }

    private func noteLanguage(_ text: String) {
        guard let g = LanguageGuess.guess(text) else { return }
        state.spokenLanguage = g == "English" ? nil : g
    }

    private var languageReminder: String {
        state.spokenLanguage.map { " Reply in \($0)." } ?? ""
    }

    private func log(_ line: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        state.log.append("\(f.string(from: now()))  \(line)")
        if state.log.count > 200 { state.log.removeFirst(state.log.count - 200) }
    }

    private func fallbackLine() -> String {
        switch Policy.nextFocus(state) {
        case .agentName?: return "Sorry, my connection hiccuped. What would you like to call me?"
        case .userName?: return "Sorry, I lost my train of thought for a second. What should I call you?"
        case .helpNeed?: return "Sorry, small hiccup on my end. What's the first thing you'd love help with?"
        case .gmail?: return "Sorry, small hiccup. Whenever you're ready, you can connect Gmail with the button."
        case nil: return "Sorry, small hiccup on my end. I'm here whenever you're ready."
        }
    }

    public static func eventLine(_ reason: CallEndReason, duration: TimeInterval) -> String {
        let d = duration > 0 ? " · \(Int(duration / 60)):\(String(format: "%02d", Int(duration) % 60))" : ""
        switch reason {
        case .declined: return "Call declined"
        case .missed: return "Missed call"
        case .micDenied: return "Call unavailable · microphone off"
        case .failed: return "Call couldn't connect"
        case .dropped: return "Call dropped\(d)"
        case .userHungUp: return "You hung up\(d)"
        case .silence: return "Call ended · line went quiet\(d)"
        case .switchedToText: return "Switched to text\(d)"
        case .completed, .graduated: return "Call ended\(d)"
        }
    }

    public static func callEndNote(_ reason: CallEndReason, duration: TimeInterval) -> String {
        let secs = Int(duration)
        // A call can end right after the user says something, before the voice agent saved it.
        let recover = " If they already said their name or what they need on the call (lines marked \"(on the call)\"), treat it as given: fill it in now and don't ask for it again."
        switch reason {
        case .declined:
            return "The user declined your call. Totally fine: continue here by text with what's still missing. No guilt-tripping, and don't offer to call again unless they ask."
        case .missed:
            return "The user didn't pick up your call. Continue by text in a light, friendly way; you can mention they can tap the phone button anytime if they'd rather talk."
        case .micDenied:
            return "The call couldn't start because microphone access is off. Continue by text, and mention once, briefly, that they can turn the mic on in Settings if they want to talk later."
        case .failed:
            return "The call couldn't connect because of a network problem. Apologize briefly, continue by text, and offer to try the call again."
        case .dropped:
            return "The call dropped after \(secs)s. Acknowledge it like a human would (\"looks like we got cut off\"), continue by text with what's still missing, and offer to call back." + recover
        case .userHungUp:
            return "The user hung up after \(secs)s. Don't make it awkward (maybe they're busy). If they said they had to go, keep it light: acknowledge it and leave one easy question they can answer whenever they're back. Don't call again unless they ask." + recover
        case .silence:
            return "The call ended because the line went quiet (you told them you'd text instead). Continue by text, lightly; they may have stepped away." + recover
        case .switchedToText:
            return "The user wanted to continue by text. Pick up exactly where the call left off." + recover
        case .completed, .graduated:
            return "The call ended. Continue by text with anything that's still missing." + recover
        }
    }

    static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "{\"ok\":false}" }
        return s
    }
}
