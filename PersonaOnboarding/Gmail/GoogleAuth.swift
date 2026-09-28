import Foundation
import AuthenticationServices
import CryptoKit
import SwiftUI

/// Real "Sign in with Google" for the Gmail step: OAuth 2.0 authorization code flow with PKCE for native
/// apps, no SDK. Scopes are basic identity plus `gmail.labels`, which Google classes as non-sensitive, so
/// any Google account can connect without Google's app verification. Reading messages needs restricted
/// scopes (`gmail.readonly` and up), which require Google's security review: that's the production path.
enum GoogleAuth {
    /// The iOS OAuth client ID (public, not a secret). Empty = fall back to the simulated connection.
    static let defaultClientID = ""

    struct Account: Equatable {
        var email: String
        var name: String?
        var labelCount: Int?
        var userLabels: [String]
    }

    enum Failure: LocalizedError, Equatable {
        case notConfigured, cancelled, denied(String), network(String)
        var errorDescription: String? {
            switch self {
            case .notConfigured: return "Google sign-in isn't set up in this build."
            case .cancelled: return "Sign-in was cancelled."
            case .denied(let why): return "Google didn't complete the connection (\(why))."
            case .network(let why): return "Couldn't reach Google (\(why))."
            }
        }
    }

    static let scopes = ["openid", "email", "profile", "https://www.googleapis.com/auth/gmail.labels"]

    static var clientID: String { AppSecrets.googleClientID }
    static var isConfigured: Bool { clientID.hasSuffix(".apps.googleusercontent.com") }
    /// Google's iOS clients redirect to the reversed client ID scheme.
    static var redirectScheme: String { clientID.split(separator: ".").reversed().joined(separator: ".") }
    static var redirectURI: String { "\(redirectScheme):/oauth2redirect" }

    @MainActor
    static func signIn(with session: WebAuthenticationSession) async throws -> Account {
        guard isConfigured else { throw Failure.notConfigured }
        let verifier = randomString(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
        let state = randomString(24)

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "prompt", value: "select_account"),
        ]

        let callback: URL
        do {
            callback = try await session.authenticate(using: components.url!, callbackURLScheme: redirectScheme)
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            throw Failure.cancelled
        } catch {
            throw Failure.network(error.localizedDescription)
        }

        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first(where: { $0.name == name })?.value }
        if let error = value("error") { throw error == "access_denied" ? Failure.cancelled : Failure.denied(error) }
        guard value("state") == state, let code = value("code") else { throw Failure.denied("unexpected response") }

        let tokens = try await exchange(code: code, verifier: verifier)
        let profile = decodeIDToken(tokens.idToken)
        guard let email = profile.email else { throw Failure.denied("no email address returned") }
        let labels = await fetchLabels(accessToken: tokens.accessToken)
        return Account(email: email.lowercased(), name: profile.name, labelCount: labels?.count, userLabels: labels?.user ?? [])
    }

    // MARK: - Steps

    private struct Tokens { let accessToken: String; let idToken: String }

    private static func exchange(code: String, verifier: String) async throws -> Tokens {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let form = [
            "code": code, "client_id": clientID, "code_verifier": verifier,
            "grant_type": "authorization_code", "redirect_uri": redirectURI,
        ]
        request.httpBody = form.map { "\($0.key)=\(formEncode($0.value))" }.joined(separator: "&").data(using: .utf8)
        let data: Data, response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: request) } catch { throw Failure.network(error.localizedDescription) }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let access = body["access_token"] as? String, let id = body["id_token"] as? String else {
            throw Failure.denied((body["error_description"] as? String) ?? (body["error"] as? String) ?? "token exchange failed")
        }
        return Tokens(accessToken: access, idToken: id)
    }

    /// The ID token is a JWT from Google over TLS; we only read the email and first name from it.
    private static func decodeIDToken(_ jwt: String) -> (email: String?, name: String?) {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return (nil, nil) }
        var base64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64),
              let claims = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return (nil, nil) }
        return (claims["email"] as? String, (claims["given_name"] as? String) ?? (claims["name"] as? String))
    }

    /// Proof the connection is live: the user's Gmail labels (names only, never messages).
    private static func fetchLabels(accessToken: String) async -> (count: Int, user: [String])? {
        var request = URLRequest(url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/labels")!)
        request.timeoutInterval = 15
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let labels = body["labels"] as? [[String: Any]] else { return nil }
        let user = labels
            .filter { $0["type"] as? String == "user" }
            .compactMap { $0["name"] as? String }
            .filter { !$0.contains("/") }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return (labels.count, Array(user.prefix(12)))
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func randomString(_ length: Int) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in alphabet.randomElement(using: &generator)! })
    }
}

private extension Data {
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
