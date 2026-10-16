import Foundation
import Observation

/// Settings › API Key (the M5 stub; M8 adds Replace Key and Validate Now).
@Observable @MainActor
final class APIKeySectionModel {
  private let keyStore: any APIKeyStore
  private let log: ActivityLog
  private(set) var lastFour: String?

  init(keyStore: any APIKeyStore, log: ActivityLog) {
    self.keyStore = keyStore
    self.log = log
    reload()
  }

  var hasKey: Bool { lastFour != nil }

  func reload() {
    lastFour = (try? keyStore.read()).flatMap { $0 }.map { String($0.suffix(4)) }
  }

  /// Remove Key. Returns true when the key is gone (onboarding follows).
  @discardableResult
  func removeKey() -> Bool {
    let action = log.begin("Remove API key", origin: .user, "Settings")
    do {
      try keyStore.delete()
      log.result(action, .success, "Keychain status ok · key removed")
      lastFour = nil
      return true
    } catch {
      log.result(action, .failed, "Keychain: \(error.localizedDescription)")
      return false
    }
  }
}
