import Foundation
import Observation

/// Settings › API Key (D§3.8): status, Replace Key (the onboarding form inline), Validate Now and
/// Remove Key. Replace and Remove reuse the Save API key and Remove API key actions.
///
/// `AppEnvironment` builds one each time the Settings sheet opens; `APIKeySection` draws it. It
/// reads and changes the key through `APIKeyStore`, and checks it with `ModelAvailabilityService`.
/// Replace Key delegates to an `OnboardingModel`, which does its own validation and saving.
///
/// Concurrency: `@MainActor`. Only Validate Now awaits (the network check). While it waits, the
/// user can tap Replace Key or Remove Key, which change the saved key. So a check's result is shown
/// only if no newer key operation happened meanwhile (`validationRun`) and the saved key is still the
/// key that was checked. A dropped result writes nothing to the screen.
@Observable @MainActor
final class APIKeySectionModel {
  /// The Validate Now line. `valid` and `problem` carry the text to show.
  enum ValidationState: Equatable {
    case idle
    case validating
    case valid(String)
    case problem(String)
  }

  private let keyStore: any APIKeyStore
  private let log: ActivityLog
  /// Optional so that tests can build a model without them. Without both, Replace Key does nothing,
  /// and without `availability` Validate Now does nothing.
  private let availability: ModelAvailabilityService?
  private let registry: SecretRegistry?
  /// The last 4 characters of the saved key, or nil when there is none. The full key is never kept
  /// here and never shown (D§3.2).
  private(set) var lastFour: String?
  private(set) var validation = ValidationState.idle
  /// The inline Replace Key form, while it's open. While it is open, the section hides Validate Now
  /// and Remove Key.
  private(set) var replace: OnboardingModel?
  /// Bumped by each Validate Now, Replace Key and Remove Key: a validation's result is shown only
  /// if nothing newer happened while it ran (it would describe a key that's no longer saved).
  @ObservationIgnored private var validationRun = 0

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

  /// Reads the Keychain again for the status line.
  func reload() {
    lastFour = (try? keyStore.read()).flatMap { $0 }.map { String($0.suffix(4)) }  // try?: an unreadable Keychain shows "Not set".
  }

  // MARK: Replace Key

  func beginReplace() {
    guard let availability, let registry else { return }
    // A Validate Now still running describes the key that is about to be replaced: drop its result.
    validationRun += 1
    validation = .idle
    replace = OnboardingModel(
      keyStore: keyStore, availability: availability, registry: registry, log: log, source: "Settings › Replace Key")
  }

  /// Cancel on the form. The form's model is told first, so a validation still running in it
  /// saves nothing when it resumes (D§3.2).
  func cancelReplace() {
    replace?.cancel()
    replace = nil
  }

  /// After the inline form saves.
  func replaceFinished() {
    replace = nil
    reload()
  }

  // MARK: Validate Now

  /// Checks the saved key with the service. The button is disabled while a check runs, so there is
  /// one check at a time from this screen.
  func validateNow() async {
    guard let availability, let key = (try? keyStore.read()).flatMap({ $0 }), !key.isEmpty else { return }  // try?: no readable key means nothing to check.
    // This run's number. Any later Validate Now, Replace Key or Remove Key changes `validationRun`.
    validationRun += 1
    let run = validationRun
    validation = .validating
    let result = await availability.validateKey(key)
    // Snapshot, then check again (see the primer, *Patterns used in this project*): after the
    // `await`, show the result only if this is still the newest run and the same key is saved.
    // When the run changed, the newer operation has already set `validation`; returning keeps it.
    guard run == validationRun else { return }
    guard (try? keyStore.read()).flatMap({ $0 }) == key else {  // try?: an unreadable key counts as changed.
      // The key changed some other way: this result describes no saved key, so show none.
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

  // MARK: Remove Key

  /// Remove Key. Returns true when the key is gone (onboarding follows).
  /// The caller (`APIKeySection`) then closes Settings and shows onboarding.
  @discardableResult
  func removeKey() -> Bool {
    let action = log.begin("Remove API key", origin: .user, "Settings")
    do {
      try keyStore.delete()
      log.result(action, .success, "Keychain status ok · key removed")
      lastFour = nil
      // A check still running described the removed key: drop its result.
      validationRun += 1
      validation = .idle
      return true
    } catch {
      log.result(action, .failed, "Keychain: \(error.localizedDescription)")
      return false
    }
  }
}
