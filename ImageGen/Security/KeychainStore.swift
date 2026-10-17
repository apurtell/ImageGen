import Foundation
import Security
import Synchronization

/// Where the API key lives. Onboarding, Settings and `GenerationService` depend only on this.
///
/// The key is never kept in `AppSettings`, the database or the log (D§4.10). Callers read it each time
/// they need it, for example each time a task is created, including retries created in the background.
/// The calls are synchronous and can come from any thread or actor, so a conformer must be `Sendable`.
protocol APIKeyStore: Sendable {
  /// nil when no key is stored. Throws only for a real Keychain failure.
  func read() throws -> String?
  /// Replaces the stored key, or adds it when none is stored.
  func save(_ key: String) throws
  /// Succeeds when no key is stored.
  func delete() throws
}

/// A Keychain failure, with the system's message for its status code.
struct KeychainError: Error, Equatable, CustomStringConvertible {
  let status: OSStatus
  var description: String {
    "Keychain error \(status): \((SecCopyErrorMessageString(status, nil) as String?) ?? "unknown")"
  }
}

/// A generic password, this device only, no iCloud sync (D§4.10). Registers the key with the
/// `SecretRegistry` on every read that returns one and on every save.
///
/// The Keychain is the operating system's encrypted secret store. Each call here is one query to it,
/// identified by service and account. The struct holds no state of its own, and the Keychain functions
/// are safe to call from any thread, so the struct is `Sendable` with no lock. The registration makes
/// sure that the log sanitizer knows the key before any code can log text that contains it.
struct KeychainStore: APIKeyStore {
  static let defaultService = (Bundle.main.bundleIdentifier ?? "com.andrewpurtell.imagegen") + ".gemini"
  static let account = "api-key"

  let service: String
  let registry: SecretRegistry

  init(service: String = KeychainStore.defaultService, registry: SecretRegistry) {
    self.service = service
    self.registry = registry
  }

  /// The attributes that identify the one item. Each call adds what it needs to return or change.
  private var baseQuery: [CFString: Any] {
    [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: Self.account]
  }

  func read() throws -> String? {
    var query = baseQuery
    query[kSecReturnData] = true
    query[kSecMatchLimit] = kSecMatchLimitOne
    var item: CFTypeRef?
    // `&item` passes `item` by reference: the C function writes the result into it.
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = item as? Data else { throw KeychainError(status: status) }
    let key = String(decoding: data, as: UTF8.self)
    registry.register(key)
    return key
  }

  /// Update first, then add if there was nothing to update. This keeps one item, with no window in
  /// which the old key is gone and the new one is not yet stored.
  func save(_ key: String) throws {
    // Registered before the Keychain call, so no later log line can show the key, even if the save fails.
    registry.register(key)
    let data = Data(key.utf8)
    // "After first unlock": background relaunches can read the key while the device is locked. "This
    // device only": the item is never synced or restored to another device.
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
///
/// The key is behind a `Mutex`, because callers on different threads can read and save at the same time
/// (see the primer, *Locks*). It registers keys with the registry exactly as `KeychainStore` does.
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
