import SwiftUI
import AuthenticationServices

/// Gmail connection sheet. With a Google client ID configured it runs a real Google sign-in
/// (identity + Gmail labels, see GoogleAuth); otherwise, or if the user picks it after an error,
/// a clearly labeled demo connection.
struct GmailConnectSheet: View {
    let agentName: String
    let helpNeed: String?
    var onConnect: (String) -> Void
    var onConnectAccount: (GoogleAuth.Account) -> Void
    var onCancel: () -> Void

    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @State private var email = ""
    @State private var stage: Stage = .form
    @State private var error: String?
    @State private var useDemo = false
    @State private var connectedDetail: String?
    @FocusState private var focused: Bool

    private var realSignIn: Bool { GoogleAuth.isConfigured && !useDemo }

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
                    Text(stage == .done ? (connectedDetail.map { "Connected as \($0)." } ?? "\(agentName) can start helping right away.") : subtitle)
                        .font(Typo.sans(15))
                        .foregroundStyle(Theme.body)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if stage != .done {
                    DoubleBezel(radius: 26) {
                        VStack(alignment: .leading, spacing: 14) {
                            if realSignIn {
                                permission("person.crop.circle.badge.checkmark", "Confirm your Google account")
                                permission("envelope.badge.shield.half.filled", "Only your name and Gmail address, never your emails")
                                permission("hand.raised", "Disconnect anytime; nothing is sold or shared")
                            } else {
                                permission("tray.full", "Read and organize your inbox")
                                permission("pencil.line", "Draft replies you approve before sending")
                                permission("hand.raised", "Disconnect anytime; nothing is sold or shared")
                            }
                        }
                        .padding(18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if realSignIn {
                        if let error {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(error).font(Typo.sans(13)).foregroundStyle(Theme.danger)
                                Button("Use a demo connection instead") {
                                    withAnimation(Motion.spring) { useDemo = true; self.error = nil }
                                    focused = true
                                }
                                .font(Typo.sans(13, .semibold))
                                .foregroundStyle(Theme.aqua)
                            }
                        }
                    } else {
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
                }

                Spacer(minLength: 0)

                if stage != .done {
                    Button(action: realSignIn ? signInWithGoogle : connect) {
                        HStack {
                            Spacer()
                            if stage == .connecting {
                                ProgressView().tint(Theme.canvas)
                                Text("Connecting…")
                            } else {
                                IslandLabel(title: realSignIn ? "Continue with Google" : "Connect demo account", icon: "arrow.right")
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(IslandButtonStyle())
                    .disabled(stage == .connecting)

                    Text(realSignIn
                         ? "Real Google sign-in. This prototype only confirms your Gmail address; it can't read or send email."
                         : "Prototype: this demo connection is simulated.")
                        .multilineTextAlignment(.center)
                        .font(Typo.sans(12))
                        .foregroundStyle(Theme.faint)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(24)
        }
        .onAppear { if !realSignIn { focused = true } }
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

    private func signInWithGoogle() {
        error = nil
        withAnimation(Motion.spring) { stage = .connecting }
        Task {
            do {
                let account = try await GoogleAuth.signIn(with: webAuthenticationSession)
                connectedDetail = account.labelCount.map { "\(account.email) · \($0) labels" } ?? account.email
                withAnimation(Motion.bouncy) { stage = .done }
                SoundFX.shared.play("success")
                try? await Task.sleep(for: .milliseconds(900))
                onConnectAccount(account)
            } catch GoogleAuth.Failure.cancelled {
                withAnimation(Motion.spring) { stage = .form }
            } catch {
                withAnimation(Motion.spring) {
                    stage = .form
                    self.error = error.localizedDescription
                }
                Haptics.warning()
            }
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
