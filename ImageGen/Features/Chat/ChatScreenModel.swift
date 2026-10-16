import Foundation
import Observation

/// What a chat screen needs from the app. Tests build one with fakes.
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
  var draftDebounce: Duration = .milliseconds(500)
  /// Prepares an upload (D§4.8 step 3); tests substitute a gated or failing one.
  var prepareUpload: @Sendable (_ source: URL, _ maxLongEdge: Int, _ destinationDir: URL, _ id: UUID) async throws -> PreparedImage = {
    try await ImagePreprocessor.prepare(source: $0, maxLongEdge: $1, destinationDir: $2, id: $3)
  }

  var actions: ChatActions { ChatActions(store: store, generation: generation, log: log, navigator: navigator) }
}

/// Where a per-chat setting was changed, for the log.
enum SettingSource: String {
  case pill
  case chatSettings = "Chat settings…"
}

/// The chat screen's model (D§3.4, D§3.5): composer text, pills, chips, send enablement and every
/// chat action. It talks to generation only through `GenerationServicing`.
@Observable @MainActor
final class ChatScreenModel {
  let conversationID: UUID
  @ObservationIgnored let services: ChatServices

  /// The composer text; changes are saved to the chat's draft after a pause.
  var composerText = "" {
    didSet { if !loadingDraft { scheduleDraftSave() } }
  }
  var isTextFieldFocused = false
  /// Edit & Resend over a non-empty draft waits for confirmation (D§3.6).
  var pendingEdit: (userMessageID: UUID, requestID: UUID?)?
  var alertMessage: String?

  private(set) var title = Conversation.untitled
  private(set) var overrides = ChatOverrides()
  private(set) var pinnedImageID: UUID?
  private(set) var pinExists = false
  private(set) var pinnedImageURL: URL?
  private(set) var implicitBaseID: UUID?
  private(set) var implicitBaseURL: URL?
  private(set) var liveRequest: RequestSnapshot?
  private(set) var isNetworkUnavailable = false
  /// Bumped on each send (haptic impact) and on each reply completed while visible (haptic success).
  private(set) var sendCount = 0
  private(set) var completedWhileVisible = 0
  /// The attachment tray, in send order (D§3.5); its files live in `Staging/`.
  var tray: [TrayItem] = []
  /// A transient message over the composer, such as "Up to 14 images per message".
  private(set) var toast: String?

  @ObservationIgnored private var loadingDraft = false
  @ObservationIgnored private var draftTask: Task<Void, Never>?
  @ObservationIgnored private var connectivityTask: Task<Void, Never>?
  @ObservationIgnored private var lastLiveID: UUID?
  @ObservationIgnored var trayTasks: [UUID: Task<TrayItemOutcome, Never>] = [:]
  @ObservationIgnored private var toastTask: Task<Void, Never>?

  init(conversationID: UUID, services: ChatServices) {
    self.conversationID = conversationID
    self.services = services
  }

  // MARK: Lifecycle

  func onAppear() async {
    services.activity.setVisible(conversationID)
    startConnectivity()
    await load()
  }

  func onDisappear() async {
    services.activity.setVisible(nil, leaving: conversationID)
    connectivityTask?.cancel()
    connectivityTask = nil
    await flushDraft()
    await services.actions.discardIfEmpty(conversationID)
  }

  /// Loads the draft and the chat's state.
  func load() async {
    // Restore a saved draft, but never over text typed while it was loading.
    if let draft = try? await services.store.draftText(conv: conversationID), !draft.isEmpty, composerText.isEmpty {
      loadingDraft = true
      composerText = draft
      loadingDraft = false
    }
    await reload()
  }

  /// Re-reads the chat's state from the store (after any change the transcript shows).
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

  private func imageURL(_ id: UUID?) async -> URL? {
    guard let id, let file = try? await services.store.imageFile(id) else { return nil }
    return services.files.url(relative: file.relativePath)
  }

  private func startConnectivity() {
    guard connectivityTask == nil else { return }
    let stream = services.connectivity.isSatisfied
    connectivityTask = Task { [weak self] in
      for await satisfied in stream {
        self?.isNetworkUnavailable = !satisfied
      }
    }
  }

  // MARK: Derived state

  var defaults: GenerationDefaults { services.settings.generationDefaults() }
  var effective: EffectiveSettings { GenerationSettingsResolver.resolve(overrides, defaults) }
  var trimmedText: String { composerText.trimmingCharacters(in: .whitespacesAndNewlines) }

  var canSend: Bool {
    InputSelector.canSend(trimmedText: trimmedText, tray: trayCounts, chatHasLiveRequest: liveRequest != nil)
  }

  var hasAttachments: Bool { trayCounts.ready + trayCounts.pending + trayCounts.failed > 0 }

  /// The pin chip: shown while a pin is set and its image exists; dimmed when attachments replace it.
  var showsPinChip: Bool { pinnedImageID != nil && pinExists }
  var pinChipDimmed: Bool { showsPinChip && hasAttachments }

  /// The informational "Editing latest image" chip: rule 3 applies (no attachments, no usable pin).
  var showsImplicitChip: Bool { !hasAttachments && !showsPinChip && implicitBaseID != nil }

  /// The key's model list doesn't include Flash (D§2.5): Flash stays selectable, with a banner.
  var flashUnlisted: Bool {
    guard let cache = services.settings.modelAvailabilityCache else { return false }
    return cache.models[ModelCatalog.defaultModelID] != true
  }

  /// "Waiting for network" on a pending card: no usable path, in the foreground, request on the wire.
  var showsWaitingForNetwork: Bool {
    guard isNetworkUnavailable, services.activity.isActive, let live = liveRequest else { return false }
    return live.state == .inFlight || live.state == .retryScheduled
  }

  // MARK: Pills (D§3.5)

  /// Enabled models the key can use: before the first check, every enabled one except the legacy
  /// preview alias; after it, only listed ones; Flash always (D§2.5).
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

  /// "Default (16:9)", or the coerced value with ⚠︎ when the model doesn't support the default.
  var defaultAspectItemLabel: String {
    let d = defaults.aspectRatio
    var o = overrides
    o.aspectRatio = nil
    let used = GenerationSettingsResolver.resolve(o, defaults).aspectRatio
    return used == d ? "Default (\(d.rawValue))" : "Default (\(used?.rawValue ?? "auto") ⚠︎)"
  }

  var defaultSizeItemLabel: String {
    let d = defaults.imageSize
    var o = overrides
    o.imageSize = nil
    let used = GenerationSettingsResolver.resolve(o, defaults).imageSize
    return used == d ? "Default (\(d.rawValue))" : "Default (\(used?.rawValue ?? "auto") ⚠︎)"
  }

  var defaultModelItemLabel: String { "Default (\(ModelCatalog.descriptor(for: ModelCatalog.defaultModelID).shortName))" }

  func setModel(_ id: String?, from source: SettingSource) async {
    var o = overrides
    o.modelID = id
    await changeSetting("model", old: modelPillLabel, new: id.map { ModelCatalog.descriptor(for: $0).shortName }, to: o, from: source) {
      ModelCatalog.descriptor(for: $0.modelID).shortName + ($0.coercions.contains { $0.field == .model } ? " (coerced)" : "")
    }
  }

  func setAspect(_ ratio: AspectRatio?, from source: SettingSource) async {
    var o = overrides
    o.aspectRatio = ratio
    await changeSetting("aspect ratio", old: aspectPillLabel, new: ratio?.rawValue, to: o, from: source) {
      ($0.aspectRatio?.rawValue ?? "omitted") + ($0.coercions.contains { $0.field == .aspectRatio } ? " (coerced)" : "")
    }
  }

  func setSize(_ size: ImageSize?, from source: SettingSource) async {
    var o = overrides
    o.imageSize = size
    await changeSetting("resolution", old: sizePillLabel, new: size?.rawValue, to: o, from: source) {
      ($0.imageSize?.rawValue ?? "omitted") + ($0.coercions.contains { $0.field == .imageSize } ? " (coerced)" : "")
    }
  }

  private func changeSetting(
    _ name: String, old: String, new: String?, to o: ChatOverrides, from source: SettingSource,
    effectiveText: (EffectiveSettings) -> String
  ) async {
    let action = services.log.begin(
      "Chat setting change", origin: .user,
      "chat \(Format.short(conversationID)) · \(name) \(old) → \(new ?? "Default") · \(source.rawValue)")
    do {
      try await services.store.setOverrides(conversationID, o)
      overrides = o
      services.log.result(action, .success, "saved · effective \(effectiveText(effective))")
    } catch {
      services.log.result(action, .failed, "\(error.localizedDescription)")
    }
  }

  // MARK: Generation

  func send() async {
    guard canSend else { return }
    let draft = SendDraft(
      conversationID: conversationID, promptText: trimmedText, attachments: tray.compactMap(\.staged), settings: effective)
    sendCount += 1
    composerText = ""
    await flushDraft()
    do {
      _ = try await services.generation.send(draft)
      tray = []
    } catch GenerationError.chatBusy {
      alertMessage = "A request is already running in this chat."
    } catch {
      // The staged files now belong to the request; preparation failures are shown on the reply card.
      tray = []
    }
    await reload()
    await services.notifications.requestOnFirstSend()
  }

  func stop() async {
    guard let live = liveRequest else { return }
    await services.generation.cancel(requestID: live.id)
    await reload()
  }

  func regenerate(requestID: UUID) async {
    do {
      _ = try await services.generation.regenerate(sourceRequestID: requestID)
    } catch GenerationError.chatBusy {
      alertMessage = "A request is already running in this chat."
    } catch GenerationError.inputMissing {
      alertMessage = "An input image was deleted."
    } catch {}
    await reload()
  }

  func retry(requestID: UUID) async {
    do {
      try await services.generation.retry(requestID: requestID)
    } catch GenerationError.chatBusy {
      alertMessage = "A request is already running in this chat."
    } catch {}
    await reload()
  }

  // MARK: Messages and images

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
      let removed = "files removed \(result.filesRemoved) (\(Format.mb(Int(result.bytesFreed))))"
      services.log.result(action, result.failures == 0 ? .success : .failed, "done · \(removed)")
    } catch {
      services.log.result(action, .failed, "\(error.localizedDescription)")
    }
    await reload()
  }

  /// Edit from here (D§3.6).
  func pin(_ imageID: UUID) async {
    let action = services.log.begin("Pin", origin: .user, "chat \(Format.short(conversationID)) · img \(Format.short(imageID))")
    do {
      try await services.store.setPin(conversationID, imageID: imageID)
      services.log.result(action, .success, "done")
    } catch {
      services.log.result(action, .failed, "\(error.localizedDescription)")
    }
    await reload()
  }

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

  /// A refused card's Edit: the user message of the request (of the source request, for a regenerated reply).
  func editRefused(requestID: UUID) async {
    guard let origin = try? await services.store.originatingUserMessage(requestID: requestID) else { return }
    await editAndResend(userMessageID: origin.id, requestID: requestID)
  }

  // MARK: Chat

  /// New Chat from this chat (a refused card's button): opens it in place of this one (D§3.4).
  func newChat() async {
    guard let id = await services.actions.newChat() else { return }
    services.navigator.replaceTop(with: id)
  }

  func rename(to name: String) async {
    await services.actions.rename(conversationID, to: name)
    await reload()
  }

  // MARK: In-place title edit

  /// The title being edited in place (long-press on the navigation title), or nil.
  var titleDraft: String?
  var isEditingTitle: Bool { titleDraft != nil }

  func beginTitleEdit() {
    titleDraft = title
  }

  /// Renames when the text changed; an empty name reverts to the automatic title, as in the alert.
  func commitTitleEdit() async {
    guard let draft = titleDraft else { return }
    titleDraft = nil
    guard let name = TitleEdit.change(draft: draft, current: title) else { return }
    await rename(to: name)
  }

  func cancelTitleEdit() {
    titleDraft = nil
  }

  func deleteChat() async {
    await services.actions.deleteChat(conversationID)
  }

  // MARK: Toast

  func showToast(_ text: String) {
    toast = text
    toastTask?.cancel()
    toastTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(2.5))
      guard !Task.isCancelled else { return }
      self?.toast = nil
    }
  }

  // MARK: Draft

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

  func flushDraft() async {
    draftTask?.cancel()
    draftTask = nil
    try? await services.store.setDraft(conversationID, text: composerText)
  }
}
