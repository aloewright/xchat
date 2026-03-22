// AuthService.swift
// xchat – Kinde PKCE / OAuth 2.0 authentication
//
// Manages the full sign-in flow:
//   1. Generates a PKCE code_verifier + code_challenge locally.
//   2. Opens ASWebAuthenticationSession (iOS / macOS) pointing at the Kinde
//      authorization endpoint.
//   3. Intercepts the https://alex.chat/callback redirect.
//   4. Posts {code, code_verifier} to the worker's /auth/callback route, which
//      holds KINDE_CLIENT_SECRET server-side and returns the token JSON.
//   5. Stores the access token in Keychain; clears it on logout.
//
// IMPORTANT: KINDE_CLIENT_SECRET is never touched by this file.
//            All token exchange happens server-side through the worker.

import AuthenticationServices
import CryptoKit
import Foundation
import Security

// MARK: - AuthState

enum AuthState: Equatable {
    case unauthenticated
    case authenticating
    case authenticated(token: String)
}

// MARK: - AuthError

enum AuthError: LocalizedError {
    case invalidURL
    case noCode
    case noCallbackURL
    case pkceGenerationFailed
    case authSessionCancelled
    case authSessionFailed(Error)
    case tokenExchangeFailed(Int)
    case decodingFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL:                    return "Invalid authentication URL."
        case .noCode:                        return "No authorization code in callback."
        case .noCallbackURL:                 return "No callback URL received."
        case .pkceGenerationFailed:          return "Failed to generate PKCE parameters."
        case .authSessionCancelled:          return "Sign-in was cancelled."
        case .authSessionFailed(let e):      return "Authentication failed: \(e.localizedDescription)"
        case .tokenExchangeFailed(let code): return "Token exchange failed (HTTP \(code))."
        case .decodingFailed:                return "Unexpected token response format."
        }
    }
}

// MARK: - AuthService

/// Manages Kinde PKCE authentication for xchat native clients.
actor AuthService {

    // ── Singleton ─────────────────────────────────────────────────────────────
    static let shared = AuthService()

    // ── Kinde / worker config ──────────────────────────────────────────────────
    // Only public values here — the client secret lives exclusively in the worker.
    private let kindeDomain   = "https://aftuh.kinde.com"
    private let kindeClientID = "e4f87148811b4f7c981ffbab3aafee59"
    private let redirectURI   = "https://alex.chat/callback"
    private let workerBase    = URL(string: "https://alex.chat")!

    // ── Mutable state ─────────────────────────────────────────────────────────
    private(set) var state: AuthState = .unauthenticated

    // MARK: Init

    init() {
        // Restore a previously stored token so the user stays signed in.
        if let saved = KeychainHelper.loadToken() {
            state = .authenticated(token: saved)
        }
    }

    // MARK: - Public API

    /// Initiates the PKCE sign-in flow.
    /// Throws `AuthError` on failure; sets `state` to `.authenticated` on success.
    func login() async throws {
        state = .authenticating

        // 1. Generate PKCE pair
        let (codeVerifier, codeChallenge) = try makePKCE()
        let stateValue = makeState()

        // 2. Build the Kinde authorization URL
        var components = URLComponents(string: "\(kindeDomain)/oauth2/auth")!
        components.queryItems = [
            URLQueryItem(name: "response_type",          value: "code"),
            URLQueryItem(name: "client_id",              value: kindeClientID),
            URLQueryItem(name: "redirect_uri",           value: redirectURI),
            URLQueryItem(name: "scope",                  value: "openid profile email"),
            URLQueryItem(name: "state",                  value: stateValue),
            URLQueryItem(name: "code_challenge",         value: codeChallenge),
            URLQueryItem(name: "code_challenge_method",  value: "S256"),
        ]
        guard let authURL = components.url else {
            state = .unauthenticated
            throw AuthError.invalidURL
        }

        // 3. Open ASWebAuthenticationSession and wait for the callback
        let callbackURL: URL
        do {
            callbackURL = try await openAuthSession(url: authURL)
        } catch let e as AuthError {
            state = .unauthenticated
            throw e
        } catch {
            state = .unauthenticated
            throw AuthError.authSessionFailed(error)
        }

        // 4. Parse the authorization code from the callback URL
        guard
            let cbComponents = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
            let code = cbComponents.queryItems?.first(where: { $0.name == "code" })?.value
        else {
            state = .unauthenticated
            throw AuthError.noCode
        }

        // 5. Exchange code via worker (keeps KINDE_CLIENT_SECRET server-side)
        let token = try await exchangeCode(code: code, codeVerifier: codeVerifier)

        // 6. Persist and surface the token
        KeychainHelper.saveToken(token)
        state = .authenticated(token: token)
    }

    /// Signs the user out: clears Keychain and redirects to Kinde logout.
    func logout() async {
        KeychainHelper.deleteToken()
        state = .unauthenticated
        // Best-effort server-side logout (fire and forget)
        if let logoutURL = URL(string: "\(kindeDomain)/logout?redirect=https://alex.chat") {
            _ = try? await URLSession.shared.data(from: logoutURL)
        }
    }

    /// Returns the current access token, or nil if unauthenticated.
    func currentToken() -> String? {
        guard case .authenticated(let token) = state else { return nil }
        return token
    }

    // MARK: - Private helpers

    // ── Auth session ─────────────────────────────────────────────────────────

    private func openAuthSession(url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            // ASWebAuthenticationSession must be created and started on the main actor.
            Task { @MainActor in
                let session = ASWebAuthenticationSession(
                    url: url,
                    callbackURLScheme: "https"
                ) { callbackURL, error in
                    if let error = error {
                        let asError = error as? ASWebAuthenticationSessionError
                        if asError?.code == .canceledLogin {
                            continuation.resume(throwing: AuthError.authSessionCancelled)
                        } else {
                            continuation.resume(throwing: AuthError.authSessionFailed(error))
                        }
                    } else if let callbackURL {
                        continuation.resume(returning: callbackURL)
                    } else {
                        continuation.resume(throwing: AuthError.noCallbackURL)
                    }
                }
                session.prefersEphemeralWebBrowserSession = false
#if !os(watchOS)
                session.presentationContextProvider = AuthPresentationContext.shared
#endif
                session.start()
            }
        }
    }

    // ── Token exchange ────────────────────────────────────────────────────────

    /// Calls the worker's /auth/callback endpoint to exchange the code.
    /// The worker holds KINDE_CLIENT_SECRET and does the actual Kinde POST.
    private func exchangeCode(code: String, codeVerifier: String) async throws -> String {
        var components = URLComponents(url: workerBase.appendingPathComponent("auth/callback"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "code",           value: code),
            URLQueryItem(name: "code_verifier",  value: codeVerifier),
        ]
        guard let url = components.url else { throw AuthError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else { throw AuthError.decodingFailed }
        guard (200...299).contains(http.statusCode) else {
            throw AuthError.tokenExchangeFailed(http.statusCode)
        }

        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        return decoded.accessToken
    }

    // ── PKCE generation ───────────────────────────────────────────────────────

    private func makePKCE() throws -> (verifier: String, challenge: String) {
        var randomBytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
        guard status == errSecSuccess else { throw AuthError.pkceGenerationFailed }

        let verifier = Data(randomBytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        let hash = SHA256.hash(data: Data(verifier.utf8))
        let challenge = Data(hash)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        return (verifier, challenge)
    }

    private func makeState() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - TokenResponse (private)

private struct TokenResponse: Decodable {
    let accessToken: String
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
    }
}

// MARK: - AuthPresentationContext

/// Supplies the window anchor required by ASWebAuthenticationSession on iOS / macOS.
#if !os(watchOS)
@MainActor
final class AuthPresentationContext: NSObject, ASWebAuthenticationPresentationContextProviding {

    static let shared = AuthPresentationContext()

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
#if os(macOS)
        // On macOS, use the key window (or a new NSWindow as fallback).
        return NSApplication.shared.keyWindow ?? NSWindow()
#else
        // On iOS, walk the connected scenes to find the key window.
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first
        return scene?.windows.first(where: { $0.isKeyWindow })
            ?? scene?.windows.first
            ?? UIWindow()
#endif
    }
}
#endif

// MARK: - KeychainHelper

enum KeychainHelper {
    private static let service = "com.xchat.auth"
    private static let account = "kinde_access_token"

    static func saveToken(_ token: String) {
        let data = Data(token.utf8)
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        // Delete any existing entry before adding the new one.
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData] = data
        SecItemAdd(item as CFDictionary, nil)
    }

    static func loadToken() -> String? {
        let query: [CFString: Any] = [
            kSecClass:            kSecClassGenericPassword,
            kSecAttrService:      service,
            kSecAttrAccount:      account,
            kSecReturnData:       true,
            kSecMatchLimit:       kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8)
        else { return nil }
        return token
    }

    static func deleteToken() {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
