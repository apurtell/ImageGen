import Foundation

/// Coordinates model discovery and API credential validation. Queries available upstream models
/// when credentials change, periodically on foreground activation (24-hour cadence), or on explicit user request.
/// Discovered model metadata is persisted in `AppSettings` to configure model selection menus.
///
/// Execution is pinned to the `@MainActor` to serialize settings updates that drive UI state.
/// Monotonically increasing run identifiers guard against out-of-order storage when overlapping network requests complete.
@MainActor
final class ModelAvailabilityService {
  enum Reason: String, Sendable {
    case keySaved = "key saved"
    case foreground = "foreground check"
    case manual = "manual check"
  }

  /// Outcome of a model catalog discovery operation.
  enum RefreshOutcome: Sendable, Equatable {
    case refreshed(modelCount: Int, flashListed: Bool)
    case noKey
    case failed(String)
  }

  /// Credential validation outcome evaluated against the upstream Gemini models endpoint.
  enum KeyValidation: Sendable, Equatable {
    case valid(modelCount: Int, flashListed: Bool)
    /// Upstream error message accompanied by structured error code when available (e.g., `API_KEY_INVALID`).
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
  /// Monotonically increasing run identifier ensuring out-of-order asynchronous responses do not overwrite fresher results.
  private var runsStarted = 0
  private var newestStored = 0

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

  /// Initiates model discovery on foreground activation if the cached catalog is absent or exceeds the staleness threshold.
  /// Bypasses execution silently if no API key is configured.
  func refreshIfStale() async {
    guard let key = try? keyStore.read(), !key.isEmpty else { return }
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
    // Allocate run identifier prior to network suspension to preserve invocation ordering.
    let run = startRun()
    do {
      let (models, pages) = try await client.listAll(apiKey: key)
      let changes = store(models, run: run, key: key) ?? "superseded by a newer check · not stored"
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

  /// Validates uncommitted API credentials prior to persistence, ensuring credentials are first registered with
  /// the secret redaction registry to prevent accidental log exposure.
  func validateKey(_ key: String, parent: ActionID? = nil) async -> KeyValidation {
    registry.register(key)
    let started = ContinuousClock.now
    let message: ActivityMessage = "\(Self.listPath) · ephemeral session · 20 s timeout"
    let action =
      parent.map { log.begin("Validate key", parent: $0, message) } ?? log.begin("Validate key", origin: .user, message)
    let run = startRun()
    do {
      let (models, _) = try await client.listAll(apiKey: key)
      // Catalog caching applies only if the key has been committed to permanent storage.
      _ = store(models, run: run, key: key)
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

  private func startRun() -> Int {
    runsStarted += 1
    return runsStarted
  }

  /// Commits discovered model availability to application settings and formats differential telemetry.
  /// Returns nil if the pass was superseded by a later invocation or if the stored key changed.
  private func store(_ models: [ModelInfo], run: Int, key: String) -> String? {
    guard run > newestStored, (try? keyStore.read()).flatMap({ $0 }) == key else { return nil }
    newestStored = run
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

  /// Produces a human-readable diagnostic description from an underlying error.
  static func describe(_ error: any Error) -> String {
    switch error {
    case ModelsClientError.unreachable(let why): "couldn't reach Google (\(why))"
    case ModelsClientError.keyRejected(let status, _, _, let message): "key rejected (HTTP \(status)): \(message)"
    case ModelsClientError.notFound(let message): "not found: \(message)"
    case ModelsClientError.http(let status, let message): "HTTP \(status): \(message)"
    case ModelsClientError.malformed: "unexpected response"
    case is CancellationError: "cancelled"
    default: error.localizedDescription
    }
  }
}
