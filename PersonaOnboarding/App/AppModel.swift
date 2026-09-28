import SwiftUI
import UIKit
import AVFoundation
import Observation

/// Glue between the pure onboarding engine and the real world (LLM, voice call, sounds, persistence).
/// Every user action and every async result becomes an `OnboardingEvent`; the engine answers with effects.
@Observable
@MainActor
final class AppModel {
    private(set) var state: OnboardingState
    private(set) var isThinking = false
    var ringVisible = false
    var showGmailSheet = false
    var showTester = false
    var simulateNoMic = false
    let voice = RealtimeVoice()
    @ObservationIgnored private(set) var autopilot: AutopilotCaller!

    @ObservationIgnored private let engine: OnboardingEngine
    @ObservationIgnored private var brain: TextBrain
    @ObservationIgnored private var brainTask: Task<Void, Never>?
    @ObservationIgnored private var brainQueued = false
    @ObservationIgnored private var queuedNote: String?
    @ObservationIgnored private var ringTask: Task<Void, Never>?
    @ObservationIgnored private var deferred: [OnboardingEffect] = []
    @ObservationIgnored private static let storeKey = "onboarding.state.v2"

    private(set) var apiKey: String

    func setAPIKey(_ key: String) {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(k, forKey: AppSecrets.overrideKey)
        apiKey = k.isEmpty ? AppSecrets.openAIKey : k
        brain = TextBrain(config: BrainConfig(apiKey: apiKey))
    }

    init() {
        Typo.registerFonts()
        let key = AppSecrets.openAIKey
        apiKey = key
        brain = TextBrain(config: BrainConfig(apiKey: key))

        var restored = OnboardingState()
        if let data = UserDefaults.standard.data(forKey: Self.storeKey),
           let saved = try? JSONDecoder().decode(OnboardingState.self, from: data) {
            restored = saved
        }
        engine = OnboardingEngine(state: restored)
        engine.language = Locale.current.language.languageCode?.identifier ?? "en"
        state = restored

        // The app was killed mid-call: that's a dropped call, and the chat should pick it up.
        switch restored.call.status {
        case .ringing: deferred = engine.handle(.callMissed)
        case .connecting, .active: deferred = engine.handle(.callEnded(.dropped))
        default: break
        }
        state = engine.state
        voice.onEvent = { [weak self] event in self?.handleVoice(event) }
        voice.goodbyeProvider = { [weak self] reason in
            guard let self else { return "Say a warm one-sentence goodbye. Do not call tools." }
            return BrainPrompts.goodbyeInstructions(self.engine.state, reason: reason)
        }
        autopilot = AutopilotCaller(model: self)
    }

    func onAppear() {
        if state.transcript.isEmpty { dispatch(.start) }
        let pending = deferred
        deferred = []
        pending.forEach(perform)
    }

    // MARK: - Derived UI state

    var agentName: String { state.profile.agentName ?? "Your assistant" }
    var isNamed: Bool { state.profile.agentName != nil }
    var incomingCallVisible: Bool { ringVisible && state.call.status == .ringing }
    var callVisible: Bool { state.call.status == .connecting || state.call.status == .active }

    var chatOrbMood: OrbMood {
        if isThinking { return .thinking }
        if state.phase == .graduated { return .happy }
        return .idle
    }

    var callOrbMood: OrbMood {
        if state.call.status == .connecting || voice.status == .connecting { return .thinking }
        if voice.assistantSpeaking { return .speaking }
        if voice.userSpeaking { return .listening }
        if state.profile.gmail != nil && Policy.isComplete(state.profile) { return .happy }
        return .listening
    }

    var callStatusText: String {
        switch voice.status {
        case .connecting: return "Connecting…"
        case .ending: return "Wrapping up…"
        case .idle: return state.call.status == .connecting ? "Connecting…" : "Call ended"
        case .live:
            if voice.isMuted { return "You're muted" }
            if voice.assistantSpeaking { return "\(agentName) is speaking" }
            if voice.userSpeaking { return "Listening…" }
            return "Listening…"
        }
    }

    var chatStatusText: String {
        if isThinking { return "typing…" }
        switch state.phase {
        case .naming: return "new · setting up"
        case .onCall: return state.call.status == .ringing ? "calling you…" : "on a call"
        case .textFollowUp: return "online"
        case .graduated: return "ready"
        }
    }

    struct Suggestion: Identifiable, Hashable {
        enum Action: Hashable { case say(String), call, connectGmail, skip, openSettings }
        let title: String
        var icon: String? = nil
        let action: Action
        var id: String { title }
    }

    var suggestions: [Suggestion] {
        guard !isThinking else { return [] }
        let p = state.profile
        switch state.phase {
        case .naming:
            return ["Nova", "Atlas", "Sage", "Juno"].map { Suggestion(title: $0, action: .say($0)) }
                + [Suggestion(title: "Surprise me", icon: "sparkles", action: .say("You pick a name for yourself"))]
        case .textFollowUp:
            var s: [Suggestion] = []
            if state.call.lastEnd == .micDenied && AVAudioApplication.shared.recordPermission != .granted {
                s.append(Suggestion(title: "Turn on microphone", icon: "mic", action: .openSettings))
            }
            if p.gmail == nil && state.gmailCardVisible {
                s.append(Suggestion(title: "Connect Gmail", icon: "envelope", action: .connectGmail))
                s.append(Suggestion(title: "Maybe later", action: .say("Maybe later for Gmail")))
            }
            if Policy.nextFocus(state) == .helpNeed {
                s += ["Tame my inbox", "Organize my calendar", "Plan my week"].map { Suggestion(title: $0, action: .say($0)) }
            }
            if Policy.canUserCall(state) && (!p.has(.userName) || !p.has(.helpNeed)) {
                s.append(Suggestion(title: "Call me", icon: "phone", action: .call))
            }
            if Policy.canGraduate(state) && !Policy.isComplete(p) {
                s.append(Suggestion(title: "Skip to the app", icon: "arrow.right", action: .skip))
            }
            return s
        case .graduated:
            var s = [Suggestion(title: "What will you do first?", action: .say("What will you do first?"))]
            if p.gmail == nil { s.append(Suggestion(title: "Connect Gmail", icon: "envelope", action: .connectGmail)) }
            s.append(Suggestion(title: "Draft my morning brief", action: .say("Draft what my morning brief would look like")))
            return s
        case .onCall:
            return []
        }
    }

    // MARK: - User actions

    func send(_ text: String) { dispatch(.userMessage(text)) }

    func tap(_ s: Suggestion) {
        Haptics.light()
        switch s.action {
        case .say(let text): send(text)
        case .call: requestCall()
        case .connectGmail: showGmailSheet = true
        case .skip: dispatch(.skipRequested)
        case .openSettings:
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        }
    }

    func requestCall() { dispatch(.requestCall) }

    func acceptCall() {
        ringTask?.cancel()
        SoundFX.shared.stopRinging()
        ringVisible = false
        Haptics.rigid()
        dispatch(.callAnswered)
    }

    func declineCall() {
        ringTask?.cancel()
        SoundFX.shared.stopRinging()
        ringVisible = false
        dispatch(.callDeclined)
    }

    func hangUp() {
        voice.stop()
        SoundFX.shared.play("call_end")
        dispatch(.callEnded(.userHungUp))
    }

    func switchToText() {
        voice.stop()
        SoundFX.shared.play("call_end")
        dispatch(.callEnded(.switchedToText))
    }

    func simulateDrop() {
        guard voice.status != .idle else { return }
        voice.simulateDrop()
    }

    func connectGmail(_ email: String) {
        showGmailSheet = false
        dispatch(.gmailConnected(GmailConnection(email: email, isSimulated: true)))
    }

    /// Real Google sign-in: the label list from the Gmail API proves the connection is live.
    func connectGmail(account: GoogleAuth.Account) {
        showGmailSheet = false
        dispatch(.gmailConnected(GmailConnection(email: account.email, isSimulated: false,
                                                 labelCount: account.labelCount,
                                                 sampleLabels: Array(account.userLabels.prefix(5)))))
    }

    /// Opening the Gmail screen mid-call: the agent should wait quietly, and silence isn't a hang-up.
    func gmailSheetChanged(open: Bool) {
        voice.suspendSilenceCheck = open || showTester
        if open, voice.status == .live {
            voice.injectSystem("The user is on the Google sign-in screen now. Stay quiet and wait until they finish or speak to you.", respond: false)
        }
    }

    func cancelGmail() {
        showGmailSheet = false
        dispatch(.gmailCancelled)
    }

    func skip() { dispatch(.skipRequested) }

    func reset() {
        autopilot.stop()
        ringTask?.cancel()
        brainTask?.cancel()
        brainTask = nil
        brainQueued = false
        queuedNote = nil
        isThinking = false
        SoundFX.shared.stopRinging()
        ringVisible = false
        voice.stop()
        showTester = false
        UserDefaults.standard.removeObject(forKey: Self.storeKey)
        dispatch(.reset)
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        guard phase == .background else { return }
        if state.call.status == .ringing && ringVisible {
            declineCallSilently(.callMissed)
        } else if callVisible {
            voice.stop()
            dispatch(.callEnded(.dropped))
        }
    }

    private func declineCallSilently(_ event: OnboardingEvent) {
        ringTask?.cancel()
        SoundFX.shared.stopRinging()
        ringVisible = false
        dispatch(event)
    }

    // MARK: - Engine plumbing

    private func dispatch(_ event: OnboardingEvent) {
        let effects = engine.handle(event)
        withAnimation(Motion.spring) { state = engine.state }
        persist()
        effects.forEach(perform)
    }

    private func perform(_ effect: OnboardingEffect) {
        switch effect {
        case .runTextBrain(let note):
            runBrain(note)

        case .ring(let delay):
            ringTask?.cancel()
            ringTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(Int(delay * 1000)))
                guard let self, !Task.isCancelled, self.state.call.status == .ringing else { return }
                self.ringVisible = true
                SoundFX.shared.startRinging()
                try? await Task.sleep(for: .seconds(22))
                guard !Task.isCancelled, self.state.call.status == .ringing, self.ringVisible else { return }
                self.declineCallSilently(.callMissed)
            }

        case .connectVoice:
            Task { [weak self] in
                guard let self else { return }
                let granted = self.simulateNoMic ? false : await AVAudioApplication.requestRecordPermission()
                guard granted else { self.dispatch(.micDenied); return }
                guard !self.apiKey.isEmpty else { self.dispatch(.callFailed("missing API key")); return }
                self.voice.start(apiKey: self.apiKey,
                                 instructions: BrainPrompts.voiceInstructions(self.engine.state),
                                 tools: BrainPrompts.voiceTools,
                                 transcriptionPrompt: BrainPrompts.transcriptionPrompt(self.engine.state))
            }

        case .disconnectVoice:
            voice.stop()

        case .hangUpAfterSpeaking(let reason):
            voice.hangUpAfterSpeaking(reason, goodbye: BrainPrompts.goodbyeInstructions(engine.state, reason: reason))

        case .voiceToolResult(let callID, let output):
            voice.sendToolResult(callID: callID, output: output)

        case .voiceSystemNote(let text):
            voice.injectSystem(text)

        case .refreshVoiceInstructions:
            voice.updateInstructions(BrainPrompts.voiceInstructions(engine.state),
                                     transcriptionPrompt: BrainPrompts.transcriptionPrompt(engine.state))

        case .showGmailConnect:
            Haptics.soft()

        case .graduate:
            SoundFX.shared.play("success", volume: 0.6)

        case .haptic(let kind):
            switch kind {
            case .light: Haptics.light()
            case .success: Haptics.success()
            case .warning: Haptics.warning()
            }
        }
    }

    private func handleVoice(_ event: RealtimeVoice.Event) {
        switch event {
        case .connected:
            SoundFX.shared.play("call_connect", volume: 0.5)
            dispatch(.callConnected)
        case .transcript(let role, let text):
            dispatch(.voiceTranscript(role: role, text: text))
        case .toolCall(let name, let arguments, let callID):
            dispatch(.voiceToolCall(name: name, arguments: arguments, callID: callID))
            if name == "save_user_name" { voice.correctUserCaption(name: state.profile.userName) }
        case .ended(let reason):
            SoundFX.shared.play("call_end")
            dispatch(.callEnded(reason))
        }
    }

    /// One LLM turn at a time; turns requested meanwhile are coalesced into the next one.
    private func runBrain(_ note: String?) {
        if brainTask != nil {
            brainQueued = true
            queuedNote = note ?? queuedNote
            return
        }
        isThinking = true
        let snapshot = engine.state
        brainTask = Task { [weak self] in
            guard let self else { return }
            let started = Date()
            var result: OnboardingEvent
            do {
                let turn = try await self.brain.nextTurn(state: snapshot, note: note)
                result = .textBrainReplied(turn)
            } catch {
                result = .textBrainFailed("\(error)")
            }
            // A beat of "typing" feels more human than an instant wall of text.
            let elapsed = Date().timeIntervalSince(started)
            if elapsed < 0.6 { try? await Task.sleep(for: .milliseconds(Int((0.6 - elapsed) * 1000))) }
            guard !Task.isCancelled else { return }
            self.brainTask = nil
            self.isThinking = false
            self.dispatch(result)
            if self.brainQueued {
                self.brainQueued = false
                let n = self.queuedNote
                self.queuedNote = nil
                self.runBrain(n)
            }
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: Self.storeKey)
        }
    }
}

enum AppSecrets {
    static let overrideKey = "openai.key.override"

    /// iOS OAuth client for "Sign in with Google" (not a secret). Secrets.json can override it.
    static var googleClientID: String {
        if let url = Bundle.main.url(forResource: "Secrets", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String],
           let id = obj["GOOGLE_IOS_CLIENT_ID"], !id.isEmpty { return id }
        return GoogleAuth.defaultClientID
    }

    static var openAIKey: String {
        if let k = UserDefaults.standard.string(forKey: overrideKey), !k.isEmpty { return k }
        if let url = Bundle.main.url(forResource: "Secrets", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String],
           let k = obj["OPENAI_API_KEY"], !k.isEmpty { return k }
        return ""
    }
}
