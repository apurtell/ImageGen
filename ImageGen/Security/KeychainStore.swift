import Foundation
import Security
import Synchronization

/// Storage interface managing secure persistence and retrieval of the API authentication key.
/// Decoupled from user defaults and database entities to prevent credential exposure in application logs or backups.
protocol APIKeyStore: Sendable {
  /// Retrieves the persisted key, returning nil if unset or throwing on operating system Keychain errors.
  func read() throws -> String?
  /// Persists or updates the stored API credential.
  func save(_ key: String) throws
  /// Purges the API credential from storage.
  func delete() throws
}

/// Strongly typed error wrapper capturing OSStatus failures returned by Security framework routines.
struct KeychainError: Error, Equatable, CustomStringConvertible {
  let status: OSStatus
  var description: String {
    "Keychain error \(status): \((SecCopyErrorMessageString(status, nil) as String?) ?? "unknown")"
  }
}

/// Security framework implementation persisting credentials as a device-local generic password.
///
/// Policies:
/// - Enforces `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` accessibility attributes, ensuring availability
///   during background execution wakes while precluding iCloud keychain synchronization or backup restoration.
/// - Automatically registers retrieved or saved secrets with `SecretRegistry` to facilitate logging redaction.
struct KeychainStore: APIKeyStore {
  static let defaultService = (Bundle.main.bundleIdentifier ?? "com.andrewpurtell.imagegen") + ".gemini"
  static let account = "api-key"

  let service: String
  let registry: SecretRegistry

  init(service: String = KeychainStore.defaultService, registry: SecretRegistry) {
    self.service = service
    self.registry = registry
  }

  /// Base query attributes identifying the application's unique credential entry.
  private var baseQuery: [CFString: Any] {
    [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: Self.account]
  }

  func read() throws -> String? {
    var query = baseQuery
    query[kSecReturnData] = true
    query[kSecMatchLimit] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = item as? Data else { throw KeychainError(status: status) }
    let key = String(decoding: data, as: UTF8.self)
    registry.register(key)
    return key
  }

  /// Atomically updates or inserts the credential to eliminate race conditions during key rotation.
  func save(_ key: String) throws {
    registry.register(key)
    let data = Data(key.utf8)
    let attributes: [CFString: Any] = [
      kSecValueData: data, kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    let status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
    if status == errSecSuccess { return }
    guard status == errSecItemNotFound else { throw KeychainError(status: status) }
    var add = baseQuery
    add.merge(attributes) { _, new in new }
    let added = SecItemAdd(add as CFDictionary, nil)
    guard added == errSecSuccess else { throw KeychainError(status: added) }
  }

  func delete() throws {
    let status = SecItemDelete(baseQuery as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
  }

  /// Queries raw item attributes for diagnostic validation.
  func attributes() throws -> [String: Any]? {
    var query = baseQuery
    query[kSecReturnAttributes] = true
    query[kSecMatchLimit] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw KeychainError(status: status) }
    return item as? [String: Any]
  }
}

/// Thread-safe in-memory credential storage implementation utilized for automated testing and preview environments.
final class InMemoryKeyStore: APIKeyStore {
  private let key: Mutex<String?>
  private let registry: SecretRegistry

  init(key: String? = nil, registry: SecretRegistry) {
    self.key = Mutex(key)
    self.registry = registry
  }

  func read() throws -> String? {
    let value = key.withLock { $0 }
    if let value { registry.register(value) }
    return value
  }

  func save(_ newKey: String) throws {
    registry.register(newKey)
    key.withLock { $0 = newKey }
  }

  func delete() throws {
    key.withLock { $0 = nil }
  }
}
