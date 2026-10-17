import Foundation
import Observation

/// Connect Gemini (D§3.2): validate a typed key, then save it. Logged as Save API key with a
/// Validate key sub-action; the follow-up models refresh is its own action (D§4.13).
///
/// Two screens use it: `OnboardingView` at first launch (or after Remove Key), and the inline
/// Replace Key form in Settings (`APIKeySectionModel` creates one there). It calls
/// `ModelAvailabilityService` to check the key and `APIKeyStore` (the Keychain) to save it.
///
/// Concurrency: `@MainActor`. `validateAndSave` has one suspension point, the network check. During
/// it the user can still type, or close the Replace Key form. So the key is copied before the
/// `await`, and the cancel flag is checked after it: a cancel during validation saves nothing.
@Observable @MainActor
final class OnboardingModel {
  /// What the form shows. The cases with a `String` carry the message for the user.
  enum Phase: Equatable {
    case idle
    case validating
    case rejected(String)
    /// Network error or 5xx: Retry or Save Anyway.
    case unreachable(String)
    /// The key is saved. `flashWarning` is true when the key's model list lacks Gemini 3.1 Flash
    /// Image; the view then shows a non-blocking warning first.
    case saved(flashWarning: Bool)
  }

  static let flashWarning = "Your key doesn't list Gemini 3.1 Flash Image; generation may fail."

  var keyText = ""
  var reveal = false
  private(set) var phase: Phase = .idle
  /// Set when the form is closed: a validation still running then saves nothing.
  /// It is never reset: a cancelled model is discarded, and a new form gets a new model.
  private(set) var isCancelled = false

  private let keyStore: any APIKeyStore
  private let availability: ModelAvailabilityService
  private let registry: SecretRegistry
  private let log: ActivityLog
  /// Where the form is, for the log ("onboarding" or "Settings › Replace Key").
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
  /// False while a check runs, so a second tap cannot start a second check.
  var canValidate: Bool { !trimmedKey.isEmpty && phase != .validating }

  /// Validate & Save. Returns true once the key is saved.
  @discardableResult
  /// `@discardableResult`: callers may ignore the return value without a compiler warning.
  func validateAndSave() async -> Bool {
    // Copied before the `await`: the key that is checked is the key that is saved, even if the
    // user types during the check.
    let key = trimmedKey
    guard !key.isEmpty else { return false }
    // Registered first, so the log removes the key from any line that echoes it.
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
    // `\(private: …)` marks the server's message as private in the log (D§4.13).
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
  /// Synchronous: it does not check the key, so there is no suspension point and no cancel check.
  /// It is its own Save API key action, separate from the failed one before it.
  @discardableResult
  func saveAnyway() -> Bool {
    let key = trimmedKey
    guard !key.isEmpty else { return false }
    registry.register(key)
    let action = log.begin("Save API key", origin: .user, "from \(source) · Save Anyway")
    return save(key, action: action, flashWarning: false, note: "not validated")
  }

  /// Writes the key to the Keychain and writes the action's Result, on success and on failure.
  private func save(_ key: String, action: ActionID, flashWarning: Bool, note: String) -> Bool {
    do {
      try keyStore.save(key)
      log.result(action, .success, "saved (\(note)) · Keychain ok")
      phase = .saved(flashWarning: flashWarning)
      keyText = ""
      // The models refresh for the new key runs on its own; this call does not wait for it. The
      // service is copied to a local, so the task does not keep this model alive.
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
