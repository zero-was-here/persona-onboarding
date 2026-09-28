import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct BrainConfig: Sendable {
    public var apiKey: String
    public var model: String
    public var fallbackModel: String
    public var timeout: TimeInterval
    public var baseURL: URL

    public init(apiKey: String, model: String = "gpt-6-luna", fallbackModel: String = "gpt-5.4-mini",
                timeout: TimeInterval = 20, baseURL: URL = URL(string: "https://api.openai.com/v1")!) {
        self.apiKey = apiKey
        self.model = model
        self.fallbackModel = fallbackModel
        self.timeout = timeout
        self.baseURL = baseURL
    }
}

public enum BrainError: Error, CustomStringConvertible {
    case missingKey, http(Int, String), badResponse(String), transport(String)
    public var description: String {
        switch self {
        case .missingKey: return "No OpenAI API key configured"
        case .http(let code, let body): return "HTTP \(code): \(body.prefix(300))"
        case .badResponse(let s): return "Bad response: \(s.prefix(300))"
        case .transport(let s): return "Network: \(s)"
        }
    }
}

/// One text turn = one structured-output call. The model returns the reply *and* the extracted
/// fields/intent/action in a single JSON object, so there's no second round-trip for tool calls.
public final class TextBrain: @unchecked Sendable {
    public let config: BrainConfig
    private let session: URLSession

    public init(config: BrainConfig) {
        self.config = config
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = config.timeout
        c.timeoutIntervalForResource = config.timeout + 10
        self.session = URLSession(configuration: c)
    }

    /// Builds the chat history the model sees: last N messages across both channels.
    public static func history(_ s: OnboardingState, limit: Int = 24) -> [[String: String]] {
        s.transcript.suffix(limit).compactMap { m in
            switch m.role {
            case .user: return ["role": "user", "content": m.channel == .voice ? "(on the call) \(m.text)" : m.text]
            case .assistant: return ["role": "assistant", "content": m.channel == .voice ? "(on the call) \(m.text)" : m.text]
            case .event: return ["role": "system", "content": "[app event] \(m.text)"]
            }
        }
    }

    public func nextTurn(state: OnboardingState, note: String?) async throws -> TextTurn {
        guard !config.apiKey.isEmpty else { throw BrainError.missingKey }
        let system = state.phase == .graduated ? BrainPrompts.mainSystemPrompt(state) : BrainPrompts.textSystemPrompt(state)
        var messages: [[String: String]] = [["role": "system", "content": system]]
        messages += Self.history(state)
        if let note { messages.append(["role": "system", "content": "[app event] \(note)"]) }
        do {
            return try await complete(model: config.model, messages: messages)
        } catch {
            // One retry on a smaller, very reliable model keeps the conversation alive on hiccups.
            return try await complete(model: config.fallbackModel, messages: messages)
        }
    }

    private func complete(model: String, messages: [[String: String]]) async throws -> TextTurn {
        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            "reasoning_effort": "none",
            "response_format": [
                "type": "json_schema",
                "json_schema": ["name": "onboarding_turn", "strict": true, "schema": BrainPrompts.textSchema],
            ],
        ]
        var req = URLRequest(url: config.baseURL.appendingPathComponent("chat/completions"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await send(req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw BrainError.http(code, String(decoding: data, as: UTF8.self)) }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw BrainError.badResponse(String(decoding: data, as: UTF8.self))
        }
        do {
            return try JSONDecoder().decode(TextTurn.self, from: Data(content.utf8))
        } catch {
            throw BrainError.badResponse(content)
        }
    }

    /// Completion-handler based so it behaves the same on Apple platforms and Linux.
    private func send(_ req: URLRequest) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { cont in
            let task = session.dataTask(with: req) { data, response, error in
                if let error { cont.resume(throwing: BrainError.transport(error.localizedDescription)); return }
                guard let data, let response else { cont.resume(throwing: BrainError.transport("empty response")); return }
                cont.resume(returning: (data, response))
            }
            task.resume()
        }
    }
}
