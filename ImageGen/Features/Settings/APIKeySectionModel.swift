import Foundation
import Observation

/// Presentation model driving the API Key section in Settings, managing credential status display,
/// on-demand remote verification, credential replacement forms, and key revocation.
///
/// Ensures stale asynchronous verification results are discarded if concurrent modifications
/// occur via generation run counters and identity checks.
@Observable @MainActor
final class APIKeySectionModel {
  /// User-facing state of the on-demand credential verification workflow.
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
  /// Suffix of the currently saved API credential for non-sensitive identification, or nil if unconfigured.
  private(set) var lastFour: String?
  private(set) var validation = ValidationState.idle
  /// Active credential replacement presentation model when the inline replacement interface is open.
  private(set) var replace: OnboardingModel?
  /// Generation token incremented on each state mutation to invalidate in-flight validation responses.
  @ObservationIgnored private var validationRun = 0

  init(keyStore: any APIKeyStore, log: ActivityLog, availability: ModelAvailabilityService? = nil, registry: SecretRegistry? = nil) {
    self.keyStore = keyStore
    self.log = log
    self.availability = availability
    self.registry = registry
    reload()
  }

  var hasKey: Bool { lastFour != nil }

  /// Formatted credential status description.
  var statusText: String { lastFour.map { "Saved (…\($0))" } ?? "Not set" }

  /// Reloads credential state from secure Keychain storage.
  func reload() {
    lastFour = (try? keyStore.read()).flatMap { $0 }.map { String($0.suffix(4)) }
  }

  func beginReplace() {
    guard let availability, let registry else { return }
    // A Validate Now still running describes the key that is about to be replaced: drop its result.
    validationRun += 1
    validation = .idle
    replace = OnboardingModel(
      keyStore: keyStore, availability: availability, registry: registry, log: log, source: "Settings › Replace Key")
  }

  /// Cancels inline credential replacement and dismisses the input form.
  func cancelReplace() {
    replace?.cancel()
    replace = nil
  }

  /// Concludes credential replacement following successful verification and storage.
  func replaceFinished() {
    replace = nil
    reload()
  }

  /// Dispatches on-demand remote verification for the currently stored credential.
  func validateNow() async {
    guard let availability, let key = (try? keyStore.read()).flatMap({ $0 }), !key.isEmpty else { return }
    // Increment generation token to isolate this validation pass from subsequent user actions.
    validationRun += 1
    let run = validationRun
    validation = .validating
    let result = await availability.validateKey(key)
    // Verify run token and credential identity post-suspension to discard stale validation outcomes.
    guard run == validationRun else { return }
    guard (try? keyStore.read()).flatMap({ $0 }) == key else {
      validation = .idle
      return
    }
    switch result {
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

  /// Removes stored API credentials from secure storage and invalidates pending verifications.
  @discardableResult
  func removeKey() -> Bool {
    let action = log.begin("Remove API key", origin: .user, "Settings")
    do {
      try keyStore.delete()
      log.result(action, .success, "Keychain status ok · key removed")
      lastFour = nil
      // Invalidate running validation attempts for the revoked credential.
      validationRun += 1
      validation = .idle
      return true
    } catch {
      log.result(action, .failed, "Keychain: \(error.localizedDescription)")
      return false
    }
  }
}
