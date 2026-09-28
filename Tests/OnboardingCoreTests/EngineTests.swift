import XCTest
@testable import OnboardingCore

final class EngineTests: XCTestCase {
    private func engine() -> OnboardingEngine {
        let e = OnboardingEngine()
        e.handle(.start)
        return e
    }

    func testNamingTriggersExactlyOneAutoCall() {
        let e = engine()
        let fx = e.handle(.textBrainReplied(TextTurn(reply: "Nova it is!", agentName: "nova", action: .startCall)))
        XCTAssertEqual(e.state.profile.agentName, "Nova")
        XCTAssertTrue(fx.contains(.ring(after: 1.6)))
        XCTAssertEqual(e.state.call.status, .ringing)
        XCTAssertEqual(e.state.phase, .onCall)
        // Declined → text follow-up, and no automatic second call.
        let fx2 = e.handle(.callDeclined)
        XCTAssertEqual(e.state.phase, .textFollowUp)
        XCTAssertTrue(fx2.contains { if case .runTextBrain = $0 { return true } else { return false } })
        let fx3 = e.handle(.textBrainReplied(TextTurn(reply: "What should I call you?", action: .startCall)))
        XCTAssertFalse(fx3.contains(.ring(after: 1.6)), "must not auto-call again after a decline")
    }

    func testUserCanAlwaysAskForACallAfterNaming() {
        let e = engine()
        e.handle(.textBrainReplied(TextTurn(reply: "Love it", agentName: "Kai")))
        e.handle(.callMissed)
        let fx = e.handle(.requestCall)
        XCTAssertEqual(fx, [.ring(after: 0.4)])
        XCTAssertEqual(e.state.call.attempts, 2)
    }

    func testHangUpMidCallKeepsWhatWasCollectedAndIsIdempotent() {
        let e = engine()
        e.handle(.textBrainReplied(TextTurn(reply: "Great name", agentName: "Juno")))
        e.handle(.callAnswered)
        e.handle(.callConnected)
        e.handle(.voiceTranscript(role: .user, text: "I'm Sara"))
        e.handle(.voiceToolCall(name: "save_user_name", arguments: #"{"name":"sara"}"#, callID: "c1"))
        let fx = e.handle(.callEnded(.userHungUp))
        XCTAssertTrue(fx.contains(.disconnectVoice))
        XCTAssertEqual(e.state.profile.userName, "Sara")
        XCTAssertEqual(e.state.phase, .textFollowUp)
        // Socket close arriving after the hang-up must not double-handle.
        XCTAssertEqual(e.handle(.callEnded(.dropped)), [])
        XCTAssertEqual(e.state.call.lastEnd, .userHungUp)
    }

    func testEverythingAtOnceGraduatesAfterGmail() {
        let e = engine()
        e.handle(.textBrainReplied(TextTurn(reply: "Hi Sam!", agentName: "Max", userName: "Sam", helpNeed: "inbox triage", helpCategory: .email)))
        XCTAssertEqual(Policy.stillNeeded(e.state.profile), [.gmail])
        e.handle(.callDeclined)
        let fx = e.handle(.textBrainReplied(TextTurn(reply: "Tap the button to connect Gmail.", action: .showGmailConnect)))
        XCTAssertTrue(fx.contains(.showGmailConnect))
        XCTAssertTrue(e.state.gmailCardVisible)
        e.handle(.gmailConnected(GmailConnection(email: "sam@gmail.com", isSimulated: true)))
        XCTAssertTrue(Policy.isComplete(e.state.profile))
        let fx2 = e.handle(.textBrainReplied(TextTurn(reply: "You're all set!", action: .graduate)))
        XCTAssertTrue(fx2.contains(.graduate))
        XCTAssertEqual(e.state.phase, .graduated)
        XCTAssertFalse(e.state.graduatedEarly)
    }

    func testPromisesMadeDuringOnboardingAreKeptAfterGraduation() {
        let e = engine()
        e.handle(.textBrainReplied(TextTurn(reply: "Nova it is!", agentName: "Nova", action: .startCall)))
        e.handle(.callAnswered)
        e.handle(.callConnected)
        // On the call: "can you draft an email to my landlord about the heater?" → promised for the chat.
        e.handle(.voiceToolCall(name: "remember_request", arguments: #"{"request":"an email to the landlord about the broken heater"}"#, callID: "r1"))
        XCTAssertEqual(e.state.laterRequests, ["an email to the landlord about the broken heater"])
        e.handle(.voiceTranscript(role: .user, text: "I'm Sam, and I need help with my inbox."))
        e.handle(.voiceToolCall(name: "save_user_name", arguments: #"{"name":"Sam"}"#, callID: "c1"))
        e.handle(.voiceToolCall(name: "save_help_need", arguments: #"{"summary":"inbox","category":"email"}"#, callID: "c2"))
        e.handle(.gmailConnected(GmailConnection(email: "sam@gmail.com", isSimulated: true)))
        e.handle(.voiceToolCall(name: "finish_call", arguments: #"{"reason":"complete"}"#, callID: "c3"))
        let fx = e.handle(.callEnded(.completed))
        XCTAssertEqual(e.state.phase, .graduated)
        let delivery = fx.compactMap { effect -> String? in if case .runTextBrain(let note) = effect { return note } else { return nil } }
        XCTAssertEqual(delivery.count, 1, "the promised item is delivered right after graduation")
        XCTAssertTrue(delivery.first?.contains("landlord") ?? false)
        XCTAssertNil(e.state.laterRequests, "delivered once")
        // Same from the text channel.
        let t = engine()
        t.handle(.textBrainReplied(TextTurn(reply: "Happy to, right after we're set up!", agentName: "Kai", rememberRequest: "a plan for next week")))
        XCTAssertEqual(t.state.laterRequests, ["a plan for next week"])
    }

    func testCallBackGreetingOnlyOnALaterCall() {
        let e = engine()
        e.handle(.textBrainReplied(TextTurn(reply: "Nova it is!", agentName: "Nova", action: .startCall)))
        e.handle(.callAnswered)
        e.handle(.callConnected)
        e.handle(.voiceTranscript(role: .assistant, text: "Hey, it's Nova! What should I call you?"))
        // Instructions refreshed mid-call must not turn the first call into a "call back".
        XCTAssertFalse(BrainPrompts.voiceInstructions(e.state).contains("again!"))
        e.handle(.callEnded(.silence))
        e.handle(.requestCall)
        e.handle(.callAnswered)
        XCTAssertTrue(BrainPrompts.voiceInstructions(e.state).contains("again!"), "second call opens as a call back")
    }

    func testInjectedMarkupNameIsRefusedAndNeverEchoed() {
        let e = engine()
        let fx = e.handle(.textBrainReplied(TextTurn(reply: "I'll go by “<script>alert(1)</script>.” I'll ring you!", agentName: "<script>alert(1)</script>", action: .startCall)))
        XCTAssertNil(e.state.profile.agentName)
        XCTAssertFalse(fx.contains(.ring(after: 1.6)), "no call before there's a real name")
        let last = e.state.transcript.last(where: { $0.role == .assistant })?.text ?? ""
        XCTAssertFalse(last.contains("<script"), "markup is never shown")
        XCTAssertTrue(last.contains("won't work as a name"))
        XCTAssertEqual(OnboardingEngine.safeReply("Sure <b>thing</b> <3"), "Sure thing <3")
        // The model echoes the payload without proposing it as a name: still refused, still not shown.
        let e2 = engine()
        e2.handle(.textBrainReplied(TextTurn(reply: "A bold choice. I'll go by <script>alert(1)</script>!", action: .startCall)))
        let last2 = e2.state.transcript.last(where: { $0.role == .assistant })?.text ?? ""
        XCTAssertFalse(last2.contains("script") || last2.contains("alert("))
    }

    func testEarlyGraduationNeedsHelpNeedButNeverTraps() {
        let e = engine()
        e.handle(.textBrainReplied(TextTurn(reply: "Nice", agentName: "Ivy")))
        e.handle(.callDeclined)
        // Wants to skip but we don't know what they need yet → one more question, no graduation.
        let fx = e.handle(.textBrainReplied(TextTurn(reply: "Sure! What's the first thing you want help with?", intent: .wantsSkip)))
        XCTAssertFalse(fx.contains(.graduate))
        // Insists again → let them in anyway.
        let fx2 = e.handle(.textBrainReplied(TextTurn(reply: "No problem, let's go.", intent: .wantsSkip)))
        XCTAssertTrue(fx2.contains(.graduate))
        XCTAssertTrue(e.state.graduatedEarly)
    }

    func testRefusedGmailIsRespected() {
        let e = engine()
        e.handle(.textBrainReplied(TextTurn(reply: "ok", agentName: "Ivy", userName: "Lee", helpNeed: "plan my week", helpCategory: .calendar)))
        e.handle(.callDeclined)
        let fx = e.handle(.textBrainReplied(TextTurn(reply: "Totally fine, you can connect later.", intent: .refuseGmail)))
        XCTAssertTrue(e.state.profile.declined.contains(.gmail))
        XCTAssertTrue(fx.contains(.graduate), "nothing left to ask once Gmail is declined")
    }

    func testCorrectionsOverwrite() {
        let e = engine()
        e.handle(.textBrainReplied(TextTurn(reply: "ok", agentName: "Atlas")))
        e.handle(.callAnswered); e.handle(.callConnected)
        e.handle(.voiceToolCall(name: "rename_agent", arguments: #"{"name":"Kai"}"#, callID: "1"))
        e.handle(.voiceTranscript(role: .user, text: "My name is Samantha."))
        e.handle(.voiceToolCall(name: "save_user_name", arguments: #"{"name":"Samantha"}"#, callID: "2"))
        e.handle(.voiceTranscript(role: .user, text: "Actually, just call me Sam."))
        e.handle(.voiceToolCall(name: "save_user_name", arguments: #"{"name":"Sam"}"#, callID: "3"))
        XCTAssertEqual(e.state.profile.agentName, "Kai")
        XCTAssertEqual(e.state.profile.userName, "Sam")
    }

    func testJunkNamesAreRejected() {
        XCTAssertNil(Validation.cleanName("none of your business"))
        XCTAssertNil(Validation.cleanName("idk"))
        XCTAssertNil(Validation.cleanName("12345"))
        XCTAssertNil(Validation.cleanName("this is a very long sentence that is not a name at all"))
        XCTAssertEqual(Validation.cleanName("call me sam"), "Sam")
        XCTAssertEqual(Validation.cleanName("\"Nova\"."), "Nova")
        XCTAssertEqual(Validation.cleanName("يوسف"), "يوسف")
    }

    func testVoiceToolResultsCarryNextStep() {
        let e = engine()
        e.handle(.textBrainReplied(TextTurn(reply: "ok", agentName: "Nova")))
        e.handle(.callAnswered); e.handle(.callConnected)
        let fx = e.handle(.voiceToolCall(name: "save_help_need", arguments: #"{"summary":"inbox zero","category":"email"}"#, callID: "x"))
        guard case .voiceToolResult(_, let out)? = fx.first else { return XCTFail("no tool result") }
        XCTAssertTrue(out.contains("still_needed"))
        XCTAssertTrue(out.contains("user_name"))
        XCTAssertEqual(e.state.profile.helpCategory, .email)
    }

    func testFinishCallGraduatesOnlyWhenAllowed() {
        let e = engine()
        e.handle(.textBrainReplied(TextTurn(reply: "ok", agentName: "Nova")))
        e.handle(.callAnswered); e.handle(.callConnected)
        let fx = e.handle(.voiceToolCall(name: "finish_call", arguments: #"{"reason":"graduate"}"#, callID: "f"))
        XCTAssertTrue(fx.contains(.hangUpAfterSpeaking(.switchedToText)), "no help need yet → can't graduate, continue by text")
    }

    func testSkipButtonAlwaysWorksEvenMidCall() {
        let e = engine()
        e.handle(.textBrainReplied(TextTurn(reply: "ok", agentName: "Nova")))
        e.handle(.callAnswered); e.handle(.callConnected)
        let fx = e.handle(.skipRequested)
        XCTAssertTrue(fx.contains(.disconnectVoice))
        XCTAssertTrue(fx.contains(.graduate))
    }

    func testDefaultNameAfterRepeatedDeflection() {
        let e = engine()
        for _ in 0..<3 { e.handle(.textBrainReplied(TextTurn(reply: "What should I call myself?"))) }
        XCTAssertEqual(e.state.profile.agentName, Policy.defaultAgentName)
        XCTAssertTrue(e.state.profile.agentNameIsDefault)
    }

    func testSchemaIsSerializable() throws {
        _ = try JSONSerialization.data(withJSONObject: BrainPrompts.textSchema)
        _ = try JSONSerialization.data(withJSONObject: BrainPrompts.voiceTools)
    }

    func testMarkupIsNeverANameAndDoesNotTriggerACall() {
        XCTAssertNil(Validation.cleanName("<script>alert(1)</script>"))
        XCTAssertNil(Validation.cleanName("sam@gmail.com"))
        XCTAssertNil(Validation.cleanName("{{name}}"))
        XCTAssertEqual(Validation.cleanName("Jean-Luc"), "Jean-Luc")
        XCTAssertEqual(Validation.cleanName("O'Brien"), "O'Brien")
        let e = engine()
        let fx = e.handle(.textBrainReplied(TextTurn(reply: "Nice try!", agentName: "<script>alert(1)</script>")))
        XCTAssertNil(e.state.profile.agentName)
        XCTAssertFalse(fx.contains(.ring(after: 1.6)))
    }

    func testModelCannotGraduateEarlyOnItsOwn() {
        let e = engine()
        e.handle(.textBrainReplied(TextTurn(reply: "ok", agentName: "Orion", userName: "Nora", helpNeed: "invoices", helpCategory: .finance)))
        e.handle(.callDeclined)
        // Model wrongly says graduate while Gmail is pending and the user never asked to skip.
        let fx = e.handle(.textBrainReplied(TextTurn(reply: "Tap the button to connect.", intent: .agreeGmail, action: .graduate)))
        XCTAssertFalse(fx.contains(.graduate))
        XCTAssertTrue(fx.contains(.showGmailConnect))
    }

    func testSkippingTheNameUsesDefaultAndNoSurpriseCall() {
        let e = engine()
        let fx = e.handle(.textBrainReplied(TextTurn(reply: "Sure, let's skip that. What should I help with first?", intent: .wantsSkip)))
        XCTAssertEqual(e.state.profile.agentName, Policy.defaultAgentName)
        XCTAssertFalse(fx.contains { if case .ring = $0 { return true } else { return false } })
        let fx2 = e.handle(.textBrainReplied(TextTurn(reply: "On it, see you inside!", helpNeed: "reply to emails faster", helpCategory: .email, action: .graduate)))
        XCTAssertTrue(fx2.contains(.graduate))
    }

    func testLocalizedOpeners() {
        let e = OnboardingEngine()
        e.language = "fr"
        e.handle(.start)
        XCTAssertTrue(e.state.transcript.first?.text.hasPrefix("Salut") == true)
    }
    func testCallRestoredAfterAppKillUsesLastSignOfLife() {
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let e = OnboardingEngine(now: { clock })
        e.handle(.start)
        e.handle(.textBrainReplied(TextTurn(reply: "Love it", agentName: "Kai")))
        e.handle(.callAnswered)
        e.handle(.callConnected)
        clock += 40
        e.handle(.voiceTranscript(role: .user, text: "I'm Sam"))
        // App killed; relaunched ten minutes later and the call is reported as dropped.
        clock += 600
        e.handle(.callEnded(.dropped))
        XCTAssertEqual(e.state.call.lastDuration, 42, accuracy: 0.5)
        // A normal call that ends while live keeps its real duration.
        let f = OnboardingEngine(now: { clock })
        f.handle(.start)
        f.handle(.textBrainReplied(TextTurn(reply: "Love it", agentName: "Kai")))
        f.handle(.callAnswered)
        f.handle(.callConnected)
        clock += 30
        f.handle(.callEnded(.silence))
        XCTAssertEqual(f.state.call.lastDuration, 30, accuracy: 0.5)
    }
    func testLanguageGuessAndVoiceLanguageTracking() {
        XCTAssertEqual(LanguageGuess.guess("Je m'appelle Youssef et j'aimerais de l'aide pour gérer mes rendez-vous"), "French")
        XCTAssertEqual(LanguageGuess.guess("Hola, soy Ana y necesito ayuda con mi correo"), "Spanish")
        XCTAssertEqual(LanguageGuess.guess("مرحبا انا يوسف"), "Arabic")
        XCTAssertEqual(LanguageGuess.guess("I need help with my inbox please"), "English")
        XCTAssertNil(LanguageGuess.guess("Sam"))
        XCTAssertEqual(LanguageGuess.guess("Youssef, appelle-moi Youssef."), "French")
        let e = engine()
        e.handle(.textBrainReplied(TextTurn(reply: "Love it", agentName: "Zaki")))
        e.handle(.callAnswered)
        e.handle(.callConnected)
        let fx = e.handle(.voiceTranscript(role: .user, text: "Je m'appelle Youssef, et toi ?"))
        XCTAssertEqual(e.state.spokenLanguage, "French")
        XCTAssertEqual(fx, [.refreshVoiceInstructions], "the call should switch language right away")
        XCTAssertTrue(BrainPrompts.voiceInstructions(e.state).contains("Speak only French"))
        // A one-word answer keeps the language; clear English switches back.
        e.handle(.voiceTranscript(role: .user, text: "Oui"))
        XCTAssertEqual(e.state.spokenLanguage, "French")
        e.handle(.voiceTranscript(role: .user, text: "Actually I'd rather speak English, is that okay?"))
        XCTAssertNil(e.state.spokenLanguage)
    }
    func testMisheardNameIsFixedInCaptionOnceSaved() {
        XCTAssertEqual(Validation.replacingSimilarName(in: "You should call me. Amen", with: "Ayman"), "You should call me. Ayman")
        XCTAssertEqual(Validation.replacingSimilarName(in: "I'm Eimon, hi", with: "Ayman"), "I'm Ayman, hi")
        XCTAssertNil(Validation.replacingSimilarName(in: "I need help with my calendar", with: "Ayman"))
        XCTAssertNil(Validation.replacingSimilarName(in: "Call me Ayman", with: "Ayman"), "already right")
        let e = engine()
        e.handle(.textBrainReplied(TextTurn(reply: "Love it", agentName: "Milo")))
        e.handle(.callAnswered)
        e.handle(.callConnected)
        e.handle(.voiceTranscript(role: .user, text: "You should call me. Amen"))
        e.handle(.voiceToolCall(name: "save_user_name", arguments: #"{"name":"Ayman"}"#, callID: "c1"))
        XCTAssertEqual(e.state.profile.userName, "Ayman")
        XCTAssertEqual(e.state.transcript.last(where: { $0.role == .user })?.text, "You should call me. Ayman")
        XCTAssertTrue(BrainPrompts.transcriptionPrompt(e.state).contains("Their name is Ayman"))
    }

    func testRealGmailConnectionTellsTheAgentWhatItSaw() {
        let e = engine()
        e.handle(.textBrainReplied(TextTurn(reply: "Love it", agentName: "Milo")))
        e.handle(.callAnswered)
        e.handle(.callConnected)
        let fx = e.handle(.gmailConnected(GmailConnection(email: "ayman@gmail.com", isSimulated: false, labelCount: 23, sampleLabels: ["Receipts", "Travel"])))
        let note = fx.compactMap { if case .voiceSystemNote(let t) = $0 { return t } else { return nil } }.first ?? ""
        XCTAssertTrue(note.contains("23 labels") && note.contains("Receipts"), note)
        XCTAssertEqual(e.state.profile.gmail?.isSimulated, false)
    }

    // MARK: - Noise on the line (phantom turns and phantom names)

    func testTurnGateAnswersOnlyRealWords() {
        var gate = TurnGate()
        let t0 = Date()
        XCTAssertEqual(gate.decide(heard: "Hi, I'm Karim.", interruptedAgent: false, now: t0), .respond)
        XCTAssertEqual(gate.decide(heard: "", interruptedAgent: false, now: t0), .sayUnclear, "noise gets an honest 'didn't catch that'")
        XCTAssertEqual(gate.decide(heard: "[noise]", interruptedAgent: false, now: t0.addingTimeInterval(3)), .ignore, "not twice in a row within the cooldown")
        XCTAssertEqual(gate.decide(heard: "Mm-hmm.", interruptedAgent: false, now: t0.addingTimeInterval(5)), .respond)
        XCTAssertEqual(gate.decide(heard: "", interruptedAgent: true, now: t0.addingTimeInterval(6)), .resume, "cut off by noise: carry on")
        XCTAssertEqual(gate.decide(heard: "", interruptedAgent: false, now: t0.addingTimeInterval(30)), .sayUnclear)
        XCTAssertEqual(gate.decide(heard: "", interruptedAgent: false, now: t0.addingTimeInterval(60)), .ignore, "steady noise doesn't make the agent chatter")
        XCTAssertEqual(gate.decide(heard: "ok", interruptedAgent: false, now: t0.addingTimeInterval(61)), .respond)
        // What counts as words.
        XCTAssertFalse(TurnGate.hasWords(""))
        XCTAssertFalse(TurnGate.hasWords(" ... "))
        XCTAssertFalse(TurnGate.hasWords("(coughs) [inaudible]"))
        XCTAssertFalse(TurnGate.hasWords("अबneamth wahمسل يعني meruhna ya"), "gibberish from unintelligible audio mixes scripts inside words")
        XCTAssertTrue(TurnGate.hasWords("سلام, I'm Ahmed"), "code-switching keeps each word in one script")
        XCTAssertTrue(TurnGate.hasWords("Je m'appelle Chloé"))
        XCTAssertTrue(TurnGate.hasWords("42"))
    }

    func testPendingTurnsWaitForSpeechToText() {
        var turns = PendingTurns()
        turns.started("a", agentBusy: false)
        turns.committed("a")
        XCTAssertNil(turns.takeReady(), "no transcript yet")
        turns.transcribed("a", "")
        XCTAssertEqual(turns.takeReady()?.heardWords, false)
        XCTAssertTrue(turns.isEmpty)
        // Live captions already have words at commit: answer right away.
        turns.started("b", agentBusy: true)
        turns.partialTranscript("b", " Hi, I'm")
        turns.committed("b")
        let ready = turns.takeReady()
        XCTAssertEqual(ready?.heardWords, true)
        XCTAssertEqual(ready?.cutAgentOff, true)
        // Two quick turns: one with words is enough; a failure or a timeout trusts the voice model.
        turns.started("c", agentBusy: false)
        turns.started("d", agentBusy: false)
        turns.transcribed("c", "")
        XCTAssertNil(turns.takeReady())
        turns.failed("d")
        XCTAssertEqual(turns.takeReady()?.heardWords, true)
        turns.started("e", agentBusy: false)
        turns.timedOut()
        XCTAssertEqual(turns.takeReady()?.heardWords, true)
    }

    func testNameNobodySaidIsNotSaved() {
        let e = engine()
        e.handle(.textBrainReplied(TextTurn(reply: "Nova it is!", agentName: "Nova")))
        e.handle(.callAnswered)
        e.handle(.callConnected)
        e.handle(.voiceTranscript(role: .assistant, text: "Hey, it's Nova! What should I call you?"))
        // Background noise, nothing transcribed, and the voice model "heard" a name anyway.
        let fx = e.handle(.voiceToolCall(name: "save_user_name", arguments: #"{"name":"Alex"}"#, callID: "c1"))
        XCTAssertNil(e.state.profile.userName)
        let output = fx.compactMap { if case .voiceToolResult(_, let o) = $0 { return o } else { return nil } }.first ?? ""
        XCTAssertTrue(output.contains("not_heard"), output)
        XCTAssertTrue(fx.contains { if case .voiceSystemNote(let t) = $0 { return t.contains("Alex") } else { return false } }, "the agent corrects itself")
        // Then they really answer.
        e.handle(.voiceTranscript(role: .user, text: "Oh sorry, it's Ahmed."))
        e.handle(.voiceToolCall(name: "save_user_name", arguments: #"{"name":"Ahmed"}"#, callID: "c2"))
        XCTAssertEqual(e.state.profile.userName, "Ahmed")
    }

    func testRealNameIsNeverStuckWhenSpeechToTextMangledIt() {
        let e = engine()
        e.handle(.textBrainReplied(TextTurn(reply: "Love it", agentName: "Milo")))
        e.handle(.callAnswered)
        e.handle(.callConnected)
        // The full transcript hasn't landed yet, but live captions have it.
        e.handle(.voiceCaption("Hi, I'm Karim"))
        e.handle(.voiceToolCall(name: "save_user_name", arguments: #"{"name":"Karim"}"#, callID: "c1"))
        XCTAssertEqual(e.state.profile.userName, "Karim")
        // Speech-to-text keeps mangling a name the voice model hears fine: asked once, then trusted.
        let f = engine()
        f.handle(.textBrainReplied(TextTurn(reply: "Love it", agentName: "Milo")))
        f.handle(.callAnswered)
        f.handle(.callConnected)
        f.handle(.voiceTranscript(role: .user, text: "I'm on."))
        f.handle(.voiceToolCall(name: "save_user_name", arguments: #"{"name":"Siobhan"}"#, callID: "c1"))
        XCTAssertNil(f.state.profile.userName)
        f.handle(.voiceTranscript(role: .user, text: "I said it's Shivawn."))
        f.handle(.voiceToolCall(name: "save_user_name", arguments: #"{"name":"Siobhan"}"#, callID: "c2"))
        XCTAssertEqual(f.state.profile.userName, "Siobhan")
        // How loose "heard" is.
        XCTAssertTrue(Validation.nameWasHeard("Ahmed", in: ["it's A-H-M-E-D"]))
        XCTAssertTrue(Validation.nameWasHeard("Chloé", in: ["je suis chloe"]))
        XCTAssertTrue(Validation.nameWasHeard("Aymane", in: ["I'm Ayman"]))
        XCTAssertTrue(Validation.nameWasHeard("Siobhan", in: ["call me Shivon"]))
        XCTAssertFalse(Validation.nameWasHeard("Alex", in: ["Let's call you Nova", "What can you do?"]))
    }
}
