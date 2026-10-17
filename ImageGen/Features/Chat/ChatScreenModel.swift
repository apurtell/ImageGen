import Foundation
import Observation

/// Service container supplying environment dependencies, persistence actors, and subsystems to a chat view model.
@MainActor
struct ChatServices {
  var store: DataStore
  var files: FileStore
  var generation: any GenerationServicing
  var settings: AppSettings
  var log: ActivityLog
  var connectivity: any ConnectivityMonitoring
  var activity: AppActivity
  var notifications: NotificationPermission
  var navigator: Navigator
  var thumbnails: ThumbnailService
  var copyToPasteboard: @MainActor (String) -> Void
  /// Debounce threshold applied before persisting draft prompt modifications.
  var draftDebounce: Duration = .milliseconds(500)
  /// Preprocessing hook transforming candidate uploads into target ingestion dimensions.
  var prepareUpload: @Sendable (_ source: URL, _ maxLongEdge: Int, _ destinationDir: URL, _ id: UUID) async throws -> PreparedImage = {
    try await ImagePreprocessor.prepare(source: $0, maxLongEdge: $1, destinationDir: $2, id: $3)
  }

  /// Factory providing conversation-level lifecycle dispatchers.
  var actions: ChatActions { ChatActions(store: store, generation: generation, log: log, navigator: navigator) }
}

/// Provenance descriptor identifying the user interface source of a parameter modification.
enum SettingSource: String {
  case pill
  case chatSettings = "Chat settings…"
  case editFromHere = "Edit from here"
}

/// Presentation model coordinating state and interactions for the conversation view.
///
/// Responsibilities:
/// - Manages interactive state for the prompt composer, parameter pills, and attachment staging tray.
/// - Coordinates asynchronous generation workflows through `GenerationServicing` and handles lifecycle cancellations.
/// - Synchronizes active conversation metadata, message pin state, and draft persistence with the underlying data store.
/// - Tracks network availability and updates contextual UI status indicators.
///
/// Threading and Concurrency:
/// Bound to `@MainActor` to ensure coherent UI state publishing and event handling. Asynchronous operations
/// yielding to background stores or generation actors re-verify local context following suspension points
/// to account for concurrent user input or navigation events.
@Observable @MainActor
final class ChatScreenModel {
  let conversationID: UUID
  @ObservationIgnored let services: ChatServices

  /// Active text buffer within the composer; bound to debounce persistence routines.
  var composerText = "" {
    didSet { if !loadingDraft { scheduleDraftSave() } }
  }
  /// Bidirectional focus binding for the primary input field.
  var isTextFieldFocused = false
  /// Pending request coordinates requiring user confirmation prior to draft replacement.
  var pendingEdit: (userMessageID: UUID, requestID: UUID?)?
  /// User-facing alert message payload presented upon exceptional workflow failures.
  var alertMessage: String?

  private(set) var title = Conversation.untitled
  private(set) var overrides = ChatOverrides()
  private(set) var pinnedImageID: UUID?
  private(set) var pinExists = false
  private(set) var pinnedImageURL: URL?
  private(set) var implicitBaseID: UUID?
  private(set) var implicitBaseURL: URL?
  /// Active generation request snapshot associated with this conversation, if running.
  private(set) var liveRequest: RequestSnapshot?
  /// Evaluated network connectivity status driving status indicator presentation.
  private(set) var isNetworkUnavailable = false
  /// Monotonic trigger counter driving sensory feedback upon prompt submission.
  private(set) var sendCount = 0
  /// Monotonic trigger counter driving sensory feedback upon image pinning.
  private(set) var pinCount = 0
  private(set) var completedWhileVisible = 0
  /// Ordered collection of attachment candidates currently residing in the composer tray.
  var tray: [TrayItem] = []
  /// Ephemeral overlay notification string displayed above the composer.
  private(set) var toast: String?
  /// Guard flag asserted during initial request dispatch to debounce duplicate submission gestures.
  private(set) var isStarting = false

  @ObservationIgnored private var loadingDraft = false
  @ObservationIgnored private var draftTask: Task<Void, Never>?
  @ObservationIgnored private var connectivityTask: Task<Void, Never>?
  @ObservationIgnored private var lastLiveID: UUID?
  @ObservationIgnored var trayTasks: [UUID: Task<TrayItemOutcome, Never>] = [:]
  @ObservationIgnored private var toastTask: Task<Void, Never>?
  @ObservationIgnored private var isOnScreen = false

  init(conversationID: UUID, services: ChatServices) {
    self.conversationID = conversationID
    self.services = services
  }

  /// Lifecycle presentation hook initializing visibility tracking, network observers, and store state.
  func onAppear() async {
    isOnScreen = true
    services.activity.setVisible(conversationID)
    startConnectivity()
    await load()
  }

  /// Lifecycle dismissal hook cleaning up visibility state, terminating monitoring streams,
  /// committing pending draft modifications, and pruning unpopulated conversations.
  func onDisappear() async {
    isOnScreen = false
    services.activity.setVisible(nil, leaving: conversationID)
    connectivityTask?.cancel()
    connectivityTask = nil
    await flushDraft()
    if !isStarting { await services.actions.discardIfEmpty(conversationID) }
  }

  /// Populates initial draft content and re-syncs conversation metadata.
  func load() async {
    if let draft = try? await services.store.draftText(conv: conversationID), !draft.isEmpty, composerText.isEmpty {
      loadingDraft = true
      composerText = draft
      loadingDraft = false
    }
    await reload()
  }

  /// Re-synchronizes conversation settings, pinned references, and active generation status from the store.
  func reload() async {
    let store = services.store
    guard let title = try? await store.conversationTitle(conversationID) else { return }
    self.title = title
    overrides = (try? await store.overrides(conversationID)) ?? ChatOverrides()
    let pin: (id: UUID?, exists: Bool) = (try? await store.pinState(conv: conversationID)) ?? (nil, false)
    pinnedImageID = pin.id
    pinExists = pin.exists
    pinnedImageURL = await imageURL(pin.exists ? pin.id : nil)
    let history = (try? await store.selectorHistory(conv: conversationID)) ?? []
    implicitBaseID = InputSelector.implicitBase(history: history)
    implicitBaseURL = await imageURL(implicitBaseID)
    let live = try? await store.liveRequest(conv: conversationID)
    if lastLiveID != nil && live == nil && services.activity.visibleConversationID == conversationID {
      completedWhileVisible += 1
    }
    lastLiveID = live?.id
    liveRequest = live
  }

  /// Resolves the filesystem URL for a stored asset identifier.
  private func imageURL(_ id: UUID?) async -> URL? {
    guard let id, let file = try? await services.store.imageFile(id) else { return nil }
    return services.files.url(relative: file.relativePath)
  }

  /// Observes system network reachability and updates the local connectivity flag.
  private func startConnectivity() {
    guard connectivityTask == nil else { return }
    let stream = services.connectivity.isSatisfied
    connectivityTask = Task { [weak self] in
      for await satisfied in stream {
        self?.isNetworkUnavailable = !satisfied
      }
    }
  }

  var defaults: GenerationDefaults { services.settings.generationDefaults() }
  var effective: EffectiveSettings { GenerationSettingsResolver.resolve(overrides, defaults) }
  var trimmedText: String { composerText.trimmingCharacters(in: .whitespacesAndNewlines) }

  /// Evaluates submission readiness based on active request locks, staging status, and input content.
  var canSend: Bool {
    !isStarting && InputSelector.canSend(trimmedText: trimmedText, tray: trayCounts, chatHasLiveRequest: liveRequest != nil)
  }

  var hasAttachments: Bool { trayCounts.ready + trayCounts.pending + trayCounts.failed > 0 }

  /// The pin chip: shown while a pin is set and its image exists; dimmed when attachments replace it.
  var showsPinChip: Bool { pinnedImageID != nil && pinExists }
  var pinChipDimmed: Bool { showsPinChip && hasAttachments }

  /// Determines whether the automatic base context indicator is applicable under rule evaluation.
  var showsImplicitChip: Bool { !hasAttachments && !showsPinChip && implicitBaseID != nil }

  /// Indicates whether the default Flash model is absent from the cached catalog descriptor list.
  var flashUnlisted: Bool {
    guard let cache = services.settings.modelAvailabilityCache else { return false }
    return cache.models[ModelCatalog.defaultModelID] != true
  }

  /// Evaluates whether the foreground UI should display waiting-for-network status.
  var showsWaitingForNetwork: Bool {
    guard isNetworkUnavailable, services.activity.isActive, let live = liveRequest else { return false }
    return live.state == .inFlight || live.state == .retryScheduled
  }

  // The pills and "Chat settings…" both call `setModel`, `setAspect` and `setSize`. Each copies the
  // current `overrides`, changes one field and saves the copy with `changeSetting`.

  /// Filtered list of models eligible for selection based on user enablement and availability cache state.
  var menuModels: [ModelDescriptor] {
    let settings = services.settings
    let enabled = settings.enabledModelIDs
    let cache = settings.modelAvailabilityCache
    let custom = settings.customModelIDs.map { ModelCatalog.descriptor(for: $0) }
    return (ModelCatalog.builtIns + custom).filter { m in
      guard enabled.contains(m.id) || m.id == ModelCatalog.defaultModelID else { return false }
      if m.id == ModelCatalog.defaultModelID { return true }
      if let cache { return cache.models[m.id] == true || (m.role == .custom && cache.models[m.id] == nil) }
      return m.role != .legacyIfListed
    }
  }

  var capability: ModelCapability { ModelCatalog.descriptor(for: effective.modelID).capability }

  var aspectSections: [(group: AspectGroup, ratios: [AspectRatio])] {
    let supported = Set(capability.aspectRatios)
    let order: [(AspectGroup, [AspectRatio])] = [
      (.landscape, [.r16x9, .r21x9, .r3x2, .r4x3, .r5x4]), (.square, [.r1x1]), (.portrait, [.r9x16, .r2x3, .r3x4, .r4x5]),
      (.extreme, [.r4x1, .r8x1, .r1x4, .r1x8]),
    ]
    return order.map { ($0.0, $0.1.filter(supported.contains)) }.filter { !$0.1.isEmpty }
  }

  var sizes: [ImageSize] { capability.imageSizes }

  var modelPillLabel: String { ModelCatalog.descriptor(for: effective.modelID).shortName }
  var aspectPillLabel: String { effective.aspectRatio?.rawValue ?? "Auto" }
  var sizePillLabel: String { effective.imageSize?.rawValue ?? "Auto" }

  var modelOverridden: Bool { overrides.modelID != nil }
  var aspectOverridden: Bool { overrides.aspectRatio != nil }
  var sizeOverridden: Bool { overrides.imageSize != nil }

  func isCoerced(_ field: CoercionField) -> Bool { effective.coercions.contains { $0.field == field } }

  /// Menu label describing the default aspect ratio setting, indicating coercion status when applicable.
  var defaultAspectItemLabel: String {
    let d = defaults.aspectRatio
    var o = overrides
    o.aspectRatio = nil
    let used = GenerationSettingsResolver.resolve(o, defaults).aspectRatio
    return used == d ? "Default (\(d.rawValue))" : "Default (\(used?.rawValue ?? "auto") ⚠︎)"
  }

  /// Menu label describing the default resolution setting, indicating coercion status when applicable.
  var defaultSizeItemLabel: String {
    let d = defaults.imageSize
    var o = overrides
    o.imageSize = nil
    let used = GenerationSettingsResolver.resolve(o, defaults).imageSize
    return used == d ? "Default (\(d.rawValue))" : "Default (\(used?.rawValue ?? "auto") ⚠︎)"
  }

  /// Menu label describing the fallback default model descriptor.
  var defaultModelItemLabel: String { "Default (\(ModelCatalog.descriptor(for: ModelCatalog.defaultModelID).shortName))" }

  func setModel(_ id: String?, from source: SettingSource) async {
    await changeSetting(
      "model", label: { $0.modelPillLabel }, new: id.map { ModelCatalog.descriptor(for: $0).shortName }, from: source,
      change: { $0.modelID = id }
    ) {
      ModelCatalog.descriptor(for: $0.modelID).shortName + ($0.coercions.contains { $0.field == .model } ? " (coerced)" : "")
    }
  }

  func setAspect(_ ratio: AspectRatio?, from source: SettingSource) async {
    await changeSetting(
      "aspect ratio", label: { $0.aspectPillLabel }, new: ratio?.rawValue, from: source, change: { $0.aspectRatio = ratio }
    ) {
      ($0.aspectRatio?.rawValue ?? "omitted") + ($0.coercions.contains { $0.field == .aspectRatio } ? " (coerced)" : "")
    }
  }

  func setSize(_ size: ImageSize?, from source: SettingSource) async {
    await changeSetting("resolution", label: { $0.sizePillLabel }, new: size?.rawValue, from: source, change: { $0.imageSize = size }) {
      ($0.imageSize?.rawValue ?? "omitted") + ($0.coercions.contains { $0.field == .imageSize } ? " (coerced)" : "")
    }
  }

  @ObservationIgnored private var settingSave: Task<Void, Never>?

  /// Serializes and persists conversation override modifications, logging the transition event.
  private func changeSetting(
    _ name: String, label: @escaping @MainActor (ChatScreenModel) -> String, new: String?, from source: SettingSource,
    change: @escaping @MainActor (inout ChatOverrides) -> Void,
    effectiveText: @escaping @MainActor (EffectiveSettings) -> String
  ) async {
    let previous = settingSave
    let save = Task { @MainActor in
      await previous?.value
      var o = self.overrides
      change(&o)
      let action = self.services.log.begin(
        "Chat setting change", origin: .user,
        "chat \(Format.short(self.conversationID)) · \(name) \(label(self)) → \(new ?? "Default") · \(source.rawValue)")
      do {
        try await self.services.store.setOverrides(self.conversationID, o)
        self.overrides = o
        self.services.log.result(action, .success, "saved · effective \(effectiveText(self.effective))")
      } catch {
        self.services.log.result(action, .failed, "\(error.localizedDescription)")
      }
    }
    settingSave = save
    await save.value
  }

  /// Submits the current composer draft and attachments to the generation service.
  /// Clears the composer input state immediately, restoring prior draft contents if the submission fails prior to record ingestion.
  func send() async {
    guard canSend else { return }
    let sent = tray
    let draft = SendDraft(
      conversationID: conversationID, promptText: trimmedText, attachments: sent.compactMap(\.staged), settings: effective)
    isStarting = true
    tray = []
    sendCount += 1
    composerText = ""
    await flushDraft()
    do {
      _ = try await services.generation.send(draft)
    } catch {
      if case GenerationError.chatBusy = error { alertMessage = "A request is already running in this chat." }
      if !Self.recorded(despite: error) { restoreComposer(text: draft.promptText, items: sent) }
    }
    isStarting = false
    await reload()
    if !isOnScreen { await services.actions.discardIfEmpty(conversationID) }
    await services.notifications.requestOnFirstSend()
  }

  /// Evaluates whether an error occurred subsequent to request record creation.
  static func recorded(despite error: any Error) -> Bool {
    switch error as? GenerationError {
    case .preparationFailed, .cancelled, .interrupted: true
    default: false
    }
  }

  /// Restores prompt text and attachment candidates back into the composer following an unrecorded dispatch failure.
  private func restoreComposer(text: String, items: [TrayItem]) {
    if composerText.isEmpty { composerText = text }
    let intact = items.filter { item in
      [item.originalURL, item.prepared?.url].allSatisfy { url in url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }
    }
    tray = intact + tray
  }

  /// Requests cancellation of the in-flight generation request.
  func stop() async {
    guard let live = liveRequest else { return }
    await services.generation.cancel(requestID: live.id)
    await reload()
  }

  /// Triggers recreation of a generation request using the parameters of an existing source request record.
  func regenerate(requestID: UUID) async {
    guard !isStarting else { return }
    isStarting = true
    defer { isStarting = false }
    do {
      _ = try await services.generation.regenerate(sourceRequestID: requestID)
    } catch GenerationError.chatBusy {
      alertMessage = "A request is already running in this chat."
    } catch GenerationError.inputMissing {
      alertMessage = "An input image was deleted."
    } catch {}
    await reload()
  }

  /// Retries execution of an existing failed request record in place.
  func retry(requestID: UUID) async {
    guard !isStarting else { return }
    isStarting = true
    defer { isStarting = false }
    do {
      try await services.generation.retry(requestID: requestID)
    } catch GenerationError.chatBusy {
      alertMessage = "A request is already running in this chat."
    } catch {}
    await reload()
  }

  /// Cancels in-flight reply requests and cascades deletion of the message entity and associated asset files.
  func deleteMessage(_ id: UUID) async {
    let info = try? await services.store.messageInfo(id)
    let live: RequestSnapshot? =
      if info?.role == .model, let requestID = info?.requestID, let snap = try? await services.store.requestSnapshot(requestID),
        snap.state.isLive
      { snap } else { nil }
    let action = services.log.begin(
      "Delete message", origin: .user,
      "message \(Format.short(id)) (\(info?.role.rawValue ?? "unknown")) · \(live == nil ? "no live request" : "1 live request to cancel")")
    if let live { await services.generation.cancel(requestID: live.id) }
    do {
      let result = try await services.store.deleteMessage(id)
      for request in result.liveRequestIDs where request != live?.id { await services.generation.cancel(requestID: request) }
      let removed = "files removed \(result.filesRemoved) (\(Format.mb(Int(result.bytesFreed))))"
      services.log.result(action, result.failures == 0 ? .success : .failed, "done · \(removed)")
    } catch {
      services.log.result(action, .failed, "\(error.localizedDescription)")
    }
    await reload()
  }

  /// Pins a generated image as the conversational editing base and adopts its generation settings.
  func pin(_ imageID: UUID) async {
    let action = services.log.begin("Pin", origin: .user, "chat \(Format.short(conversationID)) · img \(Format.short(imageID))")
    do {
      try await services.store.setPin(conversationID, imageID: imageID)
      services.log.result(action, .success, "done")
    } catch {
      services.log.result(action, .failed, "\(error.localizedDescription)")
      await reload()
      return
    }
    pinCount += 1
    await adoptSettings(ofImage: imageID)
    await reload()
    showToast("Editing from this image · \(aspectPillLabel) · \(sizePillLabel)")
  }

  /// Adopts the recorded aspect ratio and size settings from the targeted image entity.
  private func adoptSettings(ofImage imageID: UUID) async {
    guard let made = try? await services.store.generatedSettings(ofImage: imageID) else { return }
    if let ratio = made.aspectRatio {
      let override = ratio == defaults.aspectRatio ? nil : ratio
      if override != overrides.aspectRatio { await setAspect(override, from: .editFromHere) }
    }
    if let size = made.imageSize {
      let override = size == defaults.imageSize ? nil : size
      if override != overrides.imageSize { await setSize(override, from: .editFromHere) }
    }
  }

  /// Clears the pinned base image assignment for this conversation.
  func unpin() async {
    let imageText = pinnedImageID.map { "img \(Format.short($0))" } ?? "none"
    let action = services.log.begin("Unpin", origin: .user, "chat \(Format.short(conversationID)) · \(imageText)")
    do {
      try await services.store.setPin(conversationID, imageID: nil)
      services.log.result(action, .success, "done")
    } catch {
      services.log.result(action, .failed, "\(error.localizedDescription)")
    }
    await reload()
  }

  enum CopyKind: String {
    case prompt
    case replyText = "reply text"
  }

  func copy(_ text: String, kind: CopyKind) {
    let action = services.log.begin("Copy", origin: .user, "\(kind.rawValue) · \(text.count) characters")
    services.copyToPasteboard(text)
    services.log.result(action, .success, "pasteboard written (1 item, plain text)")
  }

  /// Recovers the source prompt and attachments corresponding to a refused generation request.
  func editRefused(requestID: UUID) async {
    guard let origin = try? await services.store.originatingUserMessage(requestID: requestID) else { return }
    await editAndResend(userMessageID: origin.id, requestID: requestID)
  }

  /// Instantiates a new conversation replacing the current screen within the navigation hierarchy.
  func newChat() async {
    guard let id = await services.actions.newChat() else { return }
    services.navigator.replaceTop(with: id)
  }

  func rename(to name: String) async {
    await services.actions.rename(conversationID, to: name)
    await reload()
  }

  /// Active draft string during inline title editing, or nil when inactive.
  var titleDraft: String?
  var isEditingTitle: Bool { titleDraft != nil }
  @ObservationIgnored private var titleAtEditStart = ""

  func beginTitleEdit() {
    titleDraft = title
    titleAtEditStart = title
  }

  /// Commits modified inline title text to storage.
  func commitTitleEdit() async {
    guard let draft = titleDraft else { return }
    titleDraft = nil
    guard let name = TitleEdit.change(draft: draft, current: titleAtEditStart) else { return }
    await rename(to: name)
  }

  func cancelTitleEdit() {
    titleDraft = nil
  }

  /// Cascades deletion of the active conversation entity and navigates back to root.
  func deleteChat() async {
    await services.actions.deleteChat(conversationID)
  }

  /// Displays a transient informational toast message above the composer.
  func showToast(_ text: String) {
    toast = text
    toastTask?.cancel()
    toastTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(2.5))
      guard !Task.isCancelled else { return }
      self?.toast = nil
    }
  }

  /// Schedules asynchronous persistence of the composer text buffer after the debounce interval.
  private func scheduleDraftSave() {
    draftTask?.cancel()
    let text = composerText
    let store = services.store
    let id = conversationID
    let delay = services.draftDebounce
    draftTask = Task {
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled else { return }
      try? await store.setDraft(id, text: text)
    }
  }

  /// Flushes current composer text directly to backing storage and cancels pending debounced tasks.
  func flushDraft() async {
    draftTask?.cancel()
    draftTask = nil
    try? await services.store.setDraft(conversationID, text: composerText)
  }
}
