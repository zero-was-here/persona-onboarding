import Foundation

/// The four things onboarding has to end up with.
public enum Field: String, Codable, CaseIterable, Sendable {
    case agentName = "agent_name"
    case userName = "user_name"
    case helpNeed = "help_need"
    case gmail

    public var spoken: String {
        switch self {
        case .agentName: return "what they want to call you"
        case .userName: return "their name"
        case .helpNeed: return "the first thing they want help with"
        case .gmail: return "connecting their Gmail"
        }
    }
}

public enum Channel: String, Codable, Sendable { case text, voice }

public enum HelpCategory: String, Codable, CaseIterable, Sendable {
    case email, calendar, tasks, research, writing, travel, shopping, finance, health, other
}

public struct GmailConnection: Codable, Equatable, Sendable {
    public var email: String
    public var connectedAt: Date
    public var isSimulated: Bool
    /// From the live Gmail API after a real Google sign-in (proves the connection works).
    public var labelCount: Int?
    public var sampleLabels: [String]?
    public init(email: String, connectedAt: Date = Date(), isSimulated: Bool, labelCount: Int? = nil, sampleLabels: [String]? = nil) {
        self.email = email
        self.connectedAt = connectedAt
        self.isSimulated = isSimulated
        self.labelCount = labelCount
        self.sampleLabels = sampleLabels
    }
}

public struct OnboardingProfile: Codable, Equatable, Sendable {
    public var agentName: String?
    /// True when we picked the name ourselves because the user skipped naming.
    public var agentNameIsDefault = false
    public var userName: String?
    public var helpNeed: String?
    public var helpCategory: HelpCategory?
    public var gmail: GmailConnection?
    /// Things the user explicitly refused. We stop asking for these.
    public var declined: Set<Field> = []

    public init() {}

    public func has(_ field: Field) -> Bool {
        switch field {
        case .agentName: return agentName != nil
        case .userName: return userName != nil
        case .helpNeed: return helpNeed != nil
        case .gmail: return gmail != nil
        }
    }

    public func value(_ field: Field) -> String? {
        switch field {
        case .agentName: return agentName
        case .userName: return userName
        case .helpNeed: return helpNeed
        case .gmail: return gmail?.email
        }
    }
}

public struct Message: Identifiable, Codable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable { case user, assistant, event }
    public var id: UUID
    public var role: Role
    public var text: String
    public var channel: Channel
    public var date: Date

    public init(id: UUID = UUID(), role: Role, text: String, channel: Channel, date: Date = Date()) {
        self.id = id
        self.role = role
        self.text = text
        self.channel = channel
        self.date = date
    }
}

public enum CallStatus: String, Codable, Sendable {
    case idle, ringing, connecting, active, ended
}

public enum CallEndReason: String, Codable, Sendable {
    case completed          // agent wrapped up after collecting what it needed
    case graduated          // user skipped ahead from the call
    case switchedToText     // user asked to continue by text
    case userHungUp         // user tapped the red button
    case dropped            // network / app interruption
    case silence            // nobody said anything for too long
    case declined           // user declined the incoming call
    case missed             // nobody answered
    case micDenied          // no microphone permission
    case failed             // could not connect

    public var endedBeforeConnecting: Bool {
        switch self {
        case .declined, .missed, .micDenied, .failed: return true
        default: return false
        }
    }
}

public struct CallInfo: Codable, Equatable, Sendable {
    public var status: CallStatus = .idle
    public var attempts = 0
    public var lastEnd: CallEndReason?
    public var connectedAt: Date?
    public var lastDuration: TimeInterval = 0
    /// Last moment the call showed signs of life (for honest durations when the app was killed mid-call).
    public var lastAliveAt: Date?
    /// The user told us they don't want calls. Only call again if they ask.
    public var userPrefersText = false
    /// This call: a name the voice model wanted to save that nobody seems to have said, and when it was
    /// turned down (optional so state saved by older builds still decodes).
    public var unheardName: String?
    public var unheardNameAt: Date?
    public var unheardNameRejections: Int?
    /// Live captions of the caller's current turn (the full transcript can land after the voice model acts on it).
    public var liveCaption: String?
    public init() {}
}

public enum Phase: String, Codable, Sendable {
    case naming         // text: getting the agent a name
    case onCall         // voice: ringing / talking
    case textFollowUp   // text: finishing what the call didn't get
    case graduated      // main experience
}

/// What the text brain returns every turn (JSON structured output).
public struct TextTurn: Codable, Equatable, Sendable {
    public enum Intent: String, Codable, CaseIterable, Sendable {
        case answer, correction, question, offTopic = "off_topic", unclear, hostile
        case refuseName = "refuse_name", refuseGmail = "refuse_gmail", refuseCall = "refuse_call"
        case wantsCall = "wants_call", wantsSkip = "wants_skip", agreeGmail = "agree_gmail"
    }
    public enum Action: String, Codable, CaseIterable, Sendable {
        case none, startCall = "start_call", showGmailConnect = "show_gmail_connect", graduate
    }

    public var reply: String
    public var agentName: String?
    public var userName: String?
    public var helpNeed: String?
    public var helpCategory: HelpCategory?
    public var intent: Intent
    public var action: Action
    /// Something the user asked for that the agent promised to do once they're set up (e.g. code).
    public var rememberRequest: String?

    public init(reply: String, agentName: String? = nil, userName: String? = nil, helpNeed: String? = nil,
                helpCategory: HelpCategory? = nil, intent: Intent = .answer, action: Action = .none,
                rememberRequest: String? = nil) {
        self.reply = reply
        self.agentName = agentName
        self.userName = userName
        self.helpNeed = helpNeed
        self.helpCategory = helpCategory
        self.intent = intent
        self.action = action
        self.rememberRequest = rememberRequest
    }

    enum CodingKeys: String, CodingKey {
        case reply, intent, action
        case agentName = "agent_name", userName = "user_name", helpNeed = "help_need", helpCategory = "help_category"
        case rememberRequest = "remember_request"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reply = try c.decode(String.self, forKey: .reply)
        agentName = try c.decodeIfPresent(String.self, forKey: .agentName)
        userName = try c.decodeIfPresent(String.self, forKey: .userName)
        helpNeed = try c.decodeIfPresent(String.self, forKey: .helpNeed)
        // Be lenient: unknown categories/intents/actions degrade gracefully instead of failing the turn.
        helpCategory = (try? c.decodeIfPresent(String.self, forKey: .helpCategory)).flatMap { $0.flatMap(HelpCategory.init(rawValue:)) }
        intent = (try? c.decode(String.self, forKey: .intent)).flatMap(Intent.init(rawValue:)) ?? .answer
        action = (try? c.decode(String.self, forKey: .action)).flatMap(Action.init(rawValue:)) ?? .none
        rememberRequest = try? c.decodeIfPresent(String.self, forKey: .rememberRequest)
    }
}
