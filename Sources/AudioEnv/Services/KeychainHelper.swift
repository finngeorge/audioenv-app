import Foundation
import Security
import os.log

/// Secure storage for sensitive credentials using macOS Keychain.
///
/// Uses an in-memory cache so the system keychain dialog is shown at most once
/// per app launch (bulk-loads all items for the service on first access).
class KeychainHelper {

    static let shared = KeychainHelper()
    private init() {}

    private let logger = Logger(subsystem: "com.audioenv.app", category: "Keychain")

    /// In-memory cache of keychain items (account → value).
    /// Populated by a single bulk fetch on first access, then kept in sync
    /// with save/delete operations so we never re-prompt.
    private var cache: [String: String] = [:]
    private var cacheLoaded = false

    // MARK: - S3 Credentials

    private let s3BucketKey = "com.audioenv.s3.bucket"
    private let s3AccessKeyIdKey = "com.audioenv.s3.accessKeyId"
    private let s3SecretKeyKey = "com.audioenv.s3.secretKey"
    private let s3RegionKey = "com.audioenv.s3.region"

    /// Save S3 configuration to Keychain (user-scoped)
    func saveS3Config(bucket: String, accessKeyId: String, secretKey: String, region: String, forUser userId: String) {
        let userBucketKey = "\(s3BucketKey).\(userId)"
        let userRegionKey = "\(s3RegionKey).\(userId)"
        let userAccessKeyIdKey = "\(s3AccessKeyIdKey).\(userId)"
        let userSecretKeyKey = "\(s3SecretKeyKey).\(userId)"

        UserDefaults.standard.set(bucket, forKey: userBucketKey)
        UserDefaults.standard.set(region, forKey: userRegionKey)

        // Store sensitive keys in Keychain
        save(accessKeyId, forKey: userAccessKeyIdKey)
        save(secretKey, forKey: userSecretKeyKey)
    }

    /// Load S3 configuration from Keychain (user-scoped)
    func loadS3Config(forUser userId: String) -> (bucket: String, accessKeyId: String, secretKey: String, region: String)? {
        let userBucketKey = "\(s3BucketKey).\(userId)"
        let userRegionKey = "\(s3RegionKey).\(userId)"
        let userAccessKeyIdKey = "\(s3AccessKeyIdKey).\(userId)"
        let userSecretKeyKey = "\(s3SecretKeyKey).\(userId)"

        let bucket = UserDefaults.standard.string(forKey: userBucketKey)
        let region = UserDefaults.standard.string(forKey: userRegionKey)
        let accessKeyId = load(forKey: userAccessKeyIdKey)
        let secretKey = load(forKey: userSecretKeyKey)

        guard let bucket = bucket,
              let region = region,
              let accessKeyId = accessKeyId,
              let secretKey = secretKey else {
            return nil
        }

        return (bucket, accessKeyId, secretKey, region)
    }

    /// Remove S3 configuration from Keychain (user-scoped)
    func clearS3Config(forUser userId: String) {
        let userBucketKey = "\(s3BucketKey).\(userId)"
        let userRegionKey = "\(s3RegionKey).\(userId)"
        let userAccessKeyIdKey = "\(s3AccessKeyIdKey).\(userId)"
        let userSecretKeyKey = "\(s3SecretKeyKey).\(userId)"

        UserDefaults.standard.removeObject(forKey: userBucketKey)
        UserDefaults.standard.removeObject(forKey: userRegionKey)
        delete(forKey: userAccessKeyIdKey)
        delete(forKey: userSecretKeyKey)
    }

    /// Migrate old S3 config (without user scoping) to new user-scoped format
    func migrateS3ConfigIfNeeded(forUser userId: String) {
        // Check if user already has scoped config
        if loadS3Config(forUser: userId) != nil {
            return  // Already migrated or newly configured
        }

        // Try to load old unscoped config
        guard let bucket = UserDefaults.standard.string(forKey: s3BucketKey),
              let region = UserDefaults.standard.string(forKey: s3RegionKey),
              let accessKeyId = load(forKey: s3AccessKeyIdKey),
              let secretKey = load(forKey: s3SecretKeyKey) else {
            return  // No old config to migrate
        }

        // Migrate to new scoped format
        saveS3Config(bucket: bucket, accessKeyId: accessKeyId, secretKey: secretKey, region: region, forUser: userId)

        // Clean up old unscoped config
        UserDefaults.standard.removeObject(forKey: s3BucketKey)
        UserDefaults.standard.removeObject(forKey: s3RegionKey)
        delete(forKey: s3AccessKeyIdKey)
        delete(forKey: s3SecretKeyKey)
    }

    // MARK: - Bulk Cache Loading

    /// Load ALL keychain items for this service in a single query.
    /// This triggers at most one system keychain prompt per app launch.
    private func ensureCacheLoaded() {
        guard !cacheLoaded else { return }
        cacheLoaded = true

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.audioenv.app",
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let items = result as? [[String: Any]] else {
            if status != errSecItemNotFound {
                logger.warning("Bulk keychain load returned status \(status)")
            }
            return
        }

        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String,
                  let data = item[kSecValueData as String] as? Data,
                  let value = String(data: data, encoding: .utf8) else { continue }
            cache[account] = value
        }

        logger.info("Loaded \(self.cache.count) keychain items into cache")
    }

    // MARK: - Generic Keychain Operations

    /// Save a string value to Keychain (and update the in-memory cache)
    private func save(_ value: String, forKey key: String) {
        ensureCacheLoaded()
        cache[key] = value

        let data = value.data(using: .utf8)!

        // Delete any existing item
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: "com.audioenv.app",
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: "com.audioenv.app",
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)

        if status != errSecSuccess {
            logger.error("Keychain save failed for \(key): \(status)")
        }
    }

    /// Load a string value from Keychain (returns cached value if available)
    private func load(forKey key: String) -> String? {
        ensureCacheLoaded()
        return cache[key]
    }

    /// Delete a value from Keychain (and remove from cache)
    private func delete(forKey key: String) {
        ensureCacheLoaded()
        cache.removeValue(forKey: key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: "com.audioenv.app",
        ]

        SecItemDelete(query as CFDictionary)
    }
}
