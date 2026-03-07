import Foundation
import SwiftUI
import os.log
import AuthenticationServices

/// Manages user authentication state and API communication
@MainActor
class AuthenticationService: ObservableObject {

    private let logger = Logger(subsystem: "com.audioenv.app", category: "Auth")

    @Published var isAuthenticated = false
    @Published var currentUser: User?
    @Published var authToken: String?
    @Published var isLoading = false
    @Published var errorMessage: String?

    /// Continuation for Google OAuth callback from default browser
    private var googleOAuthContinuation: CheckedContinuation<URL, Error>?

    private let baseURL: String = {
        if let override = UserDefaults.standard.string(forKey: "apiBaseURL"), !override.isEmpty {
            return override
        }
        return "https://api.audioenv.com"
    }()
    private let keychainService = "com.audioenv.app"

    /// In-memory cache for auth keychain items so we only prompt once per launch.
    private var keychainCache: [String: String] = [:]
    private var keychainCacheLoaded = false

    /// Tracks when the current access token was obtained, for proactive refresh.
    private var tokenObtainedAt: Date?

    /// How long the access token is valid (seconds), as reported by the server.
    private var tokenExpiresIn: TimeInterval = 1800  // default 30 min

    /// Refresh buffer: attempt refresh this many seconds before actual expiry.
    private let refreshBuffer: TimeInterval = 300  // 5 minutes

    /// Prevents concurrent refresh attempts.
    private var isRefreshing = false

    // MARK: - Models

    struct User: Codable {
        let id: String
        let email: String
        let username: String
        let subscriptionTier: String
        let storageUsedBytes: Int

        enum CodingKeys: String, CodingKey {
            case id, email, username
            case subscriptionTier = "subscription_tier"
            case storageUsedBytes = "storage_used_bytes"
        }
    }

    struct LoginRequest: Codable {
        let email: String
        let password: String
    }

    struct RegisterRequest: Codable {
        let email: String
        let username: String
        let password: String
    }

    struct OAuthRequest: Codable {
        let provider: String
        let idToken: String
        let fullName: String?

        enum CodingKeys: String, CodingKey {
            case provider
            case idToken = "id_token"
            case fullName = "full_name"
        }
    }

    struct AuthResponse: Codable {
        let accessToken: String
        let refreshToken: String?
        let tokenType: String
        let expiresIn: Int

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case tokenType = "token_type"
            case expiresIn = "expires_in"
        }
    }

    // MARK: - File-based Token Storage (primary, survives ad-hoc re-signing)

    private static let tokenStorageURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("AudioEnv", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static let accessTokenFile = tokenStorageURL.appendingPathComponent(".auth_token")
    private static let refreshTokenFile = tokenStorageURL.appendingPathComponent(".refresh_token")

    private func loadTokenFromFile() -> String? {
        try? String(contentsOf: Self.accessTokenFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func loadRefreshTokenFromFile() -> String? {
        try? String(contentsOf: Self.refreshTokenFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func saveTokenToFile(_ token: String) {
        do {
            try token.write(to: Self.accessTokenFile, atomically: true, encoding: .utf8)
            logger.info("Access token saved to file")
        } catch {
            logger.error("Failed to save access token to file: \(error)")
        }
    }

    private func saveRefreshTokenToFile(_ token: String) {
        do {
            try token.write(to: Self.refreshTokenFile, atomically: true, encoding: .utf8)
            logger.info("Refresh token saved to file")
        } catch {
            logger.error("Failed to save refresh token to file: \(error)")
        }
    }

    private func deleteTokenFiles() {
        try? FileManager.default.removeItem(at: Self.accessTokenFile)
        try? FileManager.default.removeItem(at: Self.refreshTokenFile)
    }

    /// Migrate: if Keychain has tokens but files don't, write them to files.
    /// If files have tokens but Keychain doesn't, write them to Keychain.
    private func ensureTokensInSync() {
        let fileAccess = loadTokenFromFile()
        let fileRefresh = loadRefreshTokenFromFile()
        let kcAccess = loadKeychainItem(account: "authToken")
        let kcRefresh = loadKeychainItem(account: "refreshToken")

        // File → Keychain
        if let fa = fileAccess, !fa.isEmpty, (kcAccess ?? "").isEmpty {
            saveKeychainItem(account: "authToken", value: fa)
        }
        if let fr = fileRefresh, !fr.isEmpty, (kcRefresh ?? "").isEmpty {
            saveKeychainItem(account: "refreshToken", value: fr)
        }
        // Keychain → File
        if let ka = kcAccess, !ka.isEmpty, (fileAccess ?? "").isEmpty {
            saveTokenToFile(ka)
        }
        if let kr = kcRefresh, !kr.isEmpty, (fileRefresh ?? "").isEmpty {
            saveRefreshTokenToFile(kr)
        }
    }

    // MARK: - Initialization

    init() {
        // Ensure file and Keychain storage are in sync (files survive ad-hoc re-signing)
        ensureTokensInSync()

        // File-based storage is primary (survives ad-hoc rebuilds)
        let savedToken = loadTokenFromFile() ?? loadKeychainItem(account: "authToken")
        if let savedToken, !savedToken.isEmpty {
            self.authToken = savedToken
            self.isAuthenticated = true

            Task {
                let refreshTokenValue = self.loadRefreshTokenFromKeychain()
                if refreshTokenValue != nil {
                    do {
                        try await refreshToken()
                    } catch {
                        logger.warning("Token refresh on init failed: \(error)")
                        // Try fetching profile with existing access token
                        do {
                            try await fetchUserProfile()
                        } catch {
                            // Tokens are preserved — stay authenticated so the user
                            // isn't forced to re-login on every launch when offline
                            // or when the server is temporarily unreachable.
                            logger.warning("Profile fetch also failed (tokens preserved, staying authenticated): \(error)")
                        }
                    }
                } else {
                    do {
                        try await fetchUserProfile()
                    } catch {
                        // No refresh token but access token exists — stay authenticated.
                        // The token will be validated on the next API call.
                        logger.warning("Profile fetch failed on init (staying authenticated): \(error)")
                    }
                }
            }
        }
    }

    // MARK: - Authentication Methods

    func register(email: String, username: String, password: String) async throws {
        isLoading = true
        errorMessage = nil

        defer { isLoading = false }

        let request = RegisterRequest(email: email, username: username, password: password)
        let url = URL(string: "\(baseURL)/api/auth/register")!

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(request)

        let (data, response) = try await URLSession.shared.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.invalidResponse
        }

        if httpResponse.statusCode == 200 {
            let authResponse = try JSONDecoder().decode(AuthResponse.self, from: data)
            await handleSuccessfulAuth(authResponse)
        } else {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw AuthError.serverError(errorText)
        }
    }

    func login(email: String, password: String) async throws {
        isLoading = true
        errorMessage = nil

        defer { isLoading = false }

        let url = URL(string: "\(baseURL)/api/auth/login")!
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"

        // Basic Auth
        let credentials = "\(email):\(password)"
        if let credentialsData = credentials.data(using: .utf8) {
            let base64Credentials = credentialsData.base64EncodedString()
            urlRequest.setValue("Basic \(base64Credentials)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.invalidResponse
        }

        if httpResponse.statusCode == 200 {
            let authResponse = try JSONDecoder().decode(AuthResponse.self, from: data)
            await handleSuccessfulAuth(authResponse)
        } else {
            let errorText = String(data: data, encoding: .utf8) ?? "Invalid credentials"
            throw AuthError.serverError(errorText)
        }
    }

    // MARK: - OAuth Methods

    func signInWithOAuth(provider: String, idToken: String, fullName: String? = nil) async throws {
        isLoading = true
        errorMessage = nil

        defer { isLoading = false }

        let oauthRequest = OAuthRequest(provider: provider, idToken: idToken, fullName: fullName)
        let url = URL(string: "\(baseURL)/api/auth/oauth")!

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(oauthRequest)

        let (data, response) = try await URLSession.shared.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.invalidResponse
        }

        if httpResponse.statusCode == 200 {
            let authResponse = try JSONDecoder().decode(AuthResponse.self, from: data)
            await handleSuccessfulAuth(authResponse)
        } else {
            let errorText = String(data: data, encoding: .utf8) ?? "OAuth sign in failed"
            throw AuthError.serverError(errorText)
        }
    }

    func signInWithApple() async throws {
        let coordinator = AppleSignInCoordinator()
        let (idToken, fullName) = try await coordinator.signIn()
        try await signInWithOAuth(provider: "apple", idToken: idToken, fullName: fullName)
    }

    func signInWithGoogle() async throws {
        isLoading = true
        errorMessage = nil

        defer { isLoading = false }

        let clientId = "809075910499-o01a42a6k9vo2e6a1sfcnifpei3bqnv9.apps.googleusercontent.com"
        let callbackScheme = "com.googleusercontent.apps.809075910499-o01a42a6k9vo2e6a1sfcnifpei3bqnv9"
        let redirectURI = "\(callbackScheme):/oauth/callback"

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "openid email profile"),
        ]

        guard let authURL = components.url else {
            throw AuthError.invalidResponse
        }

        let callbackURL: URL = try await withCheckedThrowingContinuation { continuation in
            self.googleOAuthContinuation = continuation
            NSWorkspace.shared.open(authURL)
        }

        // Extract authorization code from query params
        guard let queryItems = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems,
              let code = queryItems.first(where: { $0.name == "code" })?.value else {
            throw AuthError.serverError("No authorization code in callback")
        }

        // Exchange code for id_token with Google (iOS clients have no secret)
        var tokenRequest = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        tokenRequest.httpMethod = "POST"
        tokenRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = [
            "code=\(code)",
            "client_id=\(clientId)",
            "redirect_uri=\(redirectURI)",
            "grant_type=authorization_code",
        ].joined(separator: "&")
        tokenRequest.httpBody = body.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: tokenRequest)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let errorText = String(data: data, encoding: .utf8) ?? "Token exchange failed"
            throw AuthError.serverError(errorText)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let idToken = json["id_token"] as? String else {
            throw AuthError.serverError("No id_token in Google token response")
        }

        try await signInWithOAuth(provider: "google", idToken: idToken)
    }

    /// Handle the OAuth callback URL from the default browser.
    func handleGoogleOAuthCallback(_ url: URL) {
        googleOAuthContinuation?.resume(returning: url)
        googleOAuthContinuation = nil
    }

    func logout() {
        // Note: We do NOT clear S3 config from keychain on logout
        // This allows users to keep their S3 credentials between sessions
        isAuthenticated = false
        currentUser = nil
        authToken = nil
        tokenObtainedAt = nil
        deleteTokenFromKeychain()
        deleteRefreshTokenFromKeychain()
    }

    // MARK: - Token Refresh

    /// Returns a valid access token, refreshing proactively if near expiry or unknown age.
    /// Use this instead of accessing `authToken` directly for API calls.
    func validToken() async throws -> String {
        guard let token = authToken, !token.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw AuthError.invalidResponse
        }

        // Refresh if near expiry OR if we don't know when the token was obtained
        // (disk-loaded tokens have no tokenObtainedAt and may be expired)
        let needsRefresh = isTokenNearExpiry() || tokenObtainedAt == nil
        if needsRefresh, loadRefreshTokenFromKeychain() != nil {
            do {
                try await refreshToken()
                return self.authToken ?? token
            } catch {
                logger.warning("Proactive refresh failed, using existing token: \(error)")
                return token
            }
        }

        return token
    }

    /// Attempt to refresh the access token using the stored refresh token.
    /// On success, updates both tokens in Keychain and memory.
    func refreshToken() async throws {
        guard !isRefreshing else { return }
        guard let refreshTokenValue = loadRefreshTokenFromKeychain() else {
            throw AuthError.serverError("No refresh token available")
        }

        isRefreshing = true
        defer { isRefreshing = false }

        let url = URL(string: "\(baseURL)/api/auth/refresh")!
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload = ["refresh_token": refreshTokenValue]
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.invalidResponse
        }

        if httpResponse.statusCode == 200 {
            let authResponse = try JSONDecoder().decode(AuthResponse.self, from: data)
            self.authToken = authResponse.accessToken
            self.tokenObtainedAt = Date()
            self.tokenExpiresIn = TimeInterval(authResponse.expiresIn)
            saveTokenToKeychain(authResponse.accessToken)
            if let newRefreshToken = authResponse.refreshToken {
                saveRefreshTokenToKeychain(newRefreshToken)
            }
            self.isAuthenticated = true
            logger.info("Token refreshed successfully")

            // Refresh user profile with new token
            try? await fetchUserProfile()
        } else if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            logger.error("Token refresh rejected with status \(httpResponse.statusCode)")
            throw AuthError.serverError("Refresh token expired or revoked")
        } else {
            logger.error("Token refresh failed with status \(httpResponse.statusCode)")
            // Throw as a generic error so handleUnauthorized doesn't logout
            throw URLError(.badServerResponse)
        }
    }

    /// Attempt a reactive refresh after receiving a 401 response.
    /// Returns true if refresh succeeded (caller should retry their request).
    /// Only logs out on a definitive server rejection (401/403), not on network errors.
    func handleUnauthorized() async -> Bool {
        guard loadRefreshTokenFromKeychain() != nil else {
            logout()
            return false
        }

        do {
            try await refreshToken()
            return true
        } catch let error as AuthError {
            // Server explicitly rejected the refresh token — logout
            logger.warning("Reactive refresh rejected by server, logging out: \(error)")
            logout()
            return false
        } catch {
            // Network error, timeout, etc. — keep tokens, don't force re-login
            logger.warning("Reactive refresh failed (network error, staying authenticated): \(error)")
            return false
        }
    }

    // MARK: - Private Helpers

    private func isTokenNearExpiry() -> Bool {
        guard let obtained = tokenObtainedAt else {
            // Unknown when token was obtained — don't proactively refresh
            return false
        }
        let elapsed = Date().timeIntervalSince(obtained)
        return elapsed >= (tokenExpiresIn - refreshBuffer)
    }

    private func handleSuccessfulAuth(_ authResponse: AuthResponse) async {
        self.authToken = authResponse.accessToken
        self.isAuthenticated = true
        self.tokenObtainedAt = Date()
        self.tokenExpiresIn = TimeInterval(authResponse.expiresIn)
        saveTokenToKeychain(authResponse.accessToken)
        if let refreshTokenValue = authResponse.refreshToken {
            saveRefreshTokenToKeychain(refreshTokenValue)
        }

        // Fetch user profile
        do {
            try await fetchUserProfile()
        } catch {
            logger.warning("Failed to fetch user profile: \(error)")
            // Continue anyway, user is still authenticated
        }
    }

    private func fetchUserProfile() async throws {
        guard let token = authToken else {
            throw AuthError.invalidResponse
        }

        let url = URL(string: "\(baseURL)/api/auth/me")!
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "GET"
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw AuthError.serverError("Failed to fetch user profile")
        }

        let user = try JSONDecoder().decode(User.self, from: data)
        self.currentUser = user
    }

    // MARK: - Keychain

    private func saveTokenToKeychain(_ token: String) {
        saveTokenToFile(token)
        saveKeychainItem(account: "authToken", value: token)
    }

    private func loadTokenFromKeychain() -> String? {
        loadTokenFromFile() ?? loadKeychainItem(account: "authToken")
    }

    private func deleteTokenFromKeychain() {
        try? FileManager.default.removeItem(at: Self.accessTokenFile)
        deleteKeychainItem(account: "authToken")
    }

    private func saveRefreshTokenToKeychain(_ token: String) {
        saveRefreshTokenToFile(token)
        saveKeychainItem(account: "refreshToken", value: token)
    }

    private func loadRefreshTokenFromKeychain() -> String? {
        loadRefreshTokenFromFile() ?? loadKeychainItem(account: "refreshToken")
    }

    private func deleteRefreshTokenFromKeychain() {
        try? FileManager.default.removeItem(at: Self.refreshTokenFile)
        deleteKeychainItem(account: "refreshToken")
    }

    /// Bulk-load all auth keychain items in a single query (one prompt max).
    private func ensureKeychainCacheLoaded() {
        guard !keychainCacheLoaded else { return }
        keychainCacheLoaded = true

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let items = result as? [[String: Any]] else { return }

        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String,
                  let data = item[kSecValueData as String] as? Data,
                  let value = String(data: data, encoding: .utf8) else { continue }
            keychainCache[account] = value
        }
    }

    private func saveKeychainItem(account: String, value: String) {
        ensureKeychainCacheLoaded()
        keychainCache[account] = value

        guard let data = value.data(using: .utf8) else { return }

        // Delete existing
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Add new with proper accessibility
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    private func loadKeychainItem(account: String) -> String? {
        ensureKeychainCacheLoaded()
        return keychainCache[account]
    }

    private func deleteKeychainItem(account: String) {
        ensureKeychainCacheLoaded()
        keychainCache.removeValue(forKey: account)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Apple Sign In Coordinator

class AppleSignInCoordinator: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {

    private var continuation: CheckedContinuation<(idToken: String, fullName: String?), Error>?

    @MainActor
    func signIn() async throws -> (idToken: String, fullName: String?) {
        let provider = ASAuthorizationAppleIDProvider()
        let request = provider.createRequest()
        request.requestedScopes = [.fullName, .email]

        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            controller.performRequests()
        }
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        NSApplication.shared.mainWindow ?? ASPresentationAnchor()
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = credential.identityToken,
              let idToken = String(data: tokenData, encoding: .utf8) else {
            continuation?.resume(throwing: AuthError.invalidResponse)
            continuation = nil
            return
        }

        var fullName: String?
        if let nameComponents = credential.fullName {
            let parts = [nameComponents.givenName, nameComponents.familyName].compactMap { $0 }
            if !parts.isEmpty {
                fullName = parts.joined(separator: " ")
            }
        }

        continuation?.resume(returning: (idToken, fullName))
        continuation = nil
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

// MARK: - Errors

enum AuthError: Error, LocalizedError {
    case invalidResponse
    case serverError(String)
    case networkError

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from server"
        case .serverError(let message):
            return message
        case .networkError:
            return "Network error occurred"
        }
    }
}
