import SwiftUI

struct IncomingCallView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            Theme.canvas.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 0) {
                VStack(spacing: 12) {
                    Eyebrow(text: "Persona voice call")
                    Text(model.agentName)
                        .font(Typo.serif(58))
                        .foregroundStyle(Theme.ink)
                    Text("wants to finish setting up by voice")
                        .font(Typo.sans(15))
                        .foregroundStyle(Theme.body)
                }
                .padding(.top, 56)
                .riseIn()

                Spacer()
                ZStack {
                    PulseRings(diameter: 190)
                    AgentOrb(size: 190, level: 0.25, mood: .ringing)
                }
                Spacer()

                HStack(spacing: 72) {
                    CallActionButton(icon: "phone.down.fill", title: "Decline", color: Theme.danger) { model.declineCall() }
                    CallActionButton(icon: "phone.fill", title: "Accept", color: Theme.accept, pulses: true) { model.acceptCall() }
                }
                .padding(.bottom, 22)

                Button { model.declineCall() } label: {
                    Label("Message instead", systemImage: "message")
                        .font(Typo.sans(14, .medium))
                        .foregroundStyle(Theme.body)
                        .padding(.horizontal, 16)
                        .frame(height: 38)
                        .glassCapsule()
                }
                .buttonStyle(PressScale())
                .padding(.bottom, 26)
            }
        }
    }
}

struct CallActionButton: View {
    let icon: String
    let title: String
    let color: Color
    var pulses = false
    let action: () -> Void
    @State private var bob = false

    var body: some View {
        VStack(spacing: 10) {
            Button(action: action) {
                Image(systemName: icon)
                    .font(.system(size: 28, weight: .regular))
                    .foregroundStyle(.white)
                    .frame(width: 76, height: 76)
                    .background(Circle().fill(color))
                    .shadow(color: color.opacity(0.55), radius: 22, y: 6)
                    .offset(y: pulses && bob ? -4 : 0)
            }
            .buttonStyle(PressScale())
            .accessibilityLabel(title)
            Text(title).font(Typo.sans(13, .medium)).foregroundStyle(Theme.body)
        }
        .onAppear {
            guard pulses else { return }
            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { bob = true }
        }
    }
}

struct CallView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let voice = model.voice
        ZStack {
            Theme.canvas.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                VStack(spacing: 6) {
                    Text(model.agentName)
                        .font(Typo.serif(44))
                        .foregroundStyle(Theme.ink)
                    Text(model.callStatusText)
                        .font(Typo.sans(14))
                        .foregroundStyle(voice.assistantSpeaking ? Theme.aqua : Theme.body)
                        .contentTransition(.opacity)
                        .animation(Motion.snappy, value: model.callStatusText)
                    ProgressConstellation(profile: model.state.profile)
                        .padding(.top, 10)
                }
                .padding(.top, 8)

                Spacer(minLength: 12)
                // The ring answers the user's voice; the orb swells with the agent's voice and, more gently,
                // with the user's (so it visibly listens). Mic level has a small noise floor removed.
                let userVoice = max(0, (voice.userLevel - 0.12) / 0.88)
                ZStack {
                    WaveRing(level: userVoice, diameter: 236)
                    AgentOrb(size: 236, level: max(voice.assistantLevel, userVoice * 0.7), mood: model.callOrbMood)
                }
                .frame(height: 290)
                Spacer(minLength: 8)

                Captions(assistant: voice.assistantCaption, userSpeaking: voice.userSpeaking)
                    .frame(height: 118)
                    .padding(.horizontal, 26)

                if model.state.gmailCardVisible && model.state.profile.gmail == nil {
                    GmailInlineCard(agentName: model.agentName) { model.showGmailSheet = true }
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                controls
                    .padding(.top, 16)
                    .padding(.bottom, 20)
            }
        }
        .animation(Motion.spring, value: model.state.gmailCardVisible)
    }

    private var topBar: some View {
        HStack {
            HStack(spacing: 8) {
                Circle().fill(Theme.accept).frame(width: 7, height: 7)
                    .shadow(color: Theme.accept, radius: 4)
                CallTimer(since: model.state.call.connectedAt)
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            .glassCapsule()
            Spacer()
            Button { model.showTester = true } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 15, weight: .light))
                    .foregroundStyle(Theme.body)
                    .frame(width: 40, height: 40)
                    .glassCircle()
            }
            .buttonStyle(PressScale())
            .accessibilityLabel("Tester tools")
        }
        .padding(.horizontal, 18)
        .padding(.top, 6)
    }

    private var controls: some View {
        let voice = model.voice
        return HStack(spacing: 18) {
            RoundControl(icon: voice.isMuted ? "mic.slash.fill" : "mic", label: voice.isMuted ? "Unmute" : "Mute", active: voice.isMuted) {
                voice.setMuted(!voice.isMuted)
            }
            RoundControl(icon: voice.speakerOn ? "speaker.wave.2" : "iphone", label: voice.speakerOn ? "Speaker" : "Phone", active: !voice.speakerOn) {
                voice.setSpeaker(!voice.speakerOn)
            }
            RoundControl(icon: "message", label: "Text", active: false) { model.switchToText() }
            Button { model.hangUp() } label: {
                Image(systemName: "phone.down.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.white)
                    .frame(width: 70, height: 70)
                    .background(Circle().fill(Theme.danger))
                    .shadow(color: Theme.danger.opacity(0.5), radius: 18, y: 6)
            }
            .buttonStyle(PressScale())
            .accessibilityLabel("End call")
        }
    }
}

struct RoundControl: View {
    let icon: String
    let label: String
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.light()
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 19, weight: .light))
                .foregroundStyle(active ? Theme.canvas : Theme.ink)
                .frame(width: 58, height: 58)
                .background(Circle().fill(active ? Theme.ice : .clear))
                .glassCircle()
        }
        .buttonStyle(PressScale())
        .accessibilityLabel(label)
    }
}

struct CallTimer: View {
    let since: Date?
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let s = since.map { max(0, Int(ctx.date.timeIntervalSince($0))) } ?? 0
            Text(String(format: "%d:%02d", s / 60, s % 60))
                .font(Typo.mono(13))
                .foregroundStyle(Theme.ink)
                .monospacedDigit()
        }
    }
}

/// Three tiny glyphs that light up as the call learns things. Signals progress without feeling like a form.
struct ProgressConstellation: View {
    let profile: OnboardingProfile

    var body: some View {
        HStack(spacing: 10) {
            glyph("person", filled: "person.fill", done: profile.has(.userName), declined: profile.declined.contains(.userName))
            glyph("sparkles", filled: "sparkles", done: profile.has(.helpNeed), declined: profile.declined.contains(.helpNeed))
            glyph("envelope", filled: "envelope.fill", done: profile.has(.gmail), declined: profile.declined.contains(.gmail))
        }
    }

    private func glyph(_ icon: String, filled: String, done: Bool, declined: Bool) -> some View {
        Image(systemName: done ? filled : icon)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(done ? Theme.canvas : (declined ? Theme.faint : Theme.muted))
            .frame(width: 26, height: 26)
            .background(Circle().fill(done ? Theme.aqua : Color.white.opacity(0.05)))
            .overlay(Circle().strokeBorder(done ? Color.clear : Theme.hairline, lineWidth: 0.5))
            .shadow(color: done ? Theme.aqua.opacity(0.6) : .clear, radius: 8)
            .scaleEffect(done ? 1.08 : 1)
            .animation(Motion.bouncy, value: done)
    }
}

/// The agent's words (its exact output, so always right). The user's own speech isn't echoed back:
/// speech-to-text can mishear any word, and the agent's reply already shows what it understood.
/// Never cut with "…": the text shrinks a little to fit, and if the agent says a lot, whole older
/// sentences make room for the newest ones.
struct Captions: View {
    let assistant: String
    let userSpeaking: Bool

    var body: some View {
        Text(Self.visible(assistant))
            .font(Typo.sans(18, .medium))
            .foregroundStyle(Theme.ink.opacity(userSpeaking ? 0.45 : 0.95))
            .multilineTextAlignment(.center)
            .lineLimit(5)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(Motion.snappy, value: userSpeaking)
    }

    /// The most recent whole sentences that fit in about `limit` characters.
    static func visible(_ s: String, limit: Int = 200) -> String {
        let text = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > limit else { return text }
        let tail = text.suffix(limit)
        if let boundary = tail.range(of: #"[.!?…。؟]\s+"#, options: .regularExpression) {
            return String(tail[boundary.upperBound...])
        }
        if let space = tail.firstIndex(of: " ") { return String(tail[tail.index(after: space)...]) }
        return String(tail)
    }
}
