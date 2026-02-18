import Foundation
import SwiftUI
import os.log

/// Manages user authentication state and API communication
@MainActor
class AuthenticationService: ObservableObject {

    private let logger = Logger(subsystem: "com.audioenv.app", category: "Auth")

    @Published var isAuthenticated = false
    @Published var currentUser: User?
    @Published var authToken: String?
    @Published var isLoading = false
    @Published var errorMessage: String?

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

    // MARK: - File-based token storage

    /// Directory for persisted auth tokens (survives ad-hoc signing rebuilds unlike Keychain).
    private static let tokenStorageURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("AudioEnv", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static let accessTokenFile = tokenStorageURL.appendingPathComponent(".auth_token")
    private static let refreshTokenFile = tokenStorageURL.appendingPathComponent(".refresh_token")

    private func saveTokenToFile(_ token: String) {
        try? token.write(to: Self.accessTokenFile, atomically: true, encoding: .utf8)
    }

    private func loadTokenFromFile() -> String? {
        try? String(contentsOf: Self.accessTokenFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func saveRefreshTokenToFile(_ token: String) {
        try? token.write(to: Self.refreshTokenFile, atomically: true, encoding: .utf8)
    }

    private func loadRefreshTokenFromFile() -> String? {
        try? String(contentsOf: Self.refreshTokenFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func deleteTokenFiles() {
        try? FileManager.default.removeItem(at: Self.accessTokenFile)
        try? FileManager.default.removeItem(at: Self.refreshTokenFile)
    }

    // MARK: - Initialization

    init() {
        // Try file-based storage first (reliable across ad-hoc rebuilds), then Keychain
        let savedToken = loadTokenFromFile() ?? loadTokenFromKeychain()
        if let savedToken, !savedToken.isEmpty {
            self.authToken = savedToken
            self.isAuthenticated = true

            // Migrate keychain-only tokens to file storage
            if loadTokenFromFile() == nil {
                saveTokenToFile(savedToken)
            }
            if let rt = loadRefreshTokenFromKeychain(), loadRefreshTokenFromFile() == nil {
                saveRefreshTokenToFile(rt)
            }

            Task {
                let refreshTokenValue = self.loadRefreshTokenFromFile() ?? self.loadRefreshTokenFromKeychain()
                if refreshTokenValue != nil {
                    do {
                        try await refreshToken()
                    } catch {
                        logger.warning("Token refresh on init failed: \(error)")
                        // Try fetching profile with existing access token
                        do {
                            try await fetchUserProfile()
                        } catch {
                            // Don't delete tokens — they may work later (network issue, server down).
                            // Just mark as unauthenticated so the login gate shows.
                            logger.warning("Profile fetch failed, marking unauthenticated (tokens preserved): \(error)")
                            self.isAuthenticated = false
                            self.currentUser = nil
                        }
                    }
                } else {
                    do {
                        try await fetchUserProfile()
                    } catch {
                        logger.warning("Failed to fetch user profile on init, marking unauthenticated: \(error)")
                        self.isAuthenticated = false
                        self.currentUser = nil
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

    func logout() {
        // Note: We do NOT clear S3 config from keychain on logout
        // This allows users to keep their S3 credentials between sessions

        isAuthenticated = false
        currentUser = nil
        authToken = nil
        tokenObtainedAt = nil
        deleteTokenFromKeychain()
        deleteRefreshTokenFromKeychain()
        deleteTokenFiles()
    }

    // MARK: - Token Refresh

    /// Returns a valid access token, refreshing proactively if near expiry.
    /// Use this instead of accessing `authToken` directly for API calls.
    func validToken() async throws -> String {
        guard let token = authToken else {
            throw AuthError.invalidResponse
        }

        // Check if token is near expiry and we have a refresh token
        if isTokenNearExpiry(), (loadRefreshTokenFromFile() ?? loadRefreshTokenFromKeychain()) != nil {
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
        guard let refreshTokenValue = loadRefreshTokenFromFile() ?? loadRefreshTokenFromKeychain() else {
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
            saveTokenToFile(authResponse.accessToken)
            if let newRefreshToken = authResponse.refreshToken {
                saveRefreshTokenToKeychain(newRefreshToken)
                saveRefreshTokenToFile(newRefreshToken)
            }
            self.isAuthenticated = true
            logger.info("Token refreshed successfully")

            // Refresh user profile with new token
            try? await fetchUserProfile()
        } else {
            logger.error("Token refresh failed with status \(httpResponse.statusCode)")
            throw AuthError.serverError("Token refresh failed")
        }
    }

    /// Attempt a reactive refresh after receiving a 401 response.
    /// Returns true if refresh succeeded (caller should retry their request).
    func handleUnauthorized() async -> Bool {
        guard (loadRefreshTokenFromFile() ?? loadRefreshTokenFromKeychain()) != nil else {
            logout()
            return false
        }

        do {
            try await refreshToken()
            return true
        } catch {
            logger.warning("Reactive refresh failed, logging out: \(error)")
            logout()
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
        saveTokenToFile(authResponse.accessToken)
        if let refreshTokenValue = authResponse.refreshToken {
            saveRefreshTokenToKeychain(refreshTokenValue)
            saveRefreshTokenToFile(refreshTokenValue)
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
        saveKeychainItem(account: "authToken", value: token)
    }

    private func loadTokenFromKeychain() -> String? {
        loadKeychainItem(account: "authToken")
    }

    private func deleteTokenFromKeychain() {
        deleteKeychainItem(account: "authToken")
    }

    private func saveRefreshTokenToKeychain(_ token: String) {
        saveKeychainItem(account: "refreshToken", value: token)
    }

    private func loadRefreshTokenFromKeychain() -> String? {
        loadKeychainItem(account: "refreshToken")
    }

    private func deleteRefreshTokenFromKeychain() {
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
