import Foundation
import Observation

/// Settings › API Key (D§3.8): status, Replace Key (the onboarding form inline), Validate Now and
/// Remove Key. Replace and Remove reuse the Save API key and Remove API key actions.
@Observable @MainActor
final class APIKeySectionModel {
  enum ValidationState: Equatable {
    case idle
    case validating
    case valid(String)
    case problem(String)
  }

  private let keyStore: any APIKeyStore
  private let log: ActivityLog
  private let availability: ModelAvailabilityService?
  private let registry: SecretRegistry?
  private(set) var lastFour: String?
  private(set) var validation = ValidationState.idle
  /// The inline Replace Key form, while it's open.
  private(set) var replace: OnboardingModel?

  init(keyStore: any APIKeyStore, log: ActivityLog, availability: ModelAvailabilityService? = nil, registry: SecretRegistry? = nil) {
    self.keyStore = keyStore
    self.log = log
    self.availability = availability
    self.registry = registry
    reload()
  }

  var hasKey: Bool { lastFour != nil }

  /// "Saved (…a1B2)" or "Not set".
  var statusText: String { lastFour.map { "Saved (…\($0))" } ?? "Not set" }

  func reload() {
    lastFour = (try? keyStore.read()).flatMap { $0 }.map { String($0.suffix(4)) }
  }

  // MARK: Replace Key

  func beginReplace() {
    guard let availability, let registry else { return }
    validation = .idle
    replace = OnboardingModel(
      keyStore: keyStore, availability: availability, registry: registry, log: log, source: "Settings › Replace Key")
  }

  func cancelReplace() { replace = nil }

  /// After the inline form saves.
  func replaceFinished() {
    replace = nil
    reload()
  }

  // MARK: Validate Now

  func validateNow() async {
    guard let availability, let key = (try? keyStore.read()).flatMap({ $0 }), !key.isEmpty else { return }
    validation = .validating
    switch await availability.validateKey(key) {
    case .valid(let count, let flashListed):
      validation = .valid(
        flashListed
          ? "Valid · \(count) models"
          : "Valid · \(count) models · \(OnboardingModel.flashWarning)")
    case .rejected(let message, _):
      validation = .problem("Key rejected: \(message)")
    case .unreachable(let message):
      validation = .problem("Couldn't reach Google: \(message)")
    }
  }

  // MARK: Remove Key

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
