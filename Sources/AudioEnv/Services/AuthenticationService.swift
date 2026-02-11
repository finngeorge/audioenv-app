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

    #if DEBUG
    private let baseURL = "http://localhost:8001"
    #else
    private let baseURL = "https://api.audioenv.com"
    #endif
    private let keychainService = "com.audioenv.app"

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
        let tokenType: String
        let expiresIn: Int

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case tokenType = "token_type"
            case expiresIn = "expires_in"
        }
    }

    // MARK: - Initialization

    init() {
        // Try to load saved token from Keychain
        if let savedToken = loadTokenFromKeychain() {
            self.authToken = savedToken
            self.isAuthenticated = true
            // Fetch user profile
            Task {
                do {
                    try await fetchUserProfile()
                } catch {
                    logger.warning("Failed to fetch user profile on init: \(error)")
                    // Token might be expired, log out
                    logout()
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
            await handleSuccessfulAuth(token: authResponse.accessToken)
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
            await handleSuccessfulAuth(token: authResponse.accessToken)
        } else {
            let errorText = String(data: data, encoding: .utf8) ?? "Invalid credentials"
            throw AuthError.serverError(errorText)
        }
    }

    func logout() {
        // Note: We do NOT clear S3 config from keychain on logout
        // This allows users to keep their S3 credentials between sessions
        // The config will be cleared from memory by the onChange handler in App.swift
        // Users can explicitly disconnect S3 via the "Disconnect" button in BackupConfigView

        isAuthenticated = false
        currentUser = nil
        authToken = nil
        deleteTokenFromKeychain()
    }

    // MARK: - Private Helpers

    private func handleSuccessfulAuth(token: String) async {
        self.authToken = token
        self.isAuthenticated = true
        saveTokenToKeychain(token)

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
        guard let data = token.data(using: .utf8) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: "authToken",
            kSecValueData as String: data
        ]

        // Delete existing
        SecItemDelete(query as CFDictionary)

        // Add new
        SecItemAdd(query as CFDictionary, nil)
    }

    private func loadTokenFromKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: "authToken",
            kSecReturnData as String: true
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else {
            return nil
        }

        return token
    }

    private func deleteTokenFromKeychain() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: "authToken"
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
