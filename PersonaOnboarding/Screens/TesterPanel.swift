import SwiftUI

/// For reviewers: see the live state and break things on purpose.
struct TesterPanel: View {
    @Environment(AppModel.self) private var model
    @State private var keyDraft = ""

    var body: some View {
        @Bindable var model = model
        ZStack {
            Theme.canvas.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Eyebrow(text: "For reviewers")
                        Text("Tester tools").font(Typo.serif(36)).foregroundStyle(Theme.ink)
                        Text("Everything the agent knows, and buttons to stress it.")
                            .font(Typo.sans(14)).foregroundStyle(Theme.body)
                    }
                    .padding(.top, 20)

                    section("Live state") {
                        row("Agent name", model.state.profile.agentName, declined: false)
                        row("Your name", model.state.profile.userName, declined: model.state.profile.declined.contains(.userName))
                        row("Help with", model.state.profile.helpNeed, declined: model.state.profile.declined.contains(.helpNeed))
                        row("Gmail", model.state.profile.gmail?.email, declined: model.state.profile.declined.contains(.gmail))
                        Divider().overlay(Theme.hairline)
                        row("Phase", model.state.phase.rawValue, declined: false)
                        row("Call", "\(model.state.call.status.rawValue) · attempts \(model.state.call.attempts)" + (model.state.call.lastEnd.map { " · last: \($0.rawValue)" } ?? ""), declined: false)
                    }

                    section("Break it") {
                        action("Drop the call (network loss)", icon: "wifi.slash", enabled: model.callVisible) { model.simulateDrop() }
                        Toggle(isOn: $model.simulateNoMic) {
                            Label("Pretend microphone is denied", systemImage: "mic.slash")
                                .font(Typo.sans(15)).foregroundStyle(Theme.ink)
                        }
                        .tint(Theme.teal)
                        action("Call me now", icon: "phone", enabled: Policy.canUserCall(model.state)) {
                            model.showTester = false
                            model.requestCall()
                        }
                        action("Skip to the app", icon: "arrow.right", enabled: model.state.phase != .graduated) {
                            model.showTester = false
                            model.skip()
                        }
                        action("Restart onboarding", icon: "arrow.counterclockwise", enabled: true, destructive: true) { model.reset() }
                    }

                    section("Autopilot caller") {
                        Text("Starts a fresh onboarding where an AI caller talks to the agent end to end through the real app: it listens, answers out loud (OpenAI TTS into the mic path), taps Gmail, and continues by text if the call ends.")
                            .font(Typo.sans(13)).foregroundStyle(Theme.muted)
                        if let p = model.autopilot.running {
                            HStack {
                                Label("Running: \(p.title)", systemImage: "waveform.circle")
                                    .font(Typo.sans(15, .medium)).foregroundStyle(Theme.aqua)
                                Spacer()
                                Button("Stop") { model.autopilot.stop() }
                                    .font(Typo.sans(14, .semibold)).foregroundStyle(Theme.danger)
                            }
                        }
                        if model.autopilot.log.count > 1 {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(Array(model.autopilot.log.suffix(16).enumerated()), id: \.offset) { _, line in
                                    Text(line).font(Typo.mono(11, .regular)).foregroundStyle(Theme.body)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        } else {
                            Text(model.autopilot.status).font(Typo.mono(11, .regular)).foregroundStyle(Theme.body)
                        }
                        ForEach(AutopilotCaller.personas) { p in
                            action(p.title, icon: "person.wave.2", enabled: model.autopilot.running == nil) {
                                model.showTester = false
                                model.autopilot.start(p)
                            }
                        }
                    }

                    if model.voice.status == .live {
                        section("Simulated caller (live call)") {
                            Text("Speaks through the same audio path as the microphone.")
                                .font(Typo.sans(13)).foregroundStyle(Theme.muted)
                            ForEach(Self.callerLines, id: \.self) { line in
                                action("“\(line)”", icon: "waveform", enabled: !model.voice.simulatingCaller) {
                                    model.voice.simulateCaller(line)
                                }
                            }
                        }
                    }

                    section("Models") {
                        row("Voice", "\(model.voice.model) · \(model.voice.voice)", declined: false)
                        row("Captions", model.voice.transcriptionModel, declined: false)
                        row("Chat", "gpt-6-luna (fallback gpt-5.4-mini)", declined: false)
                        row("API key", model.apiKey.isEmpty ? "missing" : "configured ••••\(model.apiKey.suffix(4))", declined: model.apiKey.isEmpty)
                        HStack {
                            SecureField("", text: $keyDraft, prompt: Text("Paste your own OpenAI key").foregroundStyle(Theme.faint))
                                .font(Typo.sans(14))
                                .foregroundStyle(Theme.ink)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            Button("Save") {
                                model.setAPIKey(keyDraft)
                                keyDraft = ""
                            }
                            .font(Typo.sans(14, .semibold))
                            .foregroundStyle(Theme.aqua)
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.05)))
                        Text("Voice: \(model.voice.diagnostics)")
                            .font(Typo.mono(11, .regular))
                            .foregroundStyle(Theme.muted)
                        if let err = model.voice.lastError {
                            Text("Last voice error: \(err)").font(Typo.sans(12)).foregroundStyle(Theme.warning)
                        }
                    }

                    section("Engine log") {
                        ForEach(Array(model.state.log.suffix(40).reversed().enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(Typo.mono(11, .regular))
                                .foregroundStyle(Theme.body)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(20)
            }
        }
    }

    static let callerLines = [
        "Hi! I'm Sam.",
        "Honestly I need help keeping my inbox under control.",
        "Wait, what would you do with my emails?",
        "Okay, sure, I'll connect my Gmail.",
        "Actually, call me Samuel.",
        "Can we just finish over text instead?",
    ]

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        let inner = content()
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(Typo.sans(11, .semibold))
                .tracking(1.4)
                .foregroundStyle(Theme.muted)
            DoubleBezel(radius: 24) {
                VStack(alignment: .leading, spacing: 12) { inner }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func row(_ label: String, _ value: String?, declined: Bool) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(Typo.sans(14)).foregroundStyle(Theme.muted)
            Spacer(minLength: 12)
            Text(declined ? "declined" : (value ?? "—"))
                .font(Typo.sans(14, .medium))
                .foregroundStyle(declined ? Theme.warning : (value == nil ? Theme.faint : Theme.ink))
                .multilineTextAlignment(.trailing)
        }
    }

    private func action(_ title: String, icon: String, enabled: Bool, destructive: Bool = false, perform: @escaping () -> Void) -> some View {
        Button {
            Haptics.light()
            perform()
        } label: {
            HStack {
                Label(title, systemImage: icon).font(Typo.sans(15))
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.faint)
            }
            .foregroundStyle(destructive ? Theme.danger : Theme.ink)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
    }
}
