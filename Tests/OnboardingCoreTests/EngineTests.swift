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
        e.handle(.voiceToolCall(name: "save_user_name", arguments: #"{"name":"Samantha"}"#, callID: "2"))
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
}
