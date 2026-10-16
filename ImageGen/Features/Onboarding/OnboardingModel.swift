import Foundation
import Observation

/// Connect Gemini (D§3.2): validate a typed key, then save it. Logged as Save API key with a
/// Validate key sub-action; the follow-up models refresh is its own action (D§4.13).
@Observable @MainActor
final class OnboardingModel {
  enum Phase: Equatable {
    case idle
    case validating
    case rejected(String)
    /// Network error or 5xx: Retry or Save Anyway.
    case unreachable(String)
    case saved(flashWarning: Bool)
  }

  static let flashWarning = "Your key doesn't list Gemini 3.1 Flash Image; generation may fail."

  var keyText = ""
  var reveal = false
  private(set) var phase: Phase = .idle
  /// Set when the form is closed: a validation still running then saves nothing.
  private(set) var isCancelled = false

  private let keyStore: any APIKeyStore
  private let availability: ModelAvailabilityService
  private let registry: SecretRegistry
  private let log: ActivityLog
  private let source: String

  init(keyStore: any APIKeyStore, availability: ModelAvailabilityService, registry: SecretRegistry, log: ActivityLog,
       source: String = "onboarding") {
    self.keyStore = keyStore
    self.availability = availability
    self.registry = registry
    self.log = log
    self.source = source
  }

  var trimmedKey: String { keyText.trimmingCharacters(in: .whitespacesAndNewlines) }

  /// Cancel on the inline Replace Key form.
  func cancel() { isCancelled = true }
  var canValidate: Bool { !trimmedKey.isEmpty && phase != .validating }

  /// Validate & Save. Returns true once the key is saved.
  @discardableResult
  func validateAndSave() async -> Bool {
    let key = trimmedKey
    guard !key.isEmpty else { return false }
    registry.register(key)
    phase = .validating
    let action = log.begin("Save API key", origin: .user, "from \(source)")
    let validation = await availability.validateKey(key, parent: action)
    // The form was cancelled while the key was checked: the user no longer wants it saved.
    if isCancelled {
      log.result(action, .cancelled, "not saved · cancelled while validating")
      return false
    }
    switch validation {
    case .valid(_, let flashListed):
      return save(key, action: action, flashWarning: !flashListed, note: "validated")
    case .rejected(let message, let reason):
      log.result(action, .failed, "not saved · key rejected\(reason.map { " · \($0)" } ?? ""): \(private: message)")
      phase = .rejected(message)
      return false
    case .unreachable(let message):
      log.result(action, .failed, "not saved · couldn't reach Google: \(private: message)")
      phase = .unreachable(message)
      return false
    }
  }

  /// Save Anyway, after "Couldn't reach Google".
  @discardableResult
  func saveAnyway() -> Bool {
    let key = trimmedKey
    guard !key.isEmpty else { return false }
    registry.register(key)
    let action = log.begin("Save API key", origin: .user, "from \(source) · Save Anyway")
    return save(key, action: action, flashWarning: false, note: "not validated")
  }

  private func save(_ key: String, action: ActionID, flashWarning: Bool, note: String) -> Bool {
    do {
      try keyStore.save(key)
      log.result(action, .success, "saved (\(note)) · Keychain ok")
      phase = .saved(flashWarning: flashWarning)
      keyText = ""
      let availability = self.availability
      Task { _ = await availability.refresh(reason: .keySaved) }
      return true
    } catch {
      log.result(action, .failed, "not saved · Keychain: \(error.localizedDescription)")
      phase = .rejected("Couldn't save the key: \(error.localizedDescription)")
      return false
    }
  }
}
