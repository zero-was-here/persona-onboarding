import AVFoundation

/// Full-duplex audio for the call: mic → 24 kHz PCM16 chunks, model audio → speaker.
/// Uses Apple's voice-processing I/O so the agent doesn't hear (and interrupt) itself.
final class AudioIO {
    var onMicChunk: ((Data) -> Void)?
    var onLevels: ((_ input: Float, _ output: Float) -> Void)?

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var converter: AVAudioConverter?
    private let playFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!
    private let sendFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true)!
    private let lock = NSLock()
    private var pending = 0
    private var playedFrames: Int64 = 0
    private var inputLevel: Float = 0
    private var outputLevel: Float = 0
    private var running = false

    var muted = false

    /// True while model audio is still queued or playing.
    var isPlaying: Bool {
        lock.lock(); defer { lock.unlock() }
        return pending > 0
    }

    /// Milliseconds of assistant audio actually played for the current item (for truncation on barge-in).
    var playedMilliseconds: Int {
        lock.lock(); defer { lock.unlock() }
        return Int(Double(playedFrames) / 24.0)
    }

    func resetPlayedCounter() {
        lock.lock(); playedFrames = 0; lock.unlock()
    }

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
        try? session.setPreferredIOBufferDuration(0.02)
        try session.setActive(true)

        let input = engine.inputNode
        do {
            try input.setVoiceProcessingEnabled(true)
        } catch {
            print("[audio] voice processing unavailable: \(error)")
        }

        let inFormat = input.outputFormat(forBus: 0)
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
    }

    func stop() {
        guard running else { return }
        running = false
        engine.inputNode.removeTap(onBus: 0)
        engine.mainMixerNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        lock.lock(); pending = 0; lock.unlock()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
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
        lock.lock(); pending += 1; lock.unlock()
        player.scheduleBuffer(buffer) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.pending = max(0, self.pending - 1)
            self.playedFrames += Int64(frames)
            self.lock.unlock()
        }
    }

    /// Barge-in: drop everything queued right now.
    func stopPlayback() {
        guard running else { return }
        player.stop()
        lock.lock(); pending = 0; lock.unlock()
        player.play()
    }

    private func handleMic(_ buffer: AVAudioPCMBuffer) {
        let level = Self.rms(buffer)
        inputLevel = inputLevel * 0.6 + level * 0.4
        onLevels?(inputLevel, outputLevel)

        guard !muted, let converter else { return }
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
