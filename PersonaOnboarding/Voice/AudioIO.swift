import AVFoundation

/// Full-duplex audio for the call: mic → 24 kHz PCM16 chunks, model audio → speaker.
///
/// On a device it uses Apple's voice-processing I/O (echo cancellation) so the agent doesn't hear itself.
/// Without echo cancellation (Simulator, or a device that refuses it) the mic is gated while the agent talks.
///
/// Built to never go silent: every call gets a fresh engine; whenever iOS changes the audio hardware under
/// it (speaker toggle, Bluetooth, route change, media reset) or the output stops rendering, the engine is
/// rebuilt from scratch and whatever the agent hadn't finished saying is replayed from where it was.
final class AudioIO {
    var onMicChunk: ((Data) -> Void)?
    var onLevels: ((_ input: Float, _ output: Float) -> Void)?

    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private let playFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!
    private let sendFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true)!
    private let lock = NSLock()
    private var inputLevel: Float = 0
    private var running = false
    private var observers: [NSObjectProtocol] = []
    private var rebuildPending = false
    private var recentRebuilds: [CFAbsoluteTime] = []

    // Playback clock (time-based, so a missed completion callback can never leave us "speaking" forever).
    private var playbackEnd: CFAbsoluteTime = 0
    private var itemStart: CFAbsoluteTime?
    private var itemScheduledSeconds: Double = 0
    /// Audio handed to the player that may not have been heard yet (replayed after an engine rebuild).
    private var queued: [(start: CFAbsoluteTime, buffer: AVAudioPCMBuffer)] = []
    /// Loudness of what's playing, 40 ms at a time, stamped with when it's heard. Drives the orb, and
    /// doesn't depend on metering the output hardware.
    private var levelTimeline: [(at: CFAbsoluteTime, level: Float)] = []
    /// Last time the output mixer rendered anything (proves the engine is alive).
    private var lastRender: CFAbsoluteTime = 0

    #if targetEnvironment(simulator)
    private static let wantsVoiceProcessing = false
    #else
    private static let wantsVoiceProcessing = true
    #endif
    /// Set once voice processing misbehaves on this device; later engines go straight to the safe path.
    private static var voiceProcessingFailed = false

    private var halfDuplex = true
    private var wantsSpeaker = true
    /// Hardware formats the current engine was wired for (a change means the wiring must be rebuilt).
    private var wiredFormats = ""

    // Echo guard (touched only on the mic tap's thread, except the resets in start()).
    /// The call's first agent reply has finished playing (the echo canceller has had time to adapt).
    private var guardWarmedUp = false
    private var heardAgent = false
    /// Typical mic level while only the agent's own voice leaks back from the speaker.
    private var echoFloor: Float = 0.3
    private var loudSince: CFAbsoluteTime?
    private var gateOpenUntil: CFAbsoluteTime = 0
    /// The last few mic chunks held back while gated, sent first when real speech opens the gate.
    private var preRoll: [Data] = []
    private var headsetRoute = false

    private(set) var voiceProcessing = false
    /// Diagnostics: mic chunks held back as echo, and times real speech got through while the agent talked.
    private(set) var guardedChunks = 0
    private(set) var bargeIns = 0
    private(set) var micChunks = 0
    private(set) var outChunks = 0
    private(set) var rebuilds = 0
    private(set) var info = "idle"
    private(set) var route = "—"
    /// Loudest level seen at the output mixer / mic this call (diagnostics: proves audio flowed).
    private(set) var outputPeak: Float = 0
    private(set) var inputPeak: Float = 0

    var muted = false
    /// Set while the Tester "simulated caller" streams synthetic speech, so real mic audio doesn't interleave.
    var pauseMic = false

    /// True while model audio is still queued or playing.
    var isPlaying: Bool {
        lock.lock(); defer { lock.unlock() }
        return CFAbsoluteTimeGetCurrent() < playbackEnd
    }

    /// Milliseconds of the current assistant item the user has actually heard (for truncation on barge-in).
    var playedMilliseconds: Int {
        lock.lock(); defer { lock.unlock() }
        guard let start = itemStart else { return 0 }
        let heard = min(max(CFAbsoluteTimeGetCurrent() - start, 0), itemScheduledSeconds)
        return Int(heard * 1000)
    }

    /// True when a headset, AirPods or car audio carries the call (close-talking mic, not the room).
    var hasHeadset: Bool {
        let headsetPorts: [AVAudioSession.Port] = [.headphones, .bluetoothHFP, .bluetoothA2DP, .bluetoothLE, .carAudio]
        return AVAudioSession.sharedInstance().currentRoute.outputs.contains { headsetPorts.contains($0.portType) }
    }

    /// Called when a new assistant message starts.
    func resetPlayedCounter() {
        lock.lock(); itemStart = nil; itemScheduledSeconds = 0; lock.unlock()
    }

    // MARK: - Lifecycle

    func start(speaker: Bool) throws {
        wantsSpeaker = speaker
        micChunks = 0; outChunks = 0; rebuilds = 0; outputPeak = 0; inputPeak = 0
        recentRebuilds = []
        guardWarmedUp = false; heardAgent = false; echoFloor = 0.35; loudSince = nil; gateOpenUntil = 0
        preRoll = []; guardedChunks = 0; bargeIns = 0
        clearPlayback()

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: categoryOptions)
        try? session.setPreferredIOBufferDuration(0.02)
        try session.setActive(true)
        // Settle the route before the engine exists, so starting it doesn't trigger a hardware change.
        try? session.overrideOutputAudioPort(speaker ? .speaker : .none)

        let useVP = Self.wantsVoiceProcessing && !Self.voiceProcessingFailed
        do {
            try buildEngine(voiceProcessing: useVP)
        } catch where useVP {
            print("[audio] engine with echo cancellation failed (\(error.localizedDescription)); retrying without")
            Self.voiceProcessingFailed = true
            try buildEngine(voiceProcessing: false)
        }
        running = true
        observe()
        applySpeakerRoute()
        print("[audio] started: \(info) · \(route)")
    }

    func stop() {
        guard running else { return }
        running = false
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        teardownEngine()
        clearPlayback()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        print("[audio] stopped (mic chunks \(micChunks), audio chunks \(outChunks), rebuilds \(rebuilds), out peak \(outputPeak))")
    }

    /// Speaker ↔ earpiece. `.defaultToSpeaker` would override the earpiece choice, so the category changes too.
    /// If iOS reconfigures the hardware for it, the engine is rebuilt and queued speech replays.
    func setSpeaker(_ on: Bool) {
        wantsSpeaker = on
        guard running else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .voiceChat, options: categoryOptions)
        try? session.overrideOutputAudioPort(on ? .speaker : .none)
        updateRoute()
        print("[audio] speaker \(on ? "on" : "off"): \(route)")
    }

    private var categoryOptions: AVAudioSession.CategoryOptions {
        wantsSpeaker ? [.defaultToSpeaker, .allowBluetoothHFP] : [.allowBluetoothHFP]
    }

    /// Called a few times a second during the call: if the engine stopped or stopped rendering (iOS can do
    /// that when it reconfigures audio), rebuild it so the agent can't go quiet for the rest of the call.
    func checkHealth() {
        guard running, !rebuildPending else { return }
        lock.lock()
        let now = CFAbsoluteTimeGetCurrent()
        let sinceRender = now - lastRender
        let shouldBePlaying = now < playbackEnd
        lock.unlock()
        if !(engine?.isRunning ?? false) {
            scheduleRecovery("engine stopped")
        } else if shouldBePlaying && sinceRender > 1.0 {
            scheduleRecovery("output stalled", forceRebuild: true)
        }
    }

    // MARK: - Engine

    private func buildEngine(voiceProcessing wantVP: Bool) throws {
        teardownEngine()
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let input = engine.inputNode
        var vp = false
        if wantVP {
            do {
                try input.setVoiceProcessingEnabled(true)
                vp = true
            } catch {
                print("[audio] echo cancellation unavailable: \(error.localizedDescription)")
                Self.voiceProcessingFailed = true
            }
        }

        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0,
              let converter = AVAudioConverter(from: inFormat, to: sendFormat) else {
            throw NSError(domain: "AudioIO", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone input available"])
        }
        input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { [weak self] buffer, _ in
            self?.handleMic(buffer, converter: converter)
        }

        engine.attach(player)
        let mixer = engine.mainMixerNode
        engine.connect(player, to: mixer, format: playFormat)
        mixer.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            self?.meterOutput(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            mixer.removeTap(onBus: 0)
            throw error
        }
        player.play()

        self.engine = engine
        self.player = player
        voiceProcessing = vp
        halfDuplex = !vp   // no echo cancellation: never let the agent hear (and answer) itself
        lock.lock(); lastRender = CFAbsoluteTimeGetCurrent(); lock.unlock()
        let out = engine.outputNode.outputFormat(forBus: 0)
        wiredFormats = Self.formatKey(engine)
        info = "in \(Int(inFormat.sampleRate)) Hz × \(inFormat.channelCount) · out \(Int(out.sampleRate)) Hz × \(out.channelCount) · echo cancel \(vp ? "on" : "off")\(halfDuplex ? " · half-duplex" : "")"
    }

    private func teardownEngine() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.mainMixerNode.removeTap(onBus: 0)
        player?.stop()
        engine.stop()
        if let player { engine.detach(player) }
        self.engine = nil
        self.player = nil
    }

    private static func formatKey(_ engine: AVAudioEngine) -> String {
        let i = engine.inputNode.outputFormat(forBus: 0), o = engine.outputNode.outputFormat(forBus: 0)
        return "\(i.sampleRate)/\(i.channelCount)>\(o.sampleRate)/\(o.channelCount)"
    }

    private var forceRebuildPending = false

    private func scheduleRecovery(_ reason: String, delay: Double = 0.15, forceRebuild: Bool = false) {
        guard running else { return }
        forceRebuildPending = forceRebuildPending || forceRebuild
        guard !rebuildPending else { return }
        rebuildPending = true
        // Coalesce the burst of notifications iOS sends for one change.
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            let force = self.forceRebuildPending
            self.rebuildPending = false
            self.forceRebuildPending = false
            self.recover(reason, forceRebuild: force)
        }
    }

    /// Bring audio back after iOS reconfigured it. If the hardware formats are unchanged, restarting the same
    /// engine is enough (and keeps echo cancellation settled); otherwise build a fresh one. Either way, the
    /// part of the agent's sentence that hadn't been heard is played again from where it stopped.
    private func recover(_ reason: String, forceRebuild: Bool) {
        guard running else { return }
        let now = CFAbsoluteTimeGetCurrent()
        recentRebuilds = recentRebuilds.filter { now - $0 < 20 } + [now]
        if recentRebuilds.count > 8 {
            print("[audio] too many recoveries; leaving the engine as is")
            return
        }
        rebuilds += 1
        let pending = unplayedAudio()
        var how = "restarted"
        if !forceRebuild, let engine, let player, Self.formatKey(engine) == wiredFormats {
            player.stop()   // drop anything the stopped engine still holds, so nothing plays twice
            do {
                if !engine.isRunning { try engine.start() }
                player.play()
                lock.lock(); lastRender = CFAbsoluteTimeGetCurrent(); lock.unlock()
            } catch {
                print("[audio] restart failed (\(error.localizedDescription)); rebuilding")
                how = rebuildEngine()
            }
        } else {
            how = rebuildEngine()
        }
        applySpeakerRoute()
        replay(pending)
        var replayedFrames = 0
        for b in pending { replayedFrames += Int(b.frameLength) }
        let replayed = String(format: "%.1f", Double(replayedFrames) / 24_000)
        print("[audio] \(how) (\(reason)): \(info) · \(route) · replayed \(replayed) s")
    }

    private func rebuildEngine() -> String {
        // Echo cancellation that keeps breaking on this device: fall back to the plain path.
        if voiceProcessing && recentRebuilds.count >= 4 { Self.voiceProcessingFailed = true }
        let useVP = Self.wantsVoiceProcessing && !Self.voiceProcessingFailed
        do {
            try buildEngine(voiceProcessing: useVP)
        } catch {
            print("[audio] rebuild failed (\(error.localizedDescription))")
            if useVP {
                Self.voiceProcessingFailed = true
                try? buildEngine(voiceProcessing: false)
            }
        }
        return "rebuilt"
    }

    // MARK: - Route

    private func observe() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] note in
            guard let self, let changed = note.object as? AVAudioEngine, changed === self.engine else { return }
            self.scheduleRecovery("hardware changed")
        })
        observers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.routeChanged()
        })
        observers.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            self?.scheduleRecovery("media services reset", delay: 0.5, forceRebuild: true)
        })
    }

    private func routeChanged() {
        guard running else { return }
        applySpeakerRoute()
        print("[audio] route: \(route)")
    }

    /// iOS can fall back to the earpiece (e.g. when echo cancellation starts); if the user wants the
    /// speaker, move back. Only acts when actually on the earpiece, so it never causes route churn.
    private func applySpeakerRoute() {
        let session = AVAudioSession.sharedInstance()
        if wantsSpeaker, session.currentRoute.outputs.contains(where: { $0.portType == .builtInReceiver }) {
            try? session.overrideOutputAudioPort(.speaker)
            print("[audio] was on the earpiece; moved to the speaker")
        }
        updateRoute()
    }

    private func updateRoute() {
        let r = AVAudioSession.sharedInstance().currentRoute
        let out = r.outputs.map(Self.portName).joined(separator: "+")
        let inp = r.inputs.map(Self.portName).joined(separator: "+")
        route = "out \(out.isEmpty ? "none" : out) · in \(inp.isEmpty ? "none" : inp)"
        headsetRoute = hasHeadset
    }

    private static func portName(_ p: AVAudioSessionPortDescription) -> String {
        switch p.portType {
        case .builtInSpeaker: return "speaker"
        case .builtInReceiver: return "earpiece"
        case .builtInMic: return "mic"
        case .headphones, .headsetMic: return "wired"
        case .bluetoothHFP, .bluetoothA2DP, .bluetoothLE: return "bluetooth(\(p.portName))"
        case .carAudio: return "car"
        case .airPlay: return "airplay"
        default: return p.portName
        }
    }

    // MARK: - Playback

    /// Queue a chunk of 24 kHz little-endian PCM16 from the model.
    func play(pcm16 data: Data) {
        guard running else { return }
        let frames = data.count / 2
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: AVAudioFrameCount(frames)) else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        let dst = buffer.floatChannelData![0]
        data.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Int16.self)
            for i in 0..<frames { dst[i] = Float(Int16(littleEndian: src[i])) / 32768.0 }
        }
        outChunks += 1
        schedule(buffer, newItemAudio: true)
    }

    private func schedule(_ buffer: AVAudioPCMBuffer, newItemAudio: Bool) {
        let frames = Int(buffer.frameLength)
        let duration = Double(frames) / 24_000
        let levels = Self.windowLevels(buffer)
        lock.lock()
        let now = CFAbsoluteTimeGetCurrent()
        let startAt = max(now, playbackEnd)
        if newItemAudio {
            if itemStart == nil { itemStart = startAt }
            itemScheduledSeconds += duration
        }
        playbackEnd = startAt + duration
        queued.removeAll { $0.start + Double($0.buffer.frameLength) / 24_000 < now }
        queued.append((startAt, buffer))
        levelTimeline.removeAll { $0.at < now - 0.1 }
        for (i, level) in levels.enumerated() { levelTimeline.append((startAt + Double(i) * 0.04, level)) }
        lock.unlock()
        guard let player else { return }
        if !player.isPlaying { player.play() }
        player.scheduleBuffer(buffer, completionHandler: nil)
    }

    /// What was handed to the old engine but not heard yet (the first buffer trimmed to where it was).
    private func unplayedAudio() -> [AVAudioPCMBuffer] {
        lock.lock()
        let now = CFAbsoluteTimeGetCurrent()
        let items = queued
        queued = []
        levelTimeline = []
        playbackEnd = 0
        lock.unlock()
        var out: [AVAudioPCMBuffer] = []
        for item in items {
            let total = Int(item.buffer.frameLength)
            let playedFrames = max(0, Int((now - item.start) * 24_000))
            guard playedFrames < total else { continue }
            if playedFrames == 0 { out.append(item.buffer); continue }
            let remaining = total - playedFrames
            guard let copy = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: AVAudioFrameCount(remaining)),
                  let src = item.buffer.floatChannelData?[0], let dst = copy.floatChannelData?[0] else { continue }
            copy.frameLength = AVAudioFrameCount(remaining)
            dst.update(from: src.advanced(by: playedFrames), count: remaining)
            out.append(copy)
        }
        return out
    }

    private func replay(_ buffers: [AVAudioPCMBuffer]) {
        for b in buffers { schedule(b, newItemAudio: false) }
    }

    /// Barge-in: drop everything queued right now.
    func stopPlayback() {
        guard running else { return }
        player?.stop()
        clearPlayback()
        player?.play()
    }

    private func clearPlayback() {
        lock.lock()
        playbackEnd = 0
        itemStart = nil
        itemScheduledSeconds = 0
        queued = []
        levelTimeline = []
        lock.unlock()
    }

    /// Loudness of the audio being heard right now (0 when nothing plays).
    private func playingLevel() -> Float {
        lock.lock(); defer { lock.unlock() }
        let now = CFAbsoluteTimeGetCurrent()
        guard now < playbackEnd else { return 0 }
        var level: Float = 0
        for entry in levelTimeline where entry.at <= now { level = entry.level }
        return level
    }

    // MARK: - Mic & meters

    private func handleMic(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter) {
        let level = Self.rms(buffer)
        inputLevel = inputLevel * 0.6 + level * 0.4
        if inputLevel > inputPeak { inputPeak = inputLevel }
        onLevels?(inputLevel, playingLevel())

        guard !muted, !pauseMic else { return }
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock(); let end = playbackEnd; lock.unlock()
        let agentTalking = now < end + 0.3   // plus the room's echo tail
        if agentTalking { heardAgent = true } else if heardAgent { guardWarmedUp = true }

        // No echo cancellation at all: never feed the agent its own voice.
        if halfDuplex && now < end + 0.35 { return }
        guard let data = convert(buffer, with: converter) else { return }

        if !agentTalking || halfDuplex || headsetRoute {
            preRoll.removeAll()
            loudSince = nil
            send(data)
            return
        }

        // Echo guard. Even with echo cancellation, some of the agent's own voice leaks back from the speaker
        // (most at the start of a call, while the canceller adapts). Sent as-is, it made the server think the
        // user spoke: the agent cut itself off and "heard" words nobody said. So while the agent talks, only
        // speech clearly louder than that leak, lasting ~150 ms, gets through (its held-back onset first).
        // Nothing gets through during the call's first reply.
        let threshold = min(0.85, max(0.5, echoFloor + 0.25))
        if level > threshold {
            if loudSince == nil { loudSince = now }
        } else {
            loudSince = nil
        }
        let sustained = loudSince.map { now - $0 >= 0.15 } ?? false
        if guardWarmedUp && (sustained || now < gateOpenUntil) {
            if sustained {
                if now >= gateOpenUntil { bargeIns += 1 }
                gateOpenUntil = now + 0.6
            }
            for chunk in preRoll { send(chunk) }
            preRoll.removeAll()
            send(data)
        } else {
            // Learn how loud the leak is (during the first reply everything heard is the leak).
            if !guardWarmedUp || loudSince == nil { echoFloor += (level - echoFloor) * 0.05 }
            preRoll.append(data)
            if preRoll.count > 6 { preRoll.removeFirst(preRoll.count - 6) }
            guardedChunks += 1
        }
    }

    private func send(_ data: Data) {
        micChunks += 1
        onMicChunk?(data)
    }

    private func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter) -> Data? {
        let ratio = sendFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: sendFormat, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0, let ch = out.int16ChannelData else { return nil }
        return Data(bytes: ch[0], count: Int(out.frameLength) * 2)
    }

    private func meterOutput(_ buffer: AVAudioPCMBuffer) {
        let level = Self.rms(buffer)
        lock.lock()
        lastRender = CFAbsoluteTimeGetCurrent()
        if level > outputPeak { outputPeak = level }
        lock.unlock()
    }

    private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        var i = 0
        while i < n { sum += data[i] * data[i]; i += 2 }
        return loudness(sqrt(sum / Float(max(n / 2, 1))))
    }

    /// RMS every 40 ms of a 24 kHz buffer, mapped to 0…1.
    private static func windowLevels(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let data = buffer.floatChannelData?[0] else { return [] }
        let n = Int(buffer.frameLength)
        var levels: [Float] = []
        var i = 0
        while i < n {
            let m = min(960, n - i)
            var sum: Float = 0
            for k in 0..<m { let v = data[i + k]; sum += v * v }
            levels.append(loudness(sqrt(sum / Float(max(m, 1)))))
            i += 960
        }
        return levels
    }

    /// Map roughly -50 dB…-5 dB to 0…1.
    private static func loudness(_ rms: Float) -> Float {
        let db = 20 * log10(max(rms, 0.000_01))
        return min(max((db + 50) / 45, 0), 1)
    }
}
