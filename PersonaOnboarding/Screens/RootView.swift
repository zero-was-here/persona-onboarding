import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        ZStack {
            AuroraBackground(boost: model.callVisible || model.incomingCallVisible ? 1.0 : 0.6)

            Group {
                if model.state.phase == .graduated {
                    HomeView()
                        .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 1.03)), removal: .opacity))
                } else {
                    ChatScreen()
                        .transition(.opacity)
                }
            }
            .blur(radius: model.callVisible || model.incomingCallVisible ? 18 : 0)
            .allowsHitTesting(!(model.callVisible || model.incomingCallVisible))

            if model.incomingCallVisible {
                IncomingCallView()
                    .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity.combined(with: .scale(scale: 0.96))))
                    .zIndex(2)
            }

            if model.callVisible {
                CallView()
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
                    .zIndex(3)
            }
        }
        .animation(Motion.spring, value: model.incomingCallVisible)
        .animation(Motion.spring, value: model.callVisible)
        .animation(Motion.gentle, value: model.state.phase)
        .sheet(isPresented: $model.showGmailSheet, onDismiss: {}) {
            GmailConnectSheet(
                agentName: model.agentName,
                helpNeed: model.state.profile.helpNeed,
                onConnect: { model.connectGmail($0) },
                onConnectAccount: { model.connectGmail(account: $0) },
                onCancel: { model.cancelGmail() }
            )
            .presentationDetents([.large])
            .presentationCornerRadius(34)
            .interactiveDismissDisabled(false)
        }
        .sheet(isPresented: $model.showTester) {
            TesterPanel()
                .presentationDetents([.medium, .large])
                .presentationCornerRadius(34)
        }
        .preferredColorScheme(.dark)
        .onChange(of: model.showTester) { _, open in model.voice.suspendSilenceCheck = open || model.showGmailSheet }
        .onChange(of: model.showGmailSheet) { _, open in model.gmailSheetChanged(open: open) }
    }
}

struct ChatScreen: View {
    @Environment(AppModel.self) private var model
    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ChatHeader()
            ScrollViewReader { proxy in
                ScrollView {
                    // Plain VStack: onboarding transcripts are short, and LazyVStack + a bottom scroll anchor
                    // can spin in a layout loop while messages stream in behind the call screen.
                    VStack(spacing: 10) {
                        if model.state.phase == .naming {
                            NamingHero()
                                .padding(.top, 28)
                                .padding(.bottom, 18)
                        }
                        ForEach(model.visibleTranscript) { m in
                            MessageRow(message: m).id(m.id)
                        }
                        if model.showsTyping {
                            TypingBubble().id("typing")
                        }
                        if model.state.gmailCardVisible && model.state.profile.gmail == nil && !model.callVisible {
                            GmailInlineCard(agentName: model.agentName) { model.showGmailSheet = true }
                                .padding(.top, 4)
                                .id("gmail")
                        }
                        Color.clear.frame(height: 14).id("bottom")
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.interactively)
                .defaultScrollAnchor(.bottom)
                .onChange(of: model.state.transcript.count) { _, _ in scrollToBottom(proxy) }
                .onChange(of: model.showsTyping) { _, _ in scrollToBottom(proxy) }
                .onChange(of: model.introVisible) { _, _ in scrollToBottom(proxy) }
                .onChange(of: model.introStream?.index) { _, _ in scrollToBottom(proxy) }
                .onChange(of: model.state.gmailCardVisible) { _, _ in scrollToBottom(proxy) }
                .onChange(of: inputFocused) { _, _ in scrollToBottom(proxy) }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            SuggestionRow(suggestions: model.suggestions) { model.tap($0) }
                .padding(.bottom, 8)
            InputBar(draft: $draft, placeholder: model.isNamed ? "Message \(model.agentName)…" : "Name your assistant…", focused: $inputFocused) {
                let text = draft
                draft = ""
                model.send(text)
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(Motion.spring) { proxy.scrollTo("bottom", anchor: .bottom) }
        // Bubbles animate in; scroll again once their final height is known.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            withAnimation(Motion.spring) { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }
}

struct ChatHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            AgentOrb(size: 36, mood: model.chatOrbMood, palette: model.isNamed ? .brand : .unnamed)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.agentName)
                    .font(model.isNamed ? Typo.serif(24) : Typo.sans(16, .semibold))
                    .foregroundStyle(Theme.ink)
                    .contentTransition(.opacity)
                Text(model.chatStatusText)
                    .font(Typo.sans(12))
                    .foregroundStyle(model.showsTyping ? Theme.aqua : Theme.muted)
                    .contentTransition(.opacity)
            }
            Spacer()
            if Policy.canUserCall(model.state) {
                Button { model.requestCall() } label: {
                    Image(systemName: "phone")
                        .font(.system(size: 16, weight: .light))
                        .foregroundStyle(Theme.ink)
                        .frame(width: 42, height: 42)
                        .glassCircle()
                }
                .buttonStyle(PressScale())
                .accessibilityLabel("Call \(model.agentName)")
                .transition(.scale.combined(with: .opacity))
            }
            Button { model.showTester = true } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 15, weight: .light))
                    .foregroundStyle(Theme.body)
                    .frame(width: 42, height: 42)
                    .glassCircle()
            }
            .buttonStyle(PressScale())
            .accessibilityLabel("Tester tools")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .animation(Motion.spring, value: model.isNamed)
    }
}

struct NamingHero: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 18) {
            AgentOrb(size: 132, mood: model.showsTyping ? .thinking : .idle, palette: .unnamed)
                .frame(height: 150)
            Eyebrow(text: "Meet your assistant")
            Text("Let's get you two\nacquainted.")
                .font(Typo.serif(38))
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.ink)
                .lineSpacing(-2)
        }
        .frame(maxWidth: .infinity)
        .riseIn()
    }
}
