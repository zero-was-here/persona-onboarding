import AVFoundation
import UIKit

/// Ringtone (with a haptic ring pattern) and small UI sounds. All sounds are generated for this app.
@MainActor
final class SoundFX {
    static let shared = SoundFX()

    private var ringPlayer: AVAudioPlayer?
    private var oneShots: [AVAudioPlayer] = []
    private var ringHaptics: Task<Void, Never>?

    func startRinging() {
        stopRinging()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        if let url = Bundle.main.url(forResource: "ringtone", withExtension: "wav"),
           let p = try? AVAudioPlayer(contentsOf: url) {
            p.numberOfLoops = -1
            p.volume = 0.8
            p.play()
            ringPlayer = p
        }
        ringHaptics = Task {
            let heavy = UIImpactFeedbackGenerator(style: .heavy)
            while !Task.isCancelled {
                heavy.impactOccurred(intensity: 0.9)
                try? await Task.sleep(for: .milliseconds(180))
                heavy.impactOccurred(intensity: 0.6)
                try? await Task.sleep(for: .milliseconds(2220))
            }
        }
    }

    func stopRinging() {
        ringHaptics?.cancel()
        ringHaptics = nil
        ringPlayer?.stop()
        ringPlayer = nil
    }

    func play(_ name: String, volume: Float = 0.7) {
        guard let url = Bundle.main.url(forResource: name, withExtension: "wav"),
              let p = try? AVAudioPlayer(contentsOf: url) else { return }
        p.volume = volume
        p.play()
        oneShots.append(p)
        oneShots.removeAll { !$0.isPlaying && $0 !== p }
    }
}
