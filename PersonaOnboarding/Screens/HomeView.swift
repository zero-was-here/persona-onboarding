import SwiftUI

/// The "main experience" users graduate into. Missing pieces are collected here, just in time.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header.padding(.top, 12)
                        FirstUpCard(profile: model.state.profile, agentName: model.agentName)
                            .riseIn(delay: 0.08)
                        HStack(alignment: .top, spacing: 12) {
                            ConnectionsCard(profile: model.state.profile) { model.showGmailSheet = true }
                            AboutYouCard(profile: model.state.profile, agentName: model.agentName)
                        }
                        .riseIn(delay: 0.16)

                        if !mainMessages.isEmpty {
                            Eyebrow(text: "Conversation", tint: Theme.muted).padding(.top, 8)
                            ForEach(mainMessages) { m in MessageRow(message: m).id(m.id) }
                        }
                        if model.isThinking { TypingBubble() }
                        if model.state.gmailCardVisible && model.state.profile.gmail == nil {
                            GmailInlineCard(agentName: model.agentName) { model.showGmailSheet = true }
                        }
                        Color.clear.frame(height: 4).id("homeBottom")
                    }
                    .padding(.horizontal, 16)
                }
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: model.state.transcript.count) { _, _ in scrollDown(proxy) }
                .onChange(of: model.isThinking) { _, _ in scrollDown(proxy) }
            }
            SuggestionRow(suggestions: model.suggestions) { model.tap($0) }
                .padding(.bottom, 8)
            InputBar(draft: $draft, placeholder: "Ask \(model.agentName) anything…", focused: $inputFocused) {
                let text = draft
                draft = ""
                model.send(text)
            }
        }
    }

    private func scrollDown(_ proxy: ScrollViewProxy) {
        withAnimation(Motion.spring) { proxy.scrollTo("homeBottom", anchor: .bottom) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            withAnimation(Motion.spring) { proxy.scrollTo("homeBottom", anchor: .bottom) }
        }
    }

    private var mainMessages: [Message] {
        guard let since = model.state.graduatedAt else { return [] }
        return model.state.transcript.filter { $0.date > since }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            AgentOrb(size: 64, mood: model.isThinking ? .thinking : .happy)
                .frame(width: 76, height: 76)
            VStack(alignment: .leading, spacing: 6) {
                Eyebrow(text: model.state.graduatedEarly ? "Ready · a few things later" : "All set")
                Text(greeting)
                    .font(Typo.serif(36))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
            }
            Spacer(minLength: 0)
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
        .riseIn()
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        let part = h < 12 ? "Good morning" : (h < 18 ? "Good afternoon" : "Good evening")
        if let n = model.state.profile.userName { return "\(part), \(n)." }
        return "\(part)."
    }
}

struct FirstUpCard: View {
    let profile: OnboardingProfile
    let agentName: String

    var body: some View {
        DoubleBezel(radius: 30, glow: Theme.teal) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Eyebrow(text: "First up")
                    Spacer()
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .light))
                        .foregroundStyle(Theme.aqua)
                }
                Text(profile.helpNeed ?? "Tell \(agentName) what to take off your plate")
                    .font(Typo.serif(28))
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(plan, id: \.self) { step in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Circle().fill(Theme.aqua.opacity(0.8)).frame(width: 5, height: 5).offset(y: -2)
                            Text(step).font(Typo.sans(14.5)).foregroundStyle(Theme.body)
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var icon: String {
        switch profile.helpCategory ?? .other {
        case .email: return "tray.full"
        case .calendar: return "calendar"
        case .tasks: return "checklist"
        case .research: return "magnifyingglass"
        case .writing: return "pencil.line"
        case .travel: return "airplane"
        case .shopping: return "bag"
        case .finance: return "creditcard"
        case .health: return "heart"
        case .other: return "sparkles"
        }
    }

    private var plan: [String] {
        switch profile.helpCategory ?? .other {
        case .email: return ["Sort your inbox by who's waiting on you", "Draft replies for your approval", "A 2-minute morning summary"]
        case .calendar: return ["Spot conflicts before they happen", "Protect focus blocks", "Prep notes before each meeting"]
        case .tasks: return ["Turn loose notes into a clean list", "Nudge you at the right moment", "Weekly review every Sunday"]
        case .research: return ["Collect sources on your topic", "Summarize what matters", "Keep a running brief"]
        case .writing: return ["Outline first drafts", "Match your tone", "Tighten and polish"]
        case .travel: return ["Compare options side by side", "Keep bookings in one place", "Reminders before you leave"]
        default: return ["Learn how you like things done", "Handle the busywork", "Check in when something needs you"]
        }
    }
}

struct ConnectionsCard: View {
    let profile: OnboardingProfile
    var onConnect: () -> Void

    var body: some View {
        DoubleBezel(radius: 26) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "envelope")
                    .font(.system(size: 17, weight: .light))
                    .foregroundStyle(profile.gmail != nil ? Theme.accept : Theme.aqua)
                Text("Gmail").font(Typo.sans(15, .semibold)).foregroundStyle(Theme.ink)
                if let g = profile.gmail {
                    Text(g.email).font(Typo.sans(12.5)).foregroundStyle(Theme.muted).lineLimit(1).minimumScaleFactor(0.7)
                } else {
                    Button(action: onConnect) {
                        Text("Connect")
                            .font(Typo.sans(13, .semibold))
                            .foregroundStyle(Theme.canvas)
                            .padding(.horizontal, 14)
                            .frame(height: 32)
                            .background(Capsule().fill(Theme.ice))
                    }
                    .buttonStyle(PressScale())
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        }
    }
}

struct AboutYouCard: View {
    let profile: OnboardingProfile
    let agentName: String

    var body: some View {
        DoubleBezel(radius: 26) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "person")
                    .font(.system(size: 17, weight: .light))
                    .foregroundStyle(Theme.aqua)
                Text(profile.userName ?? "Unknown").font(Typo.sans(15, .semibold)).foregroundStyle(Theme.ink)
                Text("with \(agentName)").font(Typo.serif(18, italic: true)).foregroundStyle(Theme.body)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        }
    }
}
