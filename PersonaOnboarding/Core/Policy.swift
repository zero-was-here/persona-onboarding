import Foundation

/// Deterministic rules. The LLM decides *how* to say things; the policy decides *what is allowed*
/// (when to call, when the user may graduate, what's still missing). This is what keeps the bot
/// from looping, forgetting, or trapping a user who doesn't play along.
public enum Policy {
    /// Fields collected on the call. The agent name is always collected by text first.
    public static let voiceFields: [Field] = [.userName, .helpNeed, .gmail]
    public static let order: [Field] = [.agentName, .userName, .helpNeed, .gmail]
    public static let defaultAgentName = "Nova"

    public static func stillNeeded(_ p: OnboardingProfile) -> [Field] {
        order.filter { !p.has($0) && !p.declined.contains($0) }
    }

    public static func isComplete(_ p: OnboardingProfile) -> Bool { stillNeeded(p).isEmpty }

    /// Early graduation: the user knows what they want (help need) — let them in, collect the rest later.
    public static func canGraduate(_ s: OnboardingState) -> Bool {
        isComplete(s.profile) || (s.profile.agentName != nil && s.profile.helpNeed != nil)
    }

    public static func callIsFree(_ s: OnboardingState) -> Bool {
        s.call.status == .idle || s.call.status == .ended
    }

    /// We ring automatically exactly once, right after the agent gets its name.
    public static func canAutoCall(_ s: OnboardingState) -> Bool {
        s.phase != .graduated
            && s.profile.agentName != nil
            && s.call.attempts == 0
            && !s.call.userPrefersText
            && callIsFree(s)
            // Worth a call only if something conversational is missing (Gmail alone is just a button).
            && (!s.profile.has(.userName) && !s.profile.declined.contains(.userName)
                || !s.profile.has(.helpNeed) && !s.profile.declined.contains(.helpNeed))
    }

    /// The user can always ask for a call (after we have a name to call as).
    public static func canUserCall(_ s: OnboardingState) -> Bool {
        s.phase != .graduated && s.profile.agentName != nil && callIsFree(s)
    }

    public static func nextFocus(_ s: OnboardingState) -> Field? {
        stillNeeded(s.profile).first
    }

    /// One-line instruction for the text brain about what to do on this turn.
    /// Written to stay correct even when the user's latest message already answers the current question.
    public static func textDirective(_ s: OnboardingState) -> String {
        let p = s.profile
        let still = stillNeeded(p)
        let queue = still.map(\.rawValue).joined(separator: " → ")
        let skipAware = "Ask only for the FIRST item in this order that their latest message did not just give you: \(queue.isEmpty ? "nothing" : queue). Exception: if their latest message asks to skip ahead or just start and you now know what they need help with, ask nothing: give a warm one-line send-off with intent=wants_skip and action=graduate."

        if s.skipRequests >= 1 {
            if p.helpNeed != nil || s.skipRequests >= 2 {
                return "They want to skip ahead and you know enough. Don't ask anything else: give a short, warm send-off (you'll learn the rest as you go) and set action=graduate."
            }
            return "They want to skip ahead. Ask only one thing, in one friendly line: what's the first thing they'd like help with (help_need). If they refuse again, give a short send-off and set action=graduate."
        }
        if p.agentName == nil {
            if s.namingDeflections >= 2 {
                return "They still haven't picked a name for you. Pick a short, friendly one yourself, set agent_name to it, and say they can rename you anytime."
            }
            let callNext = s.call.attempts == 0 && !s.call.userPrefersText
            return "Get a name for yourself (agent_name). If they seem unsure, offer two or three short name ideas. If their message also gives other info, keep it."
                + (callNext ? " If their latest message names YOU (a name for yourself, not their own \"I'm X\"): react warmly in a few words, then say you'll ring them for a quick call to set up the rest (faster than typing; they can decline to keep texting). Don't ask anything else. Set action=start_call." : "")
        }
        if canAutoCall(s) {
            return "You now have a name. React to it warmly in a few words, then say you'll ring them for a quick call to set up the rest (faster than typing) and that they can just decline if they'd rather keep texting. Set action=start_call."
        }
        guard let next = still.first else {
            return "Everything is collected. Give a short, genuinely excited wrap-up (one sentence) and set action=graduate."
        }
        switch next {
        case .agentName:
            return "Get a name for yourself."
        case .userName:
            return "\(skipAware) For user_name: ask what you should call them."
        case .helpNeed:
            return "\(skipAware) For help_need: ask the first thing they'd love help with; when they answer, reflect it back with one concrete example of how you'll help (no follow-up questions about it)."
        case .gmail:
            if s.gmailCardVisible {
                return "Only Gmail is left and the Connect Gmail button is already on screen. Answer any questions (use PRIVACY FACTS); otherwise nudge them lightly to tap it, without repeating your last nudge. If they refuse, accept it (intent=refuse_gmail)."
            }
            return "Only Gmail is left. Ask (don't command) if they'd like to connect it with the secure button (set action=show_gmail_connect), saying in a few words what it unlocks for their goal. If they refuse, accept it (intent=refuse_gmail)."
        }
    }

    /// Guidance returned to the voice model inside every tool result.
    public static func voiceNextStep(_ s: OnboardingState) -> String {
        let skipNote = s.profile.helpNeed != nil ? " (If they asked to skip ahead, ignore this: call finish_call with reason \"graduate\".)" : ""
        return voiceNextStepCore(s) + skipNote
    }

    private static func voiceNextStepCore(_ s: OnboardingState) -> String {
        guard let next = nextFocus(s) else {
            return "Everything is collected. Call finish_call with reason \"complete\" now (you'll say goodbye right after)."
        }
        switch next {
        case .agentName: return "Ask what they'd like to call you, then call rename_agent."
        case .userName: return "Ask what you should call them."
        case .helpNeed: return "Ask plainly what's the first thing they'd love help with (no examples yet); when they answer, give one concrete example of how you'll help."
        case .gmail:
            return s.gmailCardVisible
                ? "The Connect Gmail button is on their screen. Wait for them to tap it without repeating yourself; you'll get a system message when it's connected. If they say it's done but no message came, ask them to tap it once more. If they refuse, call mark_declined."
                : "Ask them to connect Gmail: call show_gmail_connect so a button appears on their screen."
        }
    }
}
