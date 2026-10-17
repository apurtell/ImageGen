import Foundation
import Observation

/// Presentation model driving application settings, including model catalog availability,
/// generation defaults, image ingestion parameters, system notifications, and storage reclamation.
///
/// Dispatches file system aggregations and deletions off the main actor via utility tasks,
/// recording paired telemetry for configuration changes.
@Observable @MainActor
final class SettingsModel {
  /// Dependency container providing access to underlying services, storage actors, and transports.
  struct Services {
    var settings: AppSettings
    var keyStore: any APIKeyStore
    var availability: ModelAvailabilityService
    var modelsClient: ModelsClient
    var store: DataStore
    var files: FileStore
    var thumbnails: ThumbnailService
    var generation: any GenerationServicing
    var log: ActivityLog
    var navigator: Navigator
    /// Closure querying current system notification authorization status.
    var notificationStatus: @Sendable () async -> String
  }

  /// Categorization of model availability based on cached catalog metadata.
  enum Availability: Equatable {
    case available, notListed, unknown

    var label: String {
      switch self {
      case .available: "Available"
      case .notListed: "Not listed for this key"
      case .unknown: "Unknown — not checked"
      }
    }
  }

  /// Outcome of custom model identifier validation and registration attempts.
  enum CustomModelResult: Equatable {
    case added
    case invalid(String)
    case rejected(String)
  }

  @ObservationIgnored let services: Services
  var settings: AppSettings { services.settings }

  /// Aggregated disk consumption metrics across image, staging, and thumbnail directories.
  private(set) var sizes = FileStore.Sizes()
  private(set) var notificationStatus = "notDetermined"
  private(set) var isRefreshingModels = false
  /// Guard flag ensuring custom model validation operations execute strictly sequentially.
  private(set) var isAddingModel = false
  private(set) var toast: String?
  @ObservationIgnored private var toastTask: Task<Void, Never>?

  init(services: Services) {
    self.services = services
  }

  private var log: ActivityLog { services.log }

  /// Records atomic configuration changes in activity logs before executing local mutation closures.
  private func change(_ name: String, _ old: String, _ new: String, apply: () -> Void) {
    guard old != new else { return }
    let action = log.begin("Settings change", origin: .user, "\(name) \(old) → \(new)")
    apply()
    log.result(action, .success, "saved")
  }

  private static func onOff(_ b: Bool) -> String { b ? "on" : "off" }

  /// Built-in catalog models excluding the mandatory default model.
  var toggleableModels: [ModelDescriptor] {
    ModelCatalog.builtIns.filter { $0.id != ModelCatalog.defaultModelID }
  }

  /// Unknown until a models list was cached. After that, a model missing from the list is "Not
  /// Evaluates model availability based on cached remote catalog records.
  func availability(_ id: String) -> Availability {
    guard let cache = settings.modelAvailabilityCache else { return .unknown }
    return cache.models[id] == true ? .available : .notListed
  }

  var lastChecked: Date? { settings.modelAvailabilityCache?.checkedAt }

  func isEnabled(_ id: String) -> Bool { settings.enabledModelIDs.contains(id) }

  func setEnabled(_ id: String, _ on: Bool) {
    // Preserve default model enablement invariants.
    guard id != ModelCatalog.defaultModelID else { return }
    let name = ModelCatalog.descriptor(for: id).shortName
    change("model \(name)", Self.onOff(isEnabled(id)), Self.onOff(on)) { settings.setModel(id, enabled: on) }
  }

  /// Triggers asynchronous model catalog availability synchronization.
  func refreshModels() async {
    isRefreshingModels = true
    defer { isRefreshingModels = false }
    _ = await services.availability.refresh(reason: .manual)
  }

  /// Validates candidate custom model identifier against remote endpoints and registers valid entries.
  func addCustomModel(_ raw: String) async -> CustomModelResult {
    guard !isAddingModel else { return .invalid("Checking the previous model…") }
    var id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if id.hasPrefix("models/") { id.removeFirst("models/".count) }
    guard !id.isEmpty else { return .invalid("Enter a model ID.") }
    guard id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-._".contains($0)) }) else {
      return .invalid("Model IDs use letters, digits, “-”, “.” and “_”.")
    }
    guard !ModelCatalog.builtIns.contains(where: { $0.id == id }), !settings.customModelIDs.contains(id) else {
      return .invalid("That model is already in the list.")
    }
    isAddingModel = true
    defer { isAddingModel = false }
    let action = log.begin("Add custom model", origin: .user, "\(private: id) · GET /v1beta/models/{id}")
    guard let key = try? services.keyStore.read(), !key.isEmpty else {
      log.result(action, .failed, "no API key · not added")
      return .rejected("Add an API key first.")
    }
    do {
      let info = try await services.modelsClient.getModel(id: id, apiKey: key)
      guard info.supportsGenerateContent else {
        log.result(action, .failed, "HTTP 200 · no generateContent · not added")
        return .rejected("This model doesn't support image generation (generateContent).")
      }
      if !settings.customModelIDs.contains(id) { settings.customModelIDs.append(id) }
      log.result(action, .success, "HTTP 200 · added")
      return .added
    } catch ModelsClientError.notFound {
      log.result(action, .failed, "HTTP 404 · not added")
      return .rejected("Google doesn't know this model for your key.")
    } catch {
      let text = ModelAvailabilityService.describe(error)
      log.result(action, .failed, "not added: \(private: text)")
      return .rejected(text)
    }
  }

  /// Deletes a registered custom model identifier and logs the configuration change.
  func removeCustomModel(_ id: String) {
    let action = log.begin("Settings change", origin: .user, "custom model \(private: id) removed")
    settings.customModelIDs.removeAll { $0 == id }
    log.result(action, .success, "saved")
  }

  func setDefaultAspect(_ r: AspectRatio) {
    change("default aspect ratio", settings.defaultAspectRatio.rawValue, r.rawValue) { settings.defaultAspectRatio = r }
  }

  func setDefaultSize(_ s: ImageSize) {
    change("default resolution", settings.defaultImageSize.rawValue, s.rawValue) { settings.defaultImageSize = s }
  }

  func setThreshold(_ t: SafetyThreshold) {
    change("safety threshold", settings.safetyThreshold.displayName, t.displayName) { settings.safetyThreshold = t }
  }

  func setMaxLongEdge(_ e: Int) {
    change("max long edge", "\(settings.maxUploadLongEdge)", "\(e)") { settings.maxUploadLongEdge = e }
  }

  func setIncludeText(_ on: Bool) {
    change("request text alongside images", Self.onOff(settings.includeTextModality), Self.onOff(on)) {
      settings.includeTextModality = on
    }
  }

  func setOmitCivic(_ on: Bool) {
    change("omit CIVIC_INTEGRITY", Self.onOff(settings.omitCivicIntegrity), Self.onOff(on)) {
      settings.omitCivicIntegrity = on
    }
  }

  func setNotify(_ on: Bool) {
    change("notify on background completion", Self.onOff(settings.notifyOnBackgroundCompletion), Self.onOff(on)) {
      settings.notifyOnBackgroundCompletion = on
    }
  }

  /// Queries system notification authorization status.
  func refreshNotificationStatus() async {
    notificationStatus = await services.notificationStatus()
  }

  var notificationStatusText: String {
    switch notificationStatus {
    case "authorized": "Allowed"
    case "provisional", "ephemeral": "Allowed quietly"
    case "denied": "Off in system Settings"
    default: "Not asked yet"
    }
  }

  var totalBytes: Int64 { sizes.images + sizes.requests + sizes.staging + sizes.thumbnails }

  /// Measures disk consumption across application directories on a background utility queue.
  func refreshSizes() async {
    let files = services.files
    sizes = await Task.detached(priority: .utility) { files.sizes() }.value
  }

  /// Purges in-memory and on-disk thumbnail caches, prompting regeneration upon subsequent access.
  func clearThumbnailCache() async {
    let files = services.files
    let dir = files.thumbnailsDir
    let before = await Task.detached(priority: .utility) { FileStore.usage(of: dir) }.value
    let action = log.begin(
      "Clear thumbnail cache", origin: .user, "\(before.count) files · \(Format.mb(Int(before.bytes)))")
    await services.thumbnails.removeFromMemory()
    let result = await Task.detached(priority: .utility) { () -> DeletionResult in
      var r = DeletionResult()
      let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
      for item in items { files.remove(item, into: &r) }
      return r
    }.value
    let removed = "removed \(result.filesRemoved) · \(Format.mb(Int(result.bytesFreed))) freed"
    if result.failures == 0 {
      log.result(action, .success, "\(removed)")
    } else {
      log.result(action, .failed, "\(removed) · \(result.failures) failed: \(result.firstError ?? "unknown")")
    }
    show("Thumbnail cache cleared")
    await refreshSizes()
  }

  /// Cancels in-flight generation requests and deletes all conversations, image assets, and thumbnails.
  func deleteAllChats() async {
    let store = services.store
    let inventory = (try? await store.inventory()) ?? (chats: 0, images: 0)
    let live = (try? await store.nonTerminalRequests()) ?? []
    let action = log.begin(
      "Delete all chats", origin: .user,
      "\(inventory.chats) chat\(inventory.chats == 1 ? "" : "s") · \(inventory.images) image\(inventory.images == 1 ? "" : "s") · \(Format.mb(Int(sizes.images + sizes.requests))) · \(live.count) live request\(live.count == 1 ? "" : "s") to cancel"
    )
    for request in live { await services.generation.cancel(requestID: request.id) }
    do {
      var r = try await store.deleteAll()
      // Terminate any newly scheduled requests created concurrently during deletion dispatch.
      let cancelled = Set(live.map(\.id))
      for id in r.liveRequestIDs where !cancelled.contains(id) { await services.generation.cancel(requestID: id) }
      let files = services.files
      let thumbs = await Task.detached(priority: .utility) { () -> DeletionResult in
        var t = DeletionResult()
        let items = (try? FileManager.default.contentsOfDirectory(at: files.thumbnailsDir, includingPropertiesForKeys: nil)) ?? []
        for item in items { files.remove(item, into: &t) }
        return t
      }.value
      r.filesRemoved += thumbs.filesRemoved
      r.bytesFreed += thumbs.bytesFreed
      r.failures += thumbs.failures
      r.firstError = r.firstError ?? thumbs.firstError
      let removed =
        "chats removed \(inventory.chats) · files removed \(r.filesRemoved) (\(Format.mb(Int(r.bytesFreed))) freed) · thumbnails cleared"
      if r.failures == 0 {
        log.result(action, .success, "\(removed)")
      } else {
        log.result(action, .failed, "\(removed) · \(r.failures) failed: \(r.firstError ?? "unknown")")
      }
    } catch {
      log.result(action, .failed, "\(error.localizedDescription)")
    }
    // Unwind navigation stack to root conversation list to prevent viewing invalid deleted sessions.
    services.navigator.path = []
    await services.thumbnails.removeFromMemory()
    show("All chats deleted")
    await refreshSizes()
  }

  /// Displays a transient informational toast message for a standard display duration.
  func show(_ text: String) {
    toast = text
    toastTask?.cancel()
    toastTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(2))
      guard !Task.isCancelled else { return }
      self?.toast = nil
    }
  }
}
