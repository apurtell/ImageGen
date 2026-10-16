import Foundation

/// Which models the key can use (D§2.5): checked when a key is saved, on foreground at most every
/// 24 h, and on pull to refresh. Results are cached in `AppSettings`. Each run is logged.
@MainActor
final class ModelAvailabilityService {
  enum Reason: String, Sendable {
    case keySaved = "key saved"
    case foreground = "foreground check"
    case manual = "manual check"
  }

  enum RefreshOutcome: Sendable, Equatable {
    case refreshed(modelCount: Int, flashListed: Bool)
    case noKey
    case failed(String)
  }

  enum KeyValidation: Sendable, Equatable {
    case valid(modelCount: Int, flashListed: Bool)
    /// The API message, and the `ErrorInfo` reason when there is one (`API_KEY_INVALID`).
    case rejected(String, reason: String?)
    case unreachable(String)
  }

  static let staleAfter: TimeInterval = 24 * 3600
  static let listPath = "GET /v1beta/models?pageSize=1000"

  private let client: ModelsClient
  private let keyStore: any APIKeyStore
  private let settings: AppSettings
  private let log: ActivityLog
  private let registry: SecretRegistry
  private let clock: @Sendable () -> Date

  init(
    client: ModelsClient, keyStore: any APIKeyStore, settings: AppSettings, log: ActivityLog, registry: SecretRegistry,
    clock: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.client = client
    self.keyStore = keyStore
    self.settings = settings
    self.log = log
    self.registry = registry
    self.clock = clock
  }

  /// Refreshes on foreground only when the last check is more than 24 h old (or there's none).
  func refreshIfStale() async {
    if let checked = settings.modelAvailabilityCache?.checkedAt, clock().timeIntervalSince(checked) < Self.staleAfter {
      return
    }
    _ = await refresh(reason: .foreground)
  }

  func refresh(reason: Reason) async -> RefreshOutcome {
    let started = ContinuousClock.now
    let action = log.begin(
      "Models refresh", origin: reason == .foreground ? .system : .user,
      "reason \(reason.rawValue) · \(Self.listPath)")
    guard let key = try? keyStore.read(), !key.isEmpty else {
      log.result(action, .failed, "no API key")
      return .noKey
    }
    do {
      let (models, pages) = try await client.listAll(apiKey: key)
      let changes = store(models)
      let flash = ModelsClient.flashListed(models)
      log.result(
        action, .success,
        "in \(Format.seconds(ContinuousClock.now - started)) · \(pages) page\(pages == 1 ? "" : "s") · \(models.count) models · Flash \(flash ? "listed" : "not listed") · \(changes)"
      )
      return .refreshed(modelCount: models.count, flashListed: flash)
    } catch {
      let text = Self.describe(error)
      log.result(action, .failed, "in \(Format.seconds(ContinuousClock.now - started)) · \(private: text)")
      return .failed(text)
    }
  }

  /// Checks a typed key before it's saved (onboarding, Validate Now). The key is registered as a
  /// secret first, so nothing that echoes it can reach the log.
  func validateKey(_ key: String, parent: ActionID? = nil) async -> KeyValidation {
    registry.register(key)
    let started = ContinuousClock.now
    let message: ActivityMessage = "\(Self.listPath) · ephemeral session · 20 s timeout"
    let action =
      parent.map { log.begin("Validate key", parent: $0, message) } ?? log.begin("Validate key", origin: .user, message)
    do {
      let (models, _) = try await client.listAll(apiKey: key)
      _ = store(models)
      let flash = ModelsClient.flashListed(models)
      log.result(
        action, .success,
        "in \(Format.seconds(ContinuousClock.now - started)) · HTTP 200 · \(models.count) models · Flash \(flash ? "listed" : "not listed")"
      )
      return .valid(modelCount: models.count, flashListed: flash)
    } catch ModelsClientError.keyRejected(let status, let apiStatus, let reason, let text) {
      log.result(
        action, .failed,
        "in \(Format.seconds(ContinuousClock.now - started)) · key rejected · HTTP \(status)\(apiStatus.map { " \($0)" } ?? "")\(reason.map { " \($0)" } ?? ""): \(private: Redactor.errorBodyForLog(text))"
      )
      return .rejected(text, reason: reason)
    } catch {
      let text = Self.describe(error)
      log.result(action, .failed, "in \(Format.seconds(ContinuousClock.now - started)) · unreachable: \(private: text)")
      return .unreachable(text)
    }
  }

  /// Caches availability and describes what changed for the catalog models.
  private func store(_ models: [ModelInfo]) -> String {
    let now = Dictionary(models.map { ($0.id, $0.supportsGenerateContent) }, uniquingKeysWith: { a, b in a || b })
    let before = settings.modelAvailabilityCache?.models
    settings.modelAvailabilityCache = ModelAvailabilityCache(models: now, checkedAt: clock())
    let changes = ModelCatalog.builtIns.compactMap { m -> String? in
      let listed = now[m.id] == true
      guard let before else { return "\(m.shortName) \(listed ? "listed" : "not listed")" }
      let was = before[m.id] == true
      return was == listed ? nil : "\(m.shortName) \(was ? "listed" : "not listed") → \(listed ? "listed" : "not listed")"
    }
    return changes.isEmpty ? "no changes" : changes.joined(separator: ", ")
  }

  static func describe(_ error: any Error) -> String {
    switch error {
    case ModelsClientError.unreachable(let why): "couldn't reach Google (\(why))"
    case ModelsClientError.keyRejected(let status, _, _, let message): "key rejected (HTTP \(status)): \(message)"
    case ModelsClientError.notFound(let message): "not found: \(message)"
    case ModelsClientError.http(let status, let message): "HTTP \(status): \(message)"
    case ModelsClientError.malformed: "unexpected response"
    default: error.localizedDescription
    }
  }
}
