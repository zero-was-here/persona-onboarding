import SwiftUI

struct MessageRow: View {
    let message: Message

    var body: some View {
        switch message.role {
        case .assistant: assistant
        case .user: user
        case .event: event
        }
    }

    private var assistant: some View {
        HStack(alignment: .bottom, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                if message.channel == .voice {
                    Label("on the call", systemImage: "phone")
                        .font(Typo.sans(10.5, .medium))
                        .foregroundStyle(Theme.muted)
                        .labelStyle(.titleAndIcon)
                }
                Text(message.text)
                    .font(Typo.sans(16))
                    .foregroundStyle(Theme.ink.opacity(message.channel == .voice ? 0.78 : 1))
                    .lineSpacing(3)
                    .tracking(0.1)
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 11)
            .background(
                UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: 6, bottomTrailingRadius: 20, topTrailingRadius: 20, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: 6, bottomTrailingRadius: 20, topTrailingRadius: 20, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 0.5)
            )
            Spacer(minLength: 44)
        }
        .riseIn()
    }

    private var user: some View {
        HStack {
            Spacer(minLength: 44)
            Text(message.text)
                .font(Typo.sans(16))
                .foregroundStyle(Theme.canvas)
                .lineSpacing(3)
                .padding(.horizontal, 15)
                .padding(.vertical, 11)
                .background(
                    UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: 20, bottomTrailingRadius: 6, topTrailingRadius: 20, style: .continuous)
                        .fill(LinearGradient(colors: [Theme.aqua, Theme.aqua.opacity(0.82)], startPoint: .topLeading, endPoint: .bottomTrailing))
                )
                .opacity(message.channel == .voice ? 0.8 : 1)
        }
        .riseIn()
    }

    private var event: some View {
        HStack(spacing: 7) {
            Image(systemName: eventIcon).font(.system(size: 10, weight: .semibold))
            Text(message.text.uppercased())
                .font(Typo.sans(10.5, .semibold))
                .tracking(1.2)
        }
        .foregroundStyle(eventTint)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(eventTint.opacity(0.08)))
        .overlay(Capsule().strokeBorder(eventTint.opacity(0.2), lineWidth: 0.5))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .riseIn()
    }

    private var eventIcon: String {
        let t = message.text.lowercased()
        if t.contains("gmail") { return "checkmark" }
        if t.contains("missed") || t.contains("declined") { return "phone.arrow.down.left" }
        if t.contains("dropped") || t.contains("couldn't") || t.contains("microphone") { return "exclamationmark" }
        return "phone"
    }

    private var eventTint: Color {
        message.text.lowercased().contains("gmail") ? Theme.accept : Theme.muted
    }
}

struct TypingBubble: View {
    @State private var phase = false
    var body: some View {
        HStack {
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Theme.aqua.opacity(0.8))
                        .frame(width: 6, height: 6)
                        .offset(y: phase ? -3 : 3)
                        .opacity(phase ? 1 : 0.4)
                        .animation(.easeInOut(duration: 0.5).repeatForever().delay(Double(i) * 0.15), value: phase)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Capsule().fill(Color.white.opacity(0.06)))
            .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 0.5))
            Spacer()
        }
        .onAppear { phase = true }
        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottomLeading)))
    }
}

struct SuggestionRow: View {
    let suggestions: [AppModel.Suggestion]
    var onTap: (AppModel.Suggestion) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(suggestions) { s in
                    Button { onTap(s) } label: {
                        HStack(spacing: 6) {
                            if let icon = s.icon {
                                Image(systemName: icon).font(.system(size: 12, weight: .regular))
                            }
                            Text(s.title).font(Typo.sans(14, .medium))
                        }
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 14)
                        .frame(height: 36)
                        .glassCapsule()
                    }
                    .buttonStyle(PressScale())
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .padding(.horizontal, 16)
        }
        .frame(height: suggestions.isEmpty ? 0 : 44)
        .animation(Motion.spring, value: suggestions)
    }
}

struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(Motion.snappy, value: configuration.isPressed)
    }
}

struct InputBar: View {
    @Binding var draft: String
    var placeholder: String
    var focused: FocusState<Bool>.Binding
    var onSend: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("", text: $draft, prompt: Text(placeholder).foregroundStyle(Theme.faint), axis: .vertical)
                .font(Typo.sans(16))
                .foregroundStyle(Theme.ink)
                .tint(Theme.aqua)
                .lineLimit(1...4)
                .focused(focused)
                .submitLabel(.send)
                .onSubmit(onSend)
                .onChange(of: draft) { _, new in
                    // Multi-line field: the Return key sends instead of inserting a newline.
                    if new.contains("\n") {
                        draft = new.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
                        onSend()
                    }
                }
                .padding(.leading, 18)
                .padding(.vertical, 13)

            Button(action: onSend) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(canSend ? Theme.canvas : Theme.faint)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(canSend ? Theme.ice : Color.white.opacity(0.06)))
            }
            .buttonStyle(PressScale())
            .disabled(!canSend)
            .padding(6)
            .accessibilityLabel("Send")
        }
        .background(RoundedRectangle(cornerRadius: 25, style: .continuous).fill(Color.white.opacity(0.05)))
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 25, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 25, style: .continuous).strokeBorder(Theme.hairlineStrong, lineWidth: 0.5))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .animation(Motion.snappy, value: canSend)
    }

    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

struct GmailInlineCard: View {
    let agentName: String
    var onConnect: () -> Void

    var body: some View {
        DoubleBezel(radius: 28, glow: Theme.teal) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(Theme.teal.opacity(0.18))
                    Image(systemName: "envelope")
                        .font(.system(size: 18, weight: .light))
                        .foregroundStyle(Theme.aqua)
                }
                .frame(width: 46, height: 46)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Connect Gmail").font(Typo.sans(16, .semibold)).foregroundStyle(Theme.ink)
                    Text("Secure · disconnect anytime").font(Typo.sans(13)).foregroundStyle(Theme.muted)
                }
                Spacer(minLength: 8)
                Button(action: onConnect) {
                    Text("Connect")
                        .font(Typo.sans(14, .semibold))
                        .foregroundStyle(Theme.canvas)
                        .padding(.horizontal, 16)
                        .frame(height: 38)
                        .background(Capsule().fill(Theme.ice))
                }
                .buttonStyle(PressScale())
            }
            .padding(14)
        }
        .riseIn()
    }
}
