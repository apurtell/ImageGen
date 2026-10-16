import Foundation
import Security
import Testing

@testable import ImageGen

/// Uses its own service name, never the app's Keychain item.
@Suite(.serialized, .tags(.io))
struct KeychainStoreTests {
  static let service = "com.andrewpurtell.imagegen.tests"

  @Test func roundTrip() throws {
    let registry = SecretRegistry()
    let store = KeychainStore(service: Self.service, registry: registry)
    try store.delete()
    defer { try? store.delete() }
    #expect(try store.read() == nil)
    try store.save("AIza-first-key")
    #expect(try store.read() == "AIza-first-key")
    try store.save("AIza-second-key")
    #expect(try store.read() == "AIza-second-key")
    try store.delete()
    #expect(try store.read() == nil)
    try store.delete()
  }

  @Test func accessibilityIsAfterFirstUnlockThisDeviceOnly() throws {
    let store = KeychainStore(service: Self.service, registry: SecretRegistry())
    try store.delete()
    defer { try? store.delete() }
    try store.save("AIza-access")
    let attributes = try #require(try store.attributes())
    #expect(attributes[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
    #expect(attributes[kSecAttrService as String] as? String == Self.service)
    #expect(attributes[kSecAttrAccount as String] as? String == "api-key")
    #expect((attributes[kSecAttrSynchronizable as String] as? Bool ?? false) == false)
  }

  @Test func readAndSaveRegisterSecret() throws {
    let registry = SecretRegistry()
    let store = KeychainStore(service: Self.service, registry: registry)
    try store.delete()
    defer { try? store.delete() }
    try store.save("AIza-saved")
    #expect(registry.all == ["AIza-saved"])
    let other = SecretRegistry()
    #expect(try KeychainStore(service: Self.service, registry: other).read() == "AIza-saved")
    #expect(other.all == ["AIza-saved"])
    try store.delete()
    #expect(registry.all == ["AIza-saved"])
  }
}

@Suite(.tags(.pure))
struct InMemoryKeyStoreTests {
  @Test func roundTripThroughProtocol() throws {
    let store: any APIKeyStore = InMemoryKeyStore(registry: SecretRegistry())
    #expect(try store.read() == nil)
    try store.save("mock-key")
    #expect(try store.read() == "mock-key")
    try store.delete()
    #expect(try store.read() == nil)
  }

  @Test func readAndSaveRegisterSecret() throws {
    let registry = SecretRegistry()
    let preloaded = InMemoryKeyStore(key: "preloaded", registry: registry)
    #expect(registry.all.isEmpty)
    _ = try preloaded.read()
    #expect(registry.all == ["preloaded"])
    try preloaded.save("saved-key-value")
    #expect(Set(registry.all) == ["preloaded", "saved-key-value"])
    try preloaded.delete()
    #expect(Set(registry.all) == ["preloaded", "saved-key-value"])
    registry.register("")
    registry.register("short")
    #expect(registry.all.count == 2)
  }
}
