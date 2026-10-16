import Foundation
import Security
import Synchronization

/// Where the API key lives. Onboarding, Settings and `GenerationService` depend only on this.
protocol APIKeyStore: Sendable {
  func read() throws -> String?
  func save(_ key: String) throws
  func delete() throws
}

struct KeychainError: Error, Equatable, CustomStringConvertible {
  let status: OSStatus
  var description: String {
    "Keychain error \(status): \((SecCopyErrorMessageString(status, nil) as String?) ?? "unknown")"
  }
}

/// A generic password, this device only, no iCloud sync (D§4.10). Registers the key with the
/// `SecretRegistry` on every read that returns one and on every save.
struct KeychainStore: APIKeyStore {
  static let defaultService = (Bundle.main.bundleIdentifier ?? "com.andrewpurtell.imagegen") + ".gemini"
  static let account = "api-key"

  let service: String
  let registry: SecretRegistry

  init(service: String = KeychainStore.defaultService, registry: SecretRegistry) {
    self.service = service
    self.registry = registry
  }

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

  /// The stored item's attributes, for tests.
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

/// For unit tests and DEBUG mock mode, so neither touches the real Keychain.
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
