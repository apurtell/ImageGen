import Foundation
import Observation

/// Settings (D§3.8) other than the API key: models, generation defaults, uploads, advanced,
/// notifications and storage. Every control logs a Settings change with old → new (D§4.13).
@Observable @MainActor
final class SettingsModel {
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
    /// The notification authorization status, by name ("authorized", "denied", …).
    var notificationStatus: @Sendable () async -> String
  }

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

  enum CustomModelResult: Equatable {
    case added
    case invalid(String)
    case rejected(String)
  }

  @ObservationIgnored let services: Services
  var settings: AppSettings { services.settings }

  private(set) var sizes = FileStore.Sizes()
  private(set) var notificationStatus = "notDetermined"
  private(set) var isRefreshingModels = false
  private(set) var isAddingModel = false
  private(set) var toast: String?
  @ObservationIgnored private var toastTask: Task<Void, Never>?

  init(services: Services) {
    self.services = services
  }

  private var log: ActivityLog { services.log }

  // MARK: Settings change

  /// Logs one change as a paired Settings change, then applies it.
  private func change(_ name: String, _ old: String, _ new: String, apply: () -> Void) {
    guard old != new else { return }
    let action = log.begin("Settings change", origin: .user, "\(name) \(old) → \(new)")
    apply()
    log.result(action, .success, "saved")
  }

  private static func onOff(_ b: Bool) -> String { b ? "on" : "off" }

  // MARK: Models

  /// Catalog models other than Flash, each with a toggle (D§3.8).
  var toggleableModels: [ModelDescriptor] {
    ModelCatalog.builtIns.filter { $0.id != ModelCatalog.defaultModelID }
  }

  func availability(_ id: String) -> Availability {
    guard let cache = settings.modelAvailabilityCache else { return .unknown }
    return cache.models[id] == true ? .available : .notListed
  }

  var lastChecked: Date? { settings.modelAvailabilityCache?.checkedAt }

  func isEnabled(_ id: String) -> Bool { settings.enabledModelIDs.contains(id) }

  func setEnabled(_ id: String, _ on: Bool) {
    guard id != ModelCatalog.defaultModelID else { return }
    let name = ModelCatalog.descriptor(for: id).shortName
    change("model \(name)", Self.onOff(isEnabled(id)), Self.onOff(on)) { settings.setModel(id, enabled: on) }
  }

  /// Pull to refresh.
  func refreshModels() async {
    isRefreshingModels = true
    defer { isRefreshingModels = false }
    _ = await services.availability.refresh(reason: .manual)
  }

  /// A custom ID, validated with `GET v1beta/models/{id}` before it's added (D§3.8). The ID is
  /// logged as private.
  func addCustomModel(_ raw: String) async -> CustomModelResult {
    // Return in the field submits again while the first check runs; one check at a time.
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
      // Checked again: the list may have changed while the model was looked up.
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

  func removeCustomModel(_ id: String) {
    let action = log.begin("Settings change", origin: .user, "custom model \(private: id) removed")
    settings.customModelIDs.removeAll { $0 == id }
    log.result(action, .success, "saved")
  }

  // MARK: Generation defaults, uploads, advanced, notifications

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

  // MARK: Storage

  var totalBytes: Int64 { sizes.images + sizes.requests + sizes.staging + sizes.thumbnails }

  func refreshSizes() async {
    let files = services.files
    sizes = await Task.detached(priority: .utility) { files.sizes() }.value
  }

  func clearThumbnailCache() async {
    let files = services.files
    let dir = files.thumbnailsDir
    let before = FileStore.usage(of: dir)
    let action = log.begin(
      "Clear thumbnail cache", origin: .user, "\(before.count) files · \(Format.mb(Int(before.bytes)))")
    await services.thumbnails.removeFromMemory()
    let result = await Task.detached(priority: .utility) { () -> DeletionResult in
      var r = DeletionResult()
      // No thumbnail folder yet means nothing to clear.
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

  /// Delete All Chats: cancels live requests, then deletes every chat and its files.
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
      // A request recorded after the list above was read (a send that was on its way) is stopped too.
      let cancelled = Set(live.map(\.id))
      for id in r.liveRequestIDs where !cancelled.contains(id) { await services.generation.cancel(requestID: id) }
      // Their thumbnails go too.
      let files = services.files
      let thumbs = await Task.detached(priority: .utility) { () -> DeletionResult in
        var t = DeletionResult()
        // No thumbnail folder yet means nothing to clear.
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
    services.navigator.path = []
    await services.thumbnails.removeFromMemory()
    show("All chats deleted")
    await refreshSizes()
  }

  // MARK: Toast

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
