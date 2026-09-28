import Foundation
import Observation
import AVFoundation

/// The voice call: OpenAI Realtime API (gpt-realtime-2.1) over a WebSocket, with server-side
/// semantic VAD, live captions (gpt-live-transcribe), function tools, barge-in, and silence/drop handling.
@Observable
@MainActor
final class RealtimeVoice {
    enum Status: Equatable { case idle, connecting, live, ending }

    enum Event {
        case connected
        case transcript(role: Message.Role, text: String)
        case toolCall(name: String, arguments: String, callID: String)
        case ended(CallEndReason)
    }

    // Observable UI state
    private(set) var status: Status = .idle
    private(set) var assistantLevel: Float = 0
    private(set) var userLevel: Float = 0
    private(set) var assistantSpeaking = false
    private(set) var userSpeaking = false
    private(set) var assistantCaption = ""
    private(set) var userCaption = ""
    private(set) var lastError: String?
    private(set) var diagnostics = "not connected"
    private(set) var isMuted = false
    private(set) var speakerOn = true

    func setMuted(_ muted: Bool) {
        isMuted = muted
        audio.muted = muted
    }

    func setSpeaker(_ on: Bool) {
        speakerOn = on
        audio.setSpeaker(on)
    }

    var onEvent: ((Event) -> Void)?

    // Config
    var model = "gpt-realtime-2.1"
    var voice = "marin"
    var transcriptionModel = "gpt-live-transcribe"

    @ObservationIgnored private let audio = AudioIO()
    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private var urlSession: URLSession?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var responseActive = false
    @ObservationIgnored private var responseHadAudio = false
    @ObservationIgnored private var responseHadToolCall = false
    @ObservationIgnored private var responseTranscript = ""
    @ObservationIgnored private var goodbyeRequested = false
    @ObservationIgnored private var goodbyeStarted = false
    @ObservationIgnored private var goodbyeFinished = false
    @ObservationIgnored private var goodbyeInstructions = "Say a warm one-sentence goodbye. Do not call tools."
    @ObservationIgnored private var currentAssistantItem: String?
    @ObservationIgnored private var lastActivity = Date()
    @ObservationIgnored private var nudgedForSilence = false
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    @ObservationIgnored private var pendingHangUp: CallEndReason?
    @ObservationIgnored private var hangUpDeadline: Date?
    @ObservationIgnored private var sendQueue = DispatchQueue(label: "voice.send")
    @ObservationIgnored private var didReportEnd = false
    @ObservationIgnored private var interruptionObserver: NSObjectProtocol?
    @ObservationIgnored private var eventsReceived = 0
    @ObservationIgnored private var apiKey = ""
    private(set) var simulatingCaller = false
    /// While a reviewer has the Tester panel open, don't hang up on them for being quiet.
    var suspendSilenceCheck = false

    // MARK: - Lifecycle

    func start(apiKey: String, instructions: String, tools: [[String: Any]]) {
        guard status == .idle else { return }
        self.apiKey = apiKey
        generation += 1
        let gen = generation
        status = .connecting
        didReportEnd = false
        pendingHangUp = nil
        goodbyeRequested = false
        goodbyeStarted = false
        goodbyeFinished = false
        nudgedForSilence = false
        assistantCaption = ""
        userCaption = ""
        lastError = nil

        var req = URLRequest(url: URL(string: "wss://api.openai.com/v1/realtime?model=\(model)")!)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 15
        let session = URLSession(configuration: .default)
        urlSession = session
        let ws = session.webSocketTask(with: req)
        socket = ws
        ws.resume()
        receive(gen)

        send([
            "type": "session.update",
            "session": [
                "type": "realtime",
                "model": model,
                "instructions": instructions,
                "output_modalities": ["audio"],
                "audio": [
                    "input": [
                        "format": ["type": "audio/pcm", "rate": 24_000],
                        "turn_detection": ["type": "semantic_vad", "eagerness": "auto", "create_response": true, "interrupt_response": true],
                        "transcription": ["model": transcriptionModel],
                        "noise_reduction": ["type": "near_field"],
                    ],
                    "output": [
                        "format": ["type": "audio/pcm", "rate": 24_000],
                        "voice": voice,
                    ],
                ],
                "tools": tools,
                "tool_choice": "auto",
            ] as [String: Any],
        ])

        // If the handshake doesn't complete, treat it as a failed call instead of hanging forever.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard let self, self.generation == gen, self.status == .connecting else { return }
            self.finish(.failed, error: "Timed out connecting")
        }
    }

    /// Intentional stop by the app (no event is reported back).
    func stop() {
        didReportEnd = true
        teardown()
    }

    /// Chaos button: behaves exactly like the network dropping mid-call.
    func simulateDrop() {
        socket?.cancel(with: .abnormalClosure, reason: nil)
        finish(.dropped, error: "Simulated drop")
    }

    func updateInstructions(_ instructions: String) {
        guard status == .live || status == .connecting else { return }
        send(["type": "session.update", "session": ["type": "realtime", "instructions": instructions]])
    }

    func sendToolResult(callID: String, output: String) {
        send(["type": "conversation.item.create", "item": ["type": "function_call_output", "call_id": callID, "output": output]])
    }

    /// Adds an app event to the conversation (e.g. Gmail connected) and lets the agent react.
    func injectSystem(_ text: String, respond: Bool = true) {
        guard status == .live else { return }
        send(["type": "conversation.item.create", "item": ["type": "message", "role": "system", "content": [["type": "input_text", "text": text]]]])
        if respond && !responseActive { send(["type": "response.create"]) }
        lastActivity = Date()
    }

    /// True while the model is generating a response (for the autopilot caller's turn-taking).
    var isResponding: Bool { responseActive }

    /// Tester tool: speaks `text` as the caller (OpenAI TTS → the same audio input path as the mic),
    /// so the whole voice pipeline (VAD, transcription, tools, barge-in) runs without a human.
    func simulateCaller(_ text: String) {
        Task { await speakAsCaller(text) }
    }

    func speakAsCaller(_ text: String, voice ttsVoice: String = "ash") async {
        guard status == .live, !simulatingCaller else { return }
        simulatingCaller = true
        defer {
            simulatingCaller = false
            audio.pauseMic = false
            lastActivity = Date()
        }
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/speech")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": "gpt-4o-mini-tts", "voice": ttsVoice, "input": text, "response_format": "pcm",
        ])
        guard let (pcm, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200, pcm.count > 0 else {
            lastError = "Simulated caller: TTS failed"
            return
        }
        guard status == .live else { return }
        audio.pauseMic = true
        // Stream like a microphone would, in real time, then ~1.2 s of silence so VAD ends the turn.
        let all = pcm + Data(count: 24_000 * 2 * 12 / 10)
        var i = 0
        while i < all.count, status == .live {
            let end = min(i + 4_800, all.count)   // 100 ms of 24 kHz PCM16
            send(["type": "input_audio_buffer.append", "audio": all.subdata(in: i..<end).base64EncodedString()])
            i = end
            lastActivity = Date()
            try? await Task.sleep(for: .milliseconds(95))
        }
    }

    /// Let the goodbye finish playing, then end the call.
    func hangUpAfterSpeaking(_ reason: CallEndReason, goodbye: String) {
        pendingHangUp = reason
        goodbyeInstructions = goodbye
        hangUpDeadline = Date().addingTimeInterval(12)
        status = .ending
    }

    // MARK: - Internals

    private func beginAudio() {
        audio.onMicChunk = { [weak self] data in
            let b64 = data.base64EncodedString()
            Task { @MainActor [weak self] in
                self?.send(["type": "input_audio_buffer.append", "audio": b64])
            }
        }
        audio.onLevels = { [weak self] input, output in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.userLevel = self.isMuted ? 0 : input
                self.assistantLevel = output
            }
        }
        do {
            try audio.start()
            audio.muted = isMuted
            audio.setSpeaker(speakerOn)
        } catch {
            finish(.failed, error: "Audio: \(error.localizedDescription)")
            return
        }
        status = .live
        lastActivity = Date()
        // A real phone call, Siri or an alarm interrupting our audio = the call dropped.
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            Task { @MainActor [weak self] in self?.finish(.dropped, error: "Audio interrupted") }
        }
        onEvent?(.connected)
        // The agent speaks first.
        send(["type": "response.create"])
        startWatchdog()
    }

    private func startWatchdog() {
        watchdog?.cancel()
        let gen = generation
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, self.generation == gen else { return }
                self.tick()
            }
        }
    }

    private func tick() {
        let playing = audio.isPlaying
        assistantSpeaking = playing
        diagnostics = "\(audio.info) · mic chunks \(audio.micChunks) · audio chunks \(audio.outChunks) · events \(eventsReceived)"
        if playing || userSpeaking || responseActive { lastActivity = Date() }

        if let reason = pendingHangUp {
            let deadlinePassed = (hangUpDeadline ?? .distantFuture) < Date()
            // Hang up only once the goodbye response has been generated AND fully played.
            if (goodbyeFinished && !playing) || deadlinePassed {
                pendingHangUp = nil
                Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(450))
                    self?.finish(reason, error: nil)
                }
            }
            return
        }

        guard status == .live else { return }
        if suspendSilenceCheck || simulatingCaller { lastActivity = Date(); return }
        let quiet = Date().timeIntervalSince(lastActivity)
        if quiet > 10, !nudgedForSilence {
            nudgedForSilence = true
            injectSystem("The line has been quiet for about 10 seconds. Check in once, briefly and kindly (e.g. \"Still with me?\").")
        } else if quiet > 24 {
            finish(.silence, error: nil)
        }
    }

    private func finish(_ reason: CallEndReason, error: String?) {
        if let error { lastError = error }
        let shouldReport = !didReportEnd
        didReportEnd = true
        teardown()
        if shouldReport { onEvent?(.ended(reason)) }
    }

    private func teardown() {
        generation += 1
        if let o = interruptionObserver { NotificationCenter.default.removeObserver(o); interruptionObserver = nil }
        watchdog?.cancel()
        watchdog = nil
        audio.onMicChunk = nil
        audio.onLevels = nil
        audio.stop()
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        status = .idle
        responseActive = false
        assistantSpeaking = false
        userSpeaking = false
        assistantLevel = 0
        userLevel = 0
        pendingHangUp = nil
    }

    private func send(_ object: [String: Any]) {
        guard let socket, let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(text)) { error in
            if let error { print("[voice] send error: \(error.localizedDescription)") }
        }
    }

    private func receive(_ gen: Int) {
        socket?.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.generation == gen else { return }
                switch result {
                case .failure(let error):
                    // Network loss, server close, airplane mode…
                    let wasLive = self.status == .live || self.status == .ending
                    self.finish(wasLive ? .dropped : .failed, error: error.localizedDescription)
                case .success(let message):
                    switch message {
                    case .string(let text): self.handle(text)
                    case .data(let data): self.handle(String(decoding: data, as: UTF8.self))
                    @unknown default: break
                    }
                    self.receive(gen)
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let type = obj["type"] as? String else { return }
        eventsReceived += 1

        switch type {
        case "session.updated":
            if status == .connecting { beginAudio() }

        case "input_audio_buffer.speech_started":
            userSpeaking = true
            userCaption = ""
            lastActivity = Date()
            nudgedForSilence = false
            // Barge-in: stop talking immediately and tell the server how much was actually heard.
            if audio.isPlaying {
                let heard = audio.playedMilliseconds
                audio.stopPlayback()
                if let item = currentAssistantItem {
                    send(["type": "conversation.item.truncate", "item_id": item, "content_index": 0, "audio_end_ms": heard])
                }
            }

        case "input_audio_buffer.speech_stopped":
            userSpeaking = false
            lastActivity = Date()

        case "conversation.item.input_audio_transcription.delta":
            if let d = obj["delta"] as? String { userCaption += d }

        case "conversation.item.input_audio_transcription.completed":
            let t = (obj["transcript"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty {
                userCaption = t
                onEvent?(.transcript(role: .user, text: t))
            }

        case "response.created":
            if goodbyeRequested && !goodbyeStarted { goodbyeStarted = true }
            responseActive = true
            responseHadAudio = false
            responseHadToolCall = false
            responseTranscript = ""

        case "response.output_item.added":
            if let item = obj["item"] as? [String: Any], item["type"] as? String == "message" {
                currentAssistantItem = item["id"] as? String
                audio.resetPlayedCounter()
                assistantCaption = ""
            }

        case "response.output_audio.delta":
            if let d = obj["delta"] as? String, let data = Data(base64Encoded: d) {
                responseHadAudio = true
                audio.play(pcm16: data)
                lastActivity = Date()
            }

        case "response.output_audio_transcript.delta":
            if let d = obj["delta"] as? String {
                assistantCaption += d
                responseTranscript += d
            }

        case "response.output_audio_transcript.done":
            let t = (obj["transcript"] as? String ?? assistantCaption).trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { onEvent?(.transcript(role: .assistant, text: t)) }

        case "response.function_call_arguments.done":
            responseHadToolCall = true
            let name = obj["name"] as? String ?? ""
            let args = obj["arguments"] as? String ?? "{}"
            let callID = obj["call_id"] as? String ?? ""
            onEvent?(.toolCall(name: name, arguments: args, callID: callID))

        case "response.done":
            responseActive = false
            if goodbyeStarted && !goodbyeFinished { goodbyeFinished = true }
            if pendingHangUp != nil {
                // finish_call: ask for one real spoken goodbye, then hang up once it has played.
                if !goodbyeRequested {
                    goodbyeRequested = true
                    hangUpDeadline = Date().addingTimeInterval(12)
                    send(["type": "response.create", "response": ["instructions": goodbyeInstructions, "tool_choice": "none"]])
                }
            } else if responseHadToolCall && status == .live && !responseTranscript.contains("?") {
                // Tools ran and the agent didn't ask anything yet: let it continue with the tool results.
                send(["type": "response.create"])
            }

        case "error":
            let err = obj["error"] as? [String: Any]
            let msg = err?["message"] as? String ?? "Unknown error"
            let code = err?["code"] as? String ?? ""
            print("[voice] error \(code): \(msg)")
            lastError = msg
            // Harmless races (e.g. cancelling a finished response) must not kill the call.
            let fatal = ["invalid_api_key", "model_not_found", "insufficient_quota", "session_expired"].contains(code)
            if fatal || status == .connecting { finish(.failed, error: msg) }

        default:
            break
        }
    }
}
