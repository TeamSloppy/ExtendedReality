import AuthenticationServices
import CryptoKit
import Observation
import UIKit

@MainActor
@Observable
final class YouTubeAuthSession: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let readOnlyScope = "https://www.googleapis.com/auth/youtube.readonly"

    private(set) var isRestoring = false
    private(set) var isAuthorizing = false
    private(set) var isSignedIn = false
    private(set) var displayName: String?
    private(set) var email: String?
    private(set) var avatarURL: URL?
    private(set) var errorMessage: String?

    @ObservationIgnored private let keychain: KeychainStore
    @ObservationIgnored private let urlSession: URLSession
    @ObservationIgnored private var credential: OAuthCredential?
    @ObservationIgnored private var webAuthenticationSession: ASWebAuthenticationSession?
    @ObservationIgnored private var restoreTask: Task<Void, Never>?

    private static let credentialAccount = "youtube.googleOAuth"

    init(
        keychain: KeychainStore = KeychainStore(service: "com.vladprusakov.ExtendReality"),
        urlSession: URLSession = .shared,
        restoresPreviousSignIn: Bool = true
    ) {
        self.keychain = keychain
        self.urlSession = urlSession
        super.init()
        guard restoresPreviousSignIn else { return }
        restoreTask = Task { [weak self] in
            await self?.restorePreviousSignIn()
        }
    }

    var isOAuthConfigured: Bool {
        guard let clientID = configuredClientID,
              let callbackScheme = configuredCallbackScheme else { return false }
        return clientID.hasSuffix(".apps.googleusercontent.com")
            && callbackScheme.hasPrefix("com.googleusercontent.apps.")
            && !clientID.localizedCaseInsensitiveContains("CONFIGURE_")
            && !callbackScheme.localizedCaseInsensitiveContains("CONFIGURE_")
    }

    var accountLabel: String {
        displayName ?? email ?? "Google account"
    }

    func restorePreviousSignIn() async {
        guard !isRestoring, !isSignedIn, isOAuthConfigured else { return }
        isRestoring = true
        defer { isRestoring = false }
        guard let data = keychain.data(for: Self.credentialAccount),
              let stored = try? JSONDecoder().decode(OAuthCredential.self, from: data),
              !stored.refreshToken.isEmpty else {
            clearAccount()
            return
        }
        credential = stored
        applyProfile(from: stored)
        isSignedIn = true
        do {
            _ = try await accessToken()
        } catch {
            signOut()
        }
    }

    func signIn() async {
        _ = await authorize(selectsAccount: false)
    }

    @discardableResult
    func switchAccount() async -> Bool {
        await authorize(selectsAccount: true)
    }

    @discardableResult
    private func authorize(selectsAccount: Bool) async -> Bool {
        guard !isAuthorizing else { return false }
        guard isOAuthConfigured else {
            errorMessage = YouTubeAuthError.missingClientID.localizedDescription
            return false
        }

        isAuthorizing = true
        errorMessage = nil
        defer { isAuthorizing = false }
        do {
            let verifier = Self.randomURLSafeString()
            let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString
            let state = Self.randomURLSafeString()
            let authorizationURL = try makeAuthorizationURL(
                codeChallenge: challenge,
                state: state,
                selectsAccount: selectsAccount
            )
            let callbackURL = try await authenticate(at: authorizationURL)
            let callback = try parseCallback(callbackURL, expectedState: state)
            let token = try await exchangeCode(callback.code, verifier: verifier)
            var nextCredential = OAuthCredential(
                accessToken: token.accessToken,
                refreshToken: token.refreshToken ?? "",
                expirationDate: Date().addingTimeInterval(TimeInterval(token.expiresIn)),
                displayName: nil,
                email: nil,
                avatarURL: nil
            )
            if let profile = try? await loadProfile(accessToken: token.accessToken) {
                nextCredential.displayName = profile.name
                nextCredential.email = profile.email
                nextCredential.avatarURL = profile.picture
            }
            guard !nextCredential.refreshToken.isEmpty else {
                throw YouTubeAuthError.missingRefreshToken
            }
            try persist(nextCredential)
            credential = nextCredential
            applyProfile(from: nextCredential)
            isSignedIn = true
            return true
        } catch {
            if Self.isCancellation(error) { return false }
            errorMessage = error.localizedDescription
            return false
        }
    }

    func accessToken() async throws -> String {
        guard isOAuthConfigured else { throw YouTubeAuthError.missingClientID }
        guard var credential else { throw YouTubeAuthError.authorizationRequired }
        if credential.expirationDate.timeIntervalSinceNow > 60, !credential.accessToken.isEmpty {
            return credential.accessToken
        }

        let token: OAuthTokenResponse
        do {
            token = try await refresh(refreshToken: credential.refreshToken)
        } catch YouTubeAuthError.authorizationRequired {
            signOut()
            throw YouTubeAuthError.authorizationRequired
        }
        credential.accessToken = token.accessToken
        credential.expirationDate = Date().addingTimeInterval(TimeInterval(token.expiresIn))
        if let replacement = token.refreshToken, !replacement.isEmpty {
            credential.refreshToken = replacement
        }
        try persist(credential)
        self.credential = credential
        isSignedIn = true
        return credential.accessToken
    }

    func signOut() {
        webAuthenticationSession?.cancel()
        webAuthenticationSession = nil
        keychain.delete(account: Self.credentialAccount)
        credential = nil
        clearAccount()
        errorMessage = nil
    }

    func clearError() {
        errorMessage = nil
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.keyWindow ?? ASPresentationAnchor()
    }

    private var configuredClientID: String? {
        Self.configurationValue(for: "YouTubeOAuthClientID")
    }

    private var configuredCallbackScheme: String? {
        Self.configurationValue(for: "YouTubeOAuthCallbackScheme")
    }

    private var redirectURI: String? {
        configuredCallbackScheme.map { "\($0):/oauthredirect" }
    }

    private func makeAuthorizationURL(
        codeChallenge: String,
        state: String,
        selectsAccount: Bool
    ) throws -> URL {
        guard let configuredClientID, let redirectURI else { throw YouTubeAuthError.missingClientID }
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: configuredClientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "openid email profile \(Self.readOnlyScope)"),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: selectsAccount ? "select_account consent" : "consent"),
        ]
        guard let url = components.url else { throw YouTubeAuthError.invalidAuthorizationResponse }
        return url
    }

    private func authenticate(at url: URL) async throws -> URL {
        guard let callbackScheme = configuredCallbackScheme else { throw YouTubeAuthError.missingClientID }
        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { [weak self] url, error in
                Task { @MainActor in
                    self?.webAuthenticationSession = nil
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let url {
                        continuation.resume(returning: url)
                    } else {
                        continuation.resume(throwing: YouTubeAuthError.invalidAuthorizationResponse)
                    }
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            webAuthenticationSession = session
            guard session.start() else {
                webAuthenticationSession = nil
                continuation.resume(throwing: YouTubeAuthError.missingPresenter)
                return
            }
        }
    }

    private func parseCallback(_ url: URL, expectedState: String) throws -> (code: String, state: String) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let oauthError = items.first(where: { $0.name == "error" })?.value {
            throw YouTubeAuthError.providerError(oauthError)
        }
        guard let state = items.first(where: { $0.name == "state" })?.value,
              state == expectedState,
              let code = items.first(where: { $0.name == "code" })?.value,
              !code.isEmpty else {
            throw YouTubeAuthError.invalidAuthorizationResponse
        }
        return (code, state)
    }

    private func exchangeCode(_ code: String, verifier: String) async throws -> OAuthTokenResponse {
        guard let configuredClientID, let redirectURI else { throw YouTubeAuthError.missingClientID }
        return try await tokenRequest([
            URLQueryItem(name: "client_id", value: configuredClientID),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "code_verifier", value: verifier),
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
        ])
    }

    private func refresh(refreshToken: String) async throws -> OAuthTokenResponse {
        guard let configuredClientID, !refreshToken.isEmpty else {
            throw YouTubeAuthError.authorizationRequired
        }
        return try await tokenRequest([
            URLQueryItem(name: "client_id", value: configuredClientID),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "grant_type", value: "refresh_token"),
        ])
    }

    private func tokenRequest(_ formItems: [URLQueryItem]) async throws -> OAuthTokenResponse {
        var bodyComponents = URLComponents()
        bodyComponents.queryItems = formItems
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyComponents.percentEncodedQuery?.data(using: .utf8)
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw YouTubeAuthError.tokenExchangeFailed("Google did not return an HTTP response.")
        }
        guard 200 ..< 300 ~= http.statusCode else {
            let payload = try? JSONDecoder().decode(OAuthErrorResponse.self, from: data)
            if payload?.error == "invalid_grant" { throw YouTubeAuthError.authorizationRequired }
            throw YouTubeAuthError.tokenExchangeFailed(
                payload?.errorDescription ?? payload?.error ?? "Google OAuth failed (HTTP \(http.statusCode))."
            )
        }
        return try JSONDecoder().decode(OAuthTokenResponse.self, from: data)
    }

    private func loadProfile(accessToken: String) async throws -> OAuthProfile {
        var request = URLRequest(url: URL(string: "https://openidconnect.googleapis.com/v1/userinfo")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, 200 ..< 300 ~= http.statusCode else {
            throw YouTubeAuthError.profileRequestFailed
        }
        return try JSONDecoder().decode(OAuthProfile.self, from: data)
    }

    private func persist(_ credential: OAuthCredential) throws {
        try keychain.set(try JSONEncoder().encode(credential), for: Self.credentialAccount)
    }

    private func applyProfile(from credential: OAuthCredential) {
        displayName = credential.displayName
        email = credential.email
        avatarURL = credential.avatarURL
    }

    private func clearAccount() {
        displayName = nil
        email = nil
        avatarURL = nil
        isSignedIn = false
    }

    private static func configurationValue(for key: String) -> String? {
        let value = Bundle.main.object(forInfoDictionaryKey: key) as? String
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty || trimmed.contains("$(") ? nil : trimmed
    }

    private static func randomURLSafeString() -> String {
        Data((0 ..< 32).map { _ in UInt8.random(in: .min ... .max) }).base64URLEncodedString
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let nsError = error as NSError
        return nsError.domain == ASWebAuthenticationSessionError.errorDomain
            && nsError.code == ASWebAuthenticationSessionError.canceledLogin.rawValue
    }
}

enum YouTubeAuthError: LocalizedError {
    case missingClientID
    case missingPresenter
    case authorizationRequired
    case invalidAuthorizationResponse
    case missingRefreshToken
    case providerError(String)
    case tokenExchangeFailed(String)
    case profileRequestFailed

    var errorDescription: String? {
        switch self {
        case .missingClientID:
            "Configure the Google iOS OAuth client ID and reversed URL scheme."
        case .missingPresenter:
            "Google authorization cannot be presented right now."
        case .authorizationRequired:
            "Sign in with Google to use YouTube."
        case .invalidAuthorizationResponse:
            "Google returned an invalid authorization response."
        case .missingRefreshToken:
            "Google did not return a refresh token. Revoke the app grant and try again."
        case .providerError(let value):
            "Google authorization failed: \(value)."
        case .tokenExchangeFailed(let message):
            message
        case .profileRequestFailed:
            "The Google profile could not be loaded."
        }
    }
}

private struct OAuthCredential: Codable {
    var accessToken: String
    var refreshToken: String
    var expirationDate: Date
    var displayName: String?
    var email: String?
    var avatarURL: URL?
}

private struct OAuthTokenResponse: Decodable {
    let accessToken: String
    let expiresIn: Int
    let refreshToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
    }
}

private struct OAuthErrorResponse: Decodable {
    let error: String?
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
}

private struct OAuthProfile: Decodable {
    let name: String?
    let email: String?
    let picture: URL?
}

private extension Data {
    var base64URLEncodedString: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private extension UIApplication {
    var keyWindow: UIWindow? {
        connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
    }
}
