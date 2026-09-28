import AVFoundation

/// Full-duplex audio for the call: mic → 24 kHz PCM16 chunks, model audio → speaker.
/// On a device it uses Apple's voice-processing I/O (echo cancellation) so the agent doesn't hear
/// itself. In the Simulator voice processing is unreliable, so the mic is gated while the agent talks.
final class AudioIO {
    var onMicChunk: ((Data) -> Void)?
    var onLevels: ((_ input: Float, _ output: Float) -> Void)?

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var converter: AVAudioConverter?
    private let playFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!
    private let sendFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true)!
    private let lock = NSLock()
    private var inputLevel: Float = 0
    private var outputLevel: Float = 0
    private var running = false
    private var configObserver: NSObjectProtocol?

    // Playback clock (time-based, so a missed completion callback can never leave us "speaking" forever).
    private var playbackEnd: CFAbsoluteTime = 0
    private var itemStart: CFAbsoluteTime?
    private var itemScheduledSeconds: Double = 0

    #if targetEnvironment(simulator)
    private let useVoiceProcessing = false
    private let halfDuplex = true
    #else
    private let useVoiceProcessing = true
    private let halfDuplex = false
    #endif

    private(set) var micChunks = 0
    private(set) var outChunks = 0
    private(set) var info = "idle"

    var muted = false

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

    /// Called when a new assistant message starts.
    func resetPlayedCounter() {
        lock.lock(); itemStart = nil; itemScheduledSeconds = 0; lock.unlock()
    }

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
        try? session.setPreferredIOBufferDuration(0.02)
        try session.setActive(true)

        let input = engine.inputNode
        var vp = false
        if useVoiceProcessing {
            do {
                try input.setVoiceProcessingEnabled(true)
                vp = true
            } catch {
                print("[audio] voice processing unavailable: \(error)")
            }
        }

        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            throw NSError(domain: "AudioIO", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone input available"])
        }
        converter = AVAudioConverter(from: inFormat, to: sendFormat)
        input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { [weak self] buffer, _ in
            self?.handleMic(buffer)
        }

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playFormat)
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            self?.meterOutput(buffer)
        }
        engine.prepare()
        try engine.start()
        player.play()
        running = true
        info = "in \(Int(inFormat.sampleRate)) Hz × \(inFormat.channelCount) · echo cancel \(vp ? "on" : "off")\(halfDuplex ? " · half-duplex" : "")"
        print("[audio] started: \(info)")

        // Route changes / interruptions can stop the engine: bring it back instead of going silent.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.recover()
        }
    }

    func stop() {
        guard running else { return }
        running = false
        if let o = configObserver { NotificationCenter.default.removeObserver(o); configObserver = nil }
        engine.inputNode.removeTap(onBus: 0)
        engine.mainMixerNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        lock.lock(); playbackEnd = 0; itemStart = nil; lock.unlock()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        print("[audio] stopped (mic chunks \(micChunks), audio chunks \(outChunks))")
    }

    private func recover() {
        guard running else { return }
        print("[audio] engine configuration changed; restarting")
        if !engine.isRunning { try? engine.start() }
        player.play()
    }

    func setSpeaker(_ on: Bool) {
        try? AVAudioSession.sharedInstance().overrideOutputAudioPort(on ? .speaker : .none)
    }

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
        let duration = Double(frames) / 24_000
        lock.lock()
        let now = CFAbsoluteTimeGetCurrent()
        let startAt = max(now, playbackEnd)
        if itemStart == nil { itemStart = startAt }
        itemScheduledSeconds += duration
        playbackEnd = startAt + duration
        lock.unlock()
        outChunks += 1
        if !player.isPlaying { player.play() }
        player.scheduleBuffer(buffer, completionHandler: nil)
    }

    /// Barge-in: drop everything queued right now.
    func stopPlayback() {
        guard running else { return }
        player.stop()
        lock.lock(); playbackEnd = 0; lock.unlock()
        player.play()
    }

    private func handleMic(_ buffer: AVAudioPCMBuffer) {
        let level = Self.rms(buffer)
        inputLevel = inputLevel * 0.6 + level * 0.4
        onLevels?(inputLevel, outputLevel)

        guard !muted, let converter else { return }
        // Simulator has no echo cancellation: don't feed the agent its own voice (plus a short tail).
        if halfDuplex {
            lock.lock(); let busy = CFAbsoluteTimeGetCurrent() < playbackEnd + 0.35; lock.unlock()
            if busy { return }
        }

        let ratio = sendFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: sendFormat, frameCapacity: capacity) else { return }
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
        guard error == nil, out.frameLength > 0, let ch = out.int16ChannelData else { return }
        let data = Data(bytes: ch[0], count: Int(out.frameLength) * 2)
        micChunks += 1
        onMicChunk?(data)
    }

    private func meterOutput(_ buffer: AVAudioPCMBuffer) {
        let level = Self.rms(buffer)
        outputLevel = outputLevel * 0.55 + level * 0.45
    }

    private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        var i = 0
        while i < n { sum += data[i] * data[i]; i += 2 }
        let rms = sqrt(sum / Float(max(n / 2, 1)))
        // Map roughly -50 dB…-5 dB to 0…1.
        let db = 20 * log10(max(rms, 0.000_01))
        return min(max((db + 50) / 45, 0), 1)
    }
}
