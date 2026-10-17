import Foundation
import Observation

/// Presentation model driving API credential entry, verification, and persistence.
///
/// Coordinates credential validation against Gemini availability endpoints before storing
/// keys securely in the system Keychain and updating redactor registry masking.
@Observable @MainActor
final class OnboardingModel {
  /// Lifecycle phase of credential validation and persistence operations.
  enum Phase: Equatable {
    case idle
    case validating
    case rejected(String)
    /// Transient network or server fault permitting manual override or retry.
    case unreachable(String)
    /// Credential successfully persisted, accompanied by compatibility warning status.
    case saved(flashWarning: Bool)
  }

  static let flashWarning = "Your key doesn't list Gemini 3.1 Flash Image; generation may fail."

  var keyText = ""
  var reveal = false
  private(set) var phase: Phase = .idle
  /// Indicates whether the active validation operation was cancelled prior to completion.
  private(set) var isCancelled = false

  private let keyStore: any APIKeyStore
  private let availability: ModelAvailabilityService
  private let registry: SecretRegistry
  private let log: ActivityLog
  /// Origin context identifier for diagnostic activity logging.
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

  /// Cancels in-flight validation and prevents subsequent persistence.
  func cancel() { isCancelled = true }
  /// Dictates whether validation submission can be initiated based on input presence and active state.
  var canValidate: Bool { !trimmedKey.isEmpty && phase != .validating }

  /// Validates the entered credential against remote endpoints and persists valid keys to secure storage.
  @discardableResult
  func validateAndSave() async -> Bool {
    // Freeze key snapshot prior to asynchronous suspension point.
    let key = trimmedKey
    guard !key.isEmpty else { return false }
    // Register secret immediately to guarantee redaction across subsequent diagnostic logging.
    registry.register(key)
    phase = .validating
    let action = log.begin("Save API key", origin: .user, "from \(source)")
    let validation = await availability.validateKey(key, parent: action)
    // Abort persistence if validation was cancelled during remote verification.
    if isCancelled {
      log.result(action, .cancelled, "not saved · cancelled while validating")
      return false
    }
    switch validation {
    case .valid(_, let flashListed):
      return save(key, action: action, flashWarning: !flashListed, note: "validated")
    // Redact server diagnostic text in logs to prevent accidental disclosure.
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

  /// Persists unverified credentials directly to Keychain storage following network reachability failures.
  @discardableResult
  func saveAnyway() -> Bool {
    let key = trimmedKey
    guard !key.isEmpty else { return false }
    registry.register(key)
    let action = log.begin("Save API key", origin: .user, "from \(source) · Save Anyway")
    return save(key, action: action, flashWarning: false, note: "not validated")
  }

  /// Persists credentials to Keychain storage and records corresponding activity log results.
  private func save(_ key: String, action: ActionID, flashWarning: Bool, note: String) -> Bool {
    do {
      try keyStore.save(key)
      log.result(action, .success, "saved (\(note)) · Keychain ok")
      phase = .saved(flashWarning: flashWarning)
      keyText = ""
      // Dispatch asynchronous model catalog refresh in the background following successful credential configuration.
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
