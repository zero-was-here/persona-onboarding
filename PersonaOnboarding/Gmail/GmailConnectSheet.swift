import SwiftUI

/// Gmail connection sheet. This prototype simulates the Google consent step (clearly labeled);
/// production would use Google Sign-In with incremental `gmail.readonly` / `gmail.compose` scopes.
struct GmailConnectSheet: View {
    let agentName: String
    let helpNeed: String?
    var onConnect: (String) -> Void
    var onCancel: () -> Void

    @State private var email = ""
    @State private var stage: Stage = .form
    @State private var error: String?
    @FocusState private var focused: Bool

    enum Stage { case form, connecting, done }

    var body: some View {
        ZStack {
            Theme.canvas.ignoresSafeArea()
            RadialGradient(colors: [Theme.teal.opacity(0.22), .clear], center: .top, startRadius: 10, endRadius: 420)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    Eyebrow(text: "Secure connection")
                    Spacer()
                    Button { onCancel() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.body)
                            .frame(width: 34, height: 34)
                            .glassCircle()
                    }
                    .accessibilityLabel("Close")
                }

                ZStack {
                    Circle().fill(Theme.teal.opacity(0.16)).frame(width: 72, height: 72)
                    Circle().strokeBorder(Theme.aqua.opacity(0.35), lineWidth: 0.75).frame(width: 72, height: 72)
                    Image(systemName: stage == .done ? "checkmark" : "envelope")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(Theme.aqua)
                        .contentTransition(.symbolEffect(.replace))
                }
                .shadow(color: Theme.teal.opacity(0.5), radius: 24)

                VStack(alignment: .leading, spacing: 8) {
                    Text(stage == .done ? "Gmail connected" : "Connect your Gmail")
                        .font(Typo.serif(36))
                        .foregroundStyle(Theme.ink)
                    Text(stage == .done ? "\(agentName) can start helping right away." : subtitle)
                        .font(Typo.sans(15))
                        .foregroundStyle(Theme.body)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if stage != .done {
                    DoubleBezel(radius: 26) {
                        VStack(alignment: .leading, spacing: 14) {
                            permission("tray.full", "Read and organize your inbox")
                            permission("pencil.line", "Draft replies you approve before sending")
                            permission("hand.raised", "Disconnect anytime; nothing is sold or shared")
                        }
                        .padding(18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        TextField("", text: $email, prompt: Text("you@gmail.com").foregroundStyle(Theme.faint))
                            .font(Typo.sans(17))
                            .foregroundStyle(Theme.ink)
                            .textContentType(.emailAddress)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focused)
                            .submitLabel(.go)
                            .onSubmit(connect)
                            .padding(.horizontal, 18)
                            .frame(height: 54)
                            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white.opacity(0.05)))
                            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(error == nil ? Theme.hairlineStrong : Theme.danger.opacity(0.7), lineWidth: 0.75))
                            .disabled(stage == .connecting)
                        if let error {
                            Text(error).font(Typo.sans(13)).foregroundStyle(Theme.danger)
                        }
                    }
                }

                Spacer(minLength: 0)

                if stage != .done {
                    Button(action: connect) {
                        HStack {
                            Spacer()
                            if stage == .connecting {
                                ProgressView().tint(Theme.canvas)
                                Text("Connecting…")
                            } else {
                                IslandLabel(title: "Continue with Google", icon: "arrow.right")
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(IslandButtonStyle())
                    .disabled(stage == .connecting)

                    Text("Prototype: Google sign-in is simulated in this build.")
                        .font(Typo.sans(12))
                        .foregroundStyle(Theme.faint)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(24)
        }
        .onAppear { focused = true }
        .sensoryFeedback(.success, trigger: stage == .done)
    }

    private var subtitle: String {
        if let helpNeed { return "So \(agentName) can get started on “\(helpNeed)”." }
        return "So \(agentName) can triage, summarize and draft for you."
    }

    private func permission(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .light))
                .foregroundStyle(Theme.aqua)
                .frame(width: 22)
            Text(text).font(Typo.sans(14.5)).foregroundStyle(Theme.body)
        }
    }

    private func connect() {
        guard let normalized = Validation.normalizedEmail(email) else {
            withAnimation(Motion.snappy) { error = "That doesn't look like an email address." }
            Haptics.warning()
            return
        }
        error = nil
        focused = false
        withAnimation(Motion.spring) { stage = .connecting }
        Task {
            try? await Task.sleep(for: .milliseconds(1300))
            withAnimation(Motion.bouncy) { stage = .done }
            SoundFX.shared.play("success")
            try? await Task.sleep(for: .milliseconds(900))
            onConnect(normalized)
        }
    }
}
