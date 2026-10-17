import Foundation
import Observation

/// Settings (D§3.8) other than the API key: models, generation defaults, uploads, advanced,
/// notifications and storage. Every control logs a Settings change with old → new (D§4.13).
///
/// `AppEnvironment.settingsModel()` builds one each time the Settings sheet opens. The views in
/// `SettingsView.swift` and `ModelsSettingsView.swift` read it and call it. Most settings live in
/// `AppSettings` (saved to UserDefaults), and this model only logs and applies each change. The
/// storage actions call `DataStore`, `FileStore`, `ThumbnailService` and the generation service.
///
/// Concurrency: `@MainActor`, so property changes and log calls happen in the order the user acts.
/// Slow file work (sizes, deletes) runs in `Task.detached` at utility priority, so the main thread
/// stays free. The async actions (refresh, add model, clear, delete all) can each be in progress at
/// the same time as other controls; the comments at each `await` say what is checked again after it.
@Observable @MainActor
final class SettingsModel {
  /// The dependencies, in one struct, so that tests can supply fakes (see the primer, *Seams for
  /// tests*).
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

  /// A model's status from the cached models list, as the Models page shows it.
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

  /// The outcome of Add, with the message to show. `invalid`: the input was refused before any
  /// network call. `rejected`: the service refused the model, or the check failed.
  enum CustomModelResult: Equatable {
    case added
    case invalid(String)
    case rejected(String)
  }

  @ObservationIgnored let services: Services
  var settings: AppSettings { services.settings }

  /// The folder sizes for the Storage section. Zero until the first `refreshSizes()`.
  private(set) var sizes = FileStore.Sizes()
  private(set) var notificationStatus = "notDetermined"
  private(set) var isRefreshingModels = false
  /// True while one custom model check runs. It is the lock that keeps checks one at a time.
  private(set) var isAddingModel = false
  private(set) var toast: String?
  @ObservationIgnored private var toastTask: Task<Void, Never>?

  init(services: Services) {
    self.services = services
  }

  private var log: ActivityLog { services.log }

  // MARK: Settings change

  /// Logs one change as a paired Settings change, then applies it.
  /// Each change is one action: Begin, apply, Result, with no `await`, so the pair cannot interleave
  /// with another change.
  private func change(_ name: String, _ old: String, _ new: String, apply: () -> Void) {
    // A control can set the value it already has (for example, a picker re-selects): log nothing.
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

  /// Unknown until a models list was cached. After that, a model missing from the list is "Not
  /// listed".
  func availability(_ id: String) -> Availability {
    guard let cache = settings.modelAvailabilityCache else { return .unknown }
    return cache.models[id] == true ? .available : .notListed
  }

  var lastChecked: Date? { settings.modelAvailabilityCache?.checkedAt }

  func isEnabled(_ id: String) -> Bool { settings.enabledModelIDs.contains(id) }

  func setEnabled(_ id: String, _ on: Bool) {
    // The default model cannot be turned off (D§3.8).
    guard id != ModelCatalog.defaultModelID else { return }
    let name = ModelCatalog.descriptor(for: id).shortName
    change("model \(name)", Self.onOff(isEnabled(id)), Self.onOff(on)) { settings.setModel(id, enabled: on) }
  }

  /// Pull to refresh, and the Check Now button. The service logs its own Models refresh action and
  /// updates the cache in `AppSettings`, which the views read.
  func refreshModels() async {
    isRefreshingModels = true
    // `defer` clears the flag when the function exits, on every path.
    defer { isRefreshingModels = false }
    _ = await services.availability.refresh(reason: .manual)
  }

  /// A custom ID, validated with `GET v1beta/models/{id}` before it's added (D§3.8). The ID is
  /// logged as private.
  func addCustomModel(_ raw: String) async -> CustomModelResult {
    // Return in the field submits again while the first check runs; one check at a time.
    // The check and the set below have no `await` between them, so on the main actor no second
    // call can pass this guard before the flag is set.
    guard !isAddingModel else { return .invalid("Checking the previous model…") }
    var id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if id.hasPrefix("models/") { id.removeFirst("models/".count) }
    guard !id.isEmpty else { return .invalid("Enter a model ID.") }
    // The ID goes into a URL path, so only safe characters are allowed.
    guard id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-._".contains($0)) }) else {
      return .invalid("Model IDs use letters, digits, “-”, “.” and “_”.")
    }
    guard !ModelCatalog.builtIns.contains(where: { $0.id == id }), !settings.customModelIDs.contains(id) else {
      return .invalid("That model is already in the list.")
    }
    isAddingModel = true
    defer { isAddingModel = false }
    // From here on, every return writes this action's Result.
    let action = log.begin("Add custom model", origin: .user, "\(private: id) · GET /v1beta/models/{id}")
    guard let key = try? services.keyStore.read(), !key.isEmpty else {  // try?: an unreadable key is the same as no key.
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

  /// Swipe to delete on a custom ID. No check is needed, so it is synchronous.
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

  /// Reads the system's authorization status. It runs each time the sheet opens, because the user
  /// can change it in the system Settings at any time.
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

  /// Walks the folders off the main thread, then writes `sizes` back on the main actor.
  func refreshSizes() async {
    // `FileStore` is a `Sendable` struct, copied into the detached task. `self` stays on the main
    // actor; the task needs only the copy.
    let files = services.files
    // `Task.detached` has no actor, so the folder walk runs on a background thread. `.value` waits
    // for its result; the assignment then runs on the main actor again.
    sizes = await Task.detached(priority: .utility) { files.sizes() }.value
  }

  /// Clear Thumbnail Cache: empties the memory cache, then deletes the thumbnail files. Thumbnails
  /// are made again from the images when a view next needs them.
  func clearThumbnailCache() async {
    let files = services.files
    let dir = files.thumbnailsDir
    // The size before, for the log. This walk of the folder runs on the main thread.
    let before = FileStore.usage(of: dir)
    let action = log.begin(
      "Clear thumbnail cache", origin: .user, "\(before.count) files · \(Format.mb(Int(before.bytes)))")
    // Memory first, so that a view does not draw a cached thumbnail whose file is gone.
    await services.thumbnails.removeFromMemory()
    // `remove(_:into:)` takes the result as `inout`: each call adds its counts to `r`.
    let result = await Task.detached(priority: .utility) { () -> DeletionResult in
      var r = DeletionResult()
      let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []  // try?: no thumbnail folder yet means nothing to clear.
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
  ///
  /// The order matters. Live requests are cancelled first, so that they stop before their chats and
  /// folders are deleted. Each `await` here lets other code run, so a send can record a new request
  /// after the list is read; `deleteAll()` returns those too, and they are cancelled after.
  func deleteAllChats() async {
    let store = services.store
    let inventory = (try? await store.inventory()) ?? (chats: 0, images: 0)  // try?: the counts are only for the log.
    let live = (try? await store.nonTerminalRequests()) ?? []  // try?: requests missed here are cancelled after `deleteAll()`.
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
        let items = (try? FileManager.default.contentsOfDirectory(at: files.thumbnailsDir, includingPropertiesForKeys: nil)) ?? []  // try?: no thumbnail folder yet means nothing to clear.
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
    // On every path, also after a failure: pop any chat screen, because its chat may be gone.
    services.navigator.path = []
    await services.thumbnails.removeFromMemory()
    show("All chats deleted")
    await refreshSizes()
  }

  // MARK: Toast

  /// Shows a toast for 2 seconds. A newer toast cancels the older one's timer, so the older timer
  /// cannot hide the newer text early. `[weak self]`: the timer does not keep the model alive.
  func show(_ text: String) {
    toast = text
    toastTask?.cancel()
    toastTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(2))  // try?: a cancelled sleep is handled by the check below.
      guard !Task.isCancelled else { return }
      self?.toast = nil
    }
  }
}
