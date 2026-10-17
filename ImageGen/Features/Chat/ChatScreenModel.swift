import Foundation
import Observation

/// What a chat screen needs from the app. Tests build one with fakes.
///
/// `AppEnvironment` builds the real one; each `ChatView` passes it to its `ChatScreenModel`. It is a
/// struct of services and closures, so the model never reaches for global state. `@MainActor` here
/// means the struct is made and read on the main thread only (see the primer, *Actors*).
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
  /// The pause after the last keystroke before the draft is saved (D§3.5: 500 ms). Tests shorten it.
  var draftDebounce: Duration = .milliseconds(500)
  /// Prepares an upload (D§4.8 step 3); tests substitute a gated or failing one. It is `@Sendable`
  /// because the tray's tasks call it, and the real one runs off the main actor.
  var prepareUpload: @Sendable (_ source: URL, _ maxLongEdge: Int, _ destinationDir: URL, _ id: UUID) async throws -> PreparedImage = {
    try await ImagePreprocessor.prepare(source: $0, maxLongEdge: $1, destinationDir: $2, id: $3)
  }

  /// The chat-level actions that the chat list also uses (new chat, rename, delete). A new value on
  /// each read is cheap: `ChatActions` holds only references.
  var actions: ChatActions { ChatActions(store: store, generation: generation, log: log, navigator: navigator) }
}

/// Where a per-chat setting was changed, for the log.
enum SettingSource: String {
  case pill
  case chatSettings = "Chat settings…"
  case editFromHere = "Edit from here"
}

/// The chat screen's model (D§3.4, D§3.5): composer text, pills, chips, send enablement and every
/// chat action. It talks to generation only through `GenerationServicing`.
///
/// **View/model split.** The SwiftUI views in this folder are descriptions: structs that SwiftUI
/// rebuilds whenever the state they read changes. They hold no logic beyond layout. This class holds
/// the chat screen's state and does the work; `ChatView` creates one per screen and keeps it in
/// `@State`, so it lives as long as the screen. `@Observable` makes SwiftUI record which properties
/// each `body` reads and redraw only those views when one changes (see the primer, *SwiftUI: the
/// user interface*). `@ObservationIgnored` marks bookkeeping that no view reads, so a change to it
/// redraws nothing.
///
/// **Concurrency.** The class is `@MainActor`: every method and property runs on the main thread,
/// one at a time, so no lock protects its state. But each `await` (on `DataStore`, on
/// `GenerationService`) is a suspension point. While a method waits there, the user can type, tap,
/// attach or leave the screen, and other methods of this model run. So each method reads the state
/// again after an `await` where that matters, and the comments at those points say what the user
/// can do meanwhile (see the primer, *async and await: suspension points*).
///
/// The transcript itself does not come through this model: `ChatView` reads the records with
/// SwiftData queries. This model reads snapshots from `DataStore` for the composer's state
/// (`reload()`), and `ChatView` calls `reload()` whenever the transcript's records change.
@Observable @MainActor
final class ChatScreenModel {
  let conversationID: UUID
  @ObservationIgnored let services: ChatServices

  /// The composer text; changes are saved to the chat's draft after a pause. `didSet` runs after
  /// each assignment, from the text field or from this model; `loadingDraft` stops a restored draft
  /// from saving itself again.
  var composerText = "" {
    didSet { if !loadingDraft { scheduleDraftSave() } }
  }
  /// Mirrors the text field's focus both ways (see `ComposerInputRow`); Edit and Resend sets it.
  var isTextFieldFocused = false
  /// Edit and Resend over a non-empty draft waits for confirmation (D§3.6). Non-nil shows the
  /// "Replace the current draft?" dialog; the dialog's button calls `editAndResend` again with
  /// `confirmed: true`.
  var pendingEdit: (userMessageID: UUID, requestID: UUID?)?
  /// Non-nil shows the "Couldn't do that" alert; the alert sets it back to nil.
  var alertMessage: String?

  // The chat's state as of the last `reload()`. `private(set)` lets views read these but only this
  // model write them.
  private(set) var title = Conversation.untitled
  private(set) var overrides = ChatOverrides()
  private(set) var pinnedImageID: UUID?
  private(set) var pinExists = false
  private(set) var pinnedImageURL: URL?
  private(set) var implicitBaseID: UUID?
  private(set) var implicitBaseURL: URL?
  /// The chat's request in progress, if any. Non-nil turns Send into Stop.
  private(set) var liveRequest: RequestSnapshot?
  /// Set by the connectivity task; feeds "Waiting for network" on the pending card.
  private(set) var isNetworkUnavailable = false
  /// Bumped on each send (haptic impact) and on each reply completed while visible (haptic success).
  /// They are counters, not flags, because `.sensoryFeedback` plays on every change of its trigger.
  private(set) var sendCount = 0
  /// Bumped on each Edit from here (haptic selection, D§3.6).
  private(set) var pinCount = 0
  private(set) var completedWhileVisible = 0
  /// The attachment tray, in send order (D§3.5); its files live in `Staging/`. `TrayItem` is a
  /// struct, so a view always draws a consistent copy; only this model changes the array.
  var tray: [TrayItem] = []
  /// A transient message over the composer, such as "Up to 14 images per message".
  private(set) var toast: String?
  /// A Send, Retry or Regenerate between the tap and the reload after it: the buttons stay off,
  /// because `liveRequest` doesn't show the new request until that reload. Without it, a second tap
  /// during the await would start a second request, or reach the service only to fail `chatBusy`.
  /// It also tells `onDisappear` that a send may still be on its way to its record.
  private(set) var isStarting = false

  /// True only while `load()` assigns a restored draft, so `composerText.didSet` doesn't save it back.
  @ObservationIgnored private var loadingDraft = false
  /// The pending debounced draft save; each keystroke cancels it and starts a new one.
  @ObservationIgnored private var draftTask: Task<Void, Never>?
  /// Reads the connectivity stream while the screen is visible; `onDisappear` cancels it.
  @ObservationIgnored private var connectivityTask: Task<Void, Never>?
  /// The live request's ID at the last reload, to detect that the reply completed since then.
  @ObservationIgnored private var lastLiveID: UUID?
  /// The import and preparation task of each tray item that is still working, by item ID. Removing
  /// the item cancels its task. Not `private`, because the Attachments extension in another file
  /// uses it.
  @ObservationIgnored var trayTasks: [UUID: Task<TrayItemOutcome, Never>] = [:]
  @ObservationIgnored private var toastTask: Task<Void, Never>?
  /// Between `onAppear` and `onDisappear`. A send that ends after the user left reads it to decide
  /// whether it must discard the chat if empty (see `send()`).
  @ObservationIgnored private var isOnScreen = false

  init(conversationID: UUID, services: ChatServices) {
    self.conversationID = conversationID
    self.services = services
  }

  // MARK: Lifecycle

  /// Called from `ChatView`'s `.task`, so it runs each time the screen appears; some presentations
  /// (for example a full-screen cover) can make it run again. The flags are set before the first
  /// `await`, so they are true before any other code can run.
  func onAppear() async {
    isOnScreen = true
    // `AppActivity` tells the generation service which chat is visible (no notification for it).
    services.activity.setVisible(conversationID)
    startConnectivity()
    await load()
  }

  /// Called from `ChatView`'s `.onDisappear`, in a new task, when the screen leaves (Back, or another
  /// chat replaces it). The synchronous part runs first; the awaits after it can overlap a new
  /// `onAppear` of another chat's model, which is why `setVisible` clears only this chat's ID.
  func onDisappear() async {
    isOnScreen = false
    services.activity.setVisible(nil, leaving: conversationID)
    connectivityTask?.cancel()
    connectivityTask = nil
    // Save the latest text now; a debounced save still pending would otherwise be lost.
    await flushDraft()
    // An empty chat is discarded when the user leaves it (D§3.3).
    // A send still on its way to its record would find its chat deleted; it discards the chat
    // itself when it ends, if it's still empty then.
    if !isStarting { await services.actions.discardIfEmpty(conversationID) }
  }

  /// Loads the draft and the chat's state.
  func load() async {
    // Restore a saved draft, but never over text typed while it was loading: the user can type
    // during the `await`, so `composerText` is checked after it, not before.
    if let draft = try? await services.store.draftText(conv: conversationID), !draft.isEmpty, composerText.isEmpty {  // try?: a missing chat or draft restores nothing
      loadingDraft = true
      composerText = draft
      loadingDraft = false
    }
    await reload()
  }

  /// Re-reads the chat's state from the store (after any change the transcript shows).
  ///
  /// Each read is a separate `await` on `DataStore`, so the fields can come from slightly different
  /// moments. That is acceptable: every change to the chat's records triggers another reload (see
  /// `ChatView`'s `.onChange(of: signature)`), and a later reload corrects the fields. Two reloads
  /// can overlap; each field then keeps the value of the reload that wrote it last.
  func reload() async {
    let store = services.store
    // No title means the chat is gone (deleted meanwhile); keep the last state.
    guard let title = try? await store.conversationTitle(conversationID) else { return }  // try?: a deleted chat has no title
    self.title = title
    overrides = (try? await store.overrides(conversationID)) ?? ChatOverrides()  // try?: no overrides is the default state
    let pin: (id: UUID?, exists: Bool) = (try? await store.pinState(conv: conversationID)) ?? (nil, false)  // try?: no pin
    pinnedImageID = pin.id
    pinExists = pin.exists
    pinnedImageURL = await imageURL(pin.exists ? pin.id : nil)
    let history = (try? await store.selectorHistory(conv: conversationID)) ?? []  // try?: no history, no implicit base
    implicitBaseID = InputSelector.implicitBase(history: history)
    implicitBaseURL = await imageURL(implicitBaseID)
    let live = try? await store.liveRequest(conv: conversationID)  // try?: read as "no live request"
    // A live request that is now gone completed (in any outcome) while this chat was on screen.
    if lastLiveID != nil && live == nil && services.activity.visibleConversationID == conversationID {
      completedWhileVisible += 1
    }
    lastLiveID = live?.id
    liveRequest = live
  }

  /// The file URL of a stored image, or nil when there is no ID or no record.
  private func imageURL(_ id: UUID?) async -> URL? {
    guard let id, let file = try? await services.store.imageFile(id) else { return nil }  // try?: a deleted image has no URL
    return services.files.url(relative: file.relativePath)
  }

  /// Follows the network path while the screen is visible. The task inherits the main actor from
  /// this method, so it writes `isNetworkUnavailable` on the main thread. `[weak self]` lets the
  /// model be freed while the loop waits; `onDisappear` cancels the task, which ends the loop.
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

  // Computed properties: SwiftUI evaluates them inside `body`, and `@Observable` still tracks the
  // stored properties that they read, so the views redraw when an input changes.

  var defaults: GenerationDefaults { services.settings.generationDefaults() }
  var effective: EffectiveSettings { GenerationSettingsResolver.resolve(overrides, defaults) }
  var trimmedText: String { composerText.trimmingCharacters(in: .whitespacesAndNewlines) }

  /// Send is off while a send is starting, while the chat has a live request, and while the tray
  /// has a pending or failed item. It also needs text or a ready item (D§2.2; `InputSelector.canSend`
  /// holds the rule).
  var canSend: Bool {
    !isStarting && InputSelector.canSend(trimmedText: trimmedText, tray: trayCounts, chatHasLiveRequest: liveRequest != nil)
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
  //
  // The pills and "Chat settings…" both call `setModel`, `setAspect` and `setSize`. Each copies the
  // current `overrides`, changes one field and saves the copy with `changeSetting`.

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

  /// The latest setting change's save; each change waits for the one before it.
  @ObservationIgnored private var settingSave: Task<Void, Never>?

  /// Saves one change to the chat's overrides and logs it as one Chat setting change action. The
  /// model's `overrides` changes only after the save succeeds, so the pills never show a value the
  /// store doesn't hold. Changes affect only future sends (D§3.5).
  ///
  /// Changes run one after another, and each applies `change` to the overrides as they are when its
  /// turn comes. Two pills changed quickly (model, then aspect ratio) would otherwise both start from
  /// the overrides before either save, and the second save would undo the first change.
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

  // MARK: Generation

  /// Sends the composer's text and tray. Both leave the composer at once: the call below can take
  /// seconds (it returns once the body is prepared and the task started), and the composer stays
  /// usable meanwhile; anything attached or typed then is for the next message. If nothing was
  /// recorded, the text and the items come back.
  ///
  /// While the service call waits, the user can type, attach, pin, or leave the screen. Send stays
  /// off (`isStarting`), so a second tap can't start a second request.
  func send() async {
    guard canSend else { return }
    // Everything up to the first `await` runs as one step on the main actor: no tap or keystroke
    // can land between taking the snapshot and clearing the composer.
    let sent = tray
    let draft = SendDraft(
      conversationID: conversationID, promptText: trimmedText, attachments: sent.compactMap(\.staged), settings: effective)
    isStarting = true
    tray = []
    sendCount += 1
    composerText = ""
    // Saves the empty draft now, so a draft save still pending can't write the sent text back.
    await flushDraft()
    do {
      _ = try await services.generation.send(draft)
    } catch {
      if case GenerationError.chatBusy = error { alertMessage = "A request is already running in this chat." }
      // A recorded request shows its failure on its reply card; its staged files now belong to it.
      if !Self.recorded(despite: error) { restoreComposer(text: draft.promptText, items: sent) }
    }
    isStarting = false
    await reload()
    // The user left during the call, and `onDisappear` skipped the empty-chat check because this
    // send was starting. Do it here: a send that recorded nothing leaves the chat empty.
    if !isOnScreen { await services.actions.discardIfEmpty(conversationID) }
    await services.notifications.requestOnFirstSend()
  }

  /// Whether a request record exists although `send` threw (its reply card shows the outcome).
  /// These errors happen after `DataStore` moved the staged files into the request's folder, so
  /// the composer must not take the items back. Any other error happened before the record.
  static func recorded(despite error: any Error) -> Bool {
    switch error as? GenerationError {
    case .preparationFailed, .cancelled, .interrupted: true
    default: false
    }
  }

  /// Puts a send that was never recorded back: its text (unless new text was typed meanwhile) and
  /// its items ahead of any attached since, if their staged files are still there.
  private func restoreComposer(text: String, items: [TrayItem]) {
    if composerText.isEmpty { composerText = text }
    // A file can be gone, for example when `DataStore.createSend` moved some files and then failed
    // before it saved the record. An item without its files would fail at the next send, so it is
    // dropped.
    let intact = items.filter { item in
      [item.originalURL, item.prepared?.url].allSatisfy { url in url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }
    }
    tray = intact + tray
  }

  /// Stop (D§3.5) and a pending card's Cancel. The service records the Stop even when no network
  /// task exists yet (see the primer, *Patterns used in this project*: remembered intent).
  func stop() async {
    guard let live = liveRequest else { return }
    await services.generation.cancel(requestID: live.id)
    await reload()
  }

  /// Regenerate (D§3.6): a new request from the source request's record. `isStarting` blocks a
  /// second Send, Retry or Regenerate until the reload shows the new request.
  func regenerate(requestID: UUID) async {
    guard !isStarting else { return }
    isStarting = true
    // `defer` clears the flag on every exit; it runs after the final `reload()` below.
    defer { isStarting = false }
    do {
      _ = try await services.generation.regenerate(sourceRequestID: requestID)
    } catch GenerationError.chatBusy {
      alertMessage = "A request is already running in this chat."
    } catch GenerationError.inputMissing {
      alertMessage = "An input image was deleted."
    } catch {}  // Other failures are recorded on the request; its reply card shows them.
    await reload()
  }

  /// Retry: a new attempt of the same recorded request, in place (D§6, Regenerate vs Retry).
  func retry(requestID: UUID) async {
    guard !isStarting else { return }
    isStarting = true
    defer { isStarting = false }
    do {
      try await services.generation.retry(requestID: requestID)
    } catch GenerationError.chatBusy {
      alertMessage = "A request is already running in this chat."
    } catch {}  // Other failures are recorded on the request; its reply card shows them.
    await reload()
  }

  // MARK: Messages and images

  /// Delete on a message (D§3.6): cancels the reply's live request first, then deletes the message
  /// and its files, logged as one Delete message action.
  func deleteMessage(_ id: UUID) async {
    let info = try? await services.store.messageInfo(id)  // try?: a message already gone logs as "unknown"
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
      // A request can become live during the awaits above; the store reports every live request
      // it deleted, and each one not cancelled yet is cancelled now.
      for request in result.liveRequestIDs where request != live?.id { await services.generation.cancel(requestID: request) }
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
      await reload()
      return
    }
    pinCount += 1
    await adoptSettings(ofImage: imageID)
    await reload()
    // The chip and pills change at the bottom of the screen, often far from the image the user
    // long-pressed; the toast says what happened where the user is looking at the composer.
    showToast("Editing from this image · \(aspectPillLabel) · \(sizePillLabel)")
  }

  /// Edit from here continues from an image as it was made: the aspect ratio and resolution pills
  /// take the values its request recorded (D§3.6). A value equal to the global default becomes
  /// Default (no override). The model pill stays. An upload has no recorded values and changes nothing.
  private func adoptSettings(ofImage imageID: UUID) async {
    guard let made = try? await services.store.generatedSettings(ofImage: imageID) else { return }  // try?: a failed read leaves the pills as they are.
    if let ratio = made.aspectRatio {
      let override = ratio == defaults.aspectRatio ? nil : ratio
      if override != overrides.aspectRatio { await setAspect(override, from: .editFromHere) }
    }
    if let size = made.imageSize {
      let override = size == defaults.imageSize ? nil : size
      if override != overrides.imageSize { await setSize(override, from: .editFromHere) }
    }
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
    guard let origin = try? await services.store.originatingUserMessage(requestID: requestID) else { return }  // try?: no user message, no Edit
    await editAndResend(userMessageID: origin.id, requestID: requestID)
  }

  // MARK: Chat

  /// New Chat from this chat (a refused card's button): opens it in place of this one (D§3.4).
  /// Replacing the top of the navigation stack makes this screen disappear; its `onDisappear` keeps
  /// the refused chat, because it has messages.
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
  /// The title when editing began: an untouched draft changes nothing, even if the automatic
  /// title arrived meanwhile.
  @ObservationIgnored private var titleAtEditStart = ""

  func beginTitleEdit() {
    titleDraft = title
    titleAtEditStart = title
  }

  /// Renames when the text changed; an empty name reverts to the automatic title, as in the alert.
  func commitTitleEdit() async {
    guard let draft = titleDraft else { return }
    // Cleared before the `await`, so a second commit (Return and ✓ together) finds no draft.
    titleDraft = nil
    guard let name = TitleEdit.change(draft: draft, current: titleAtEditStart) else { return }
    await rename(to: name)
  }

  func cancelTitleEdit() {
    titleDraft = nil
  }

  /// Delete chat from the chat menu. `ChatActions.deleteChat` cancels the live request, deletes the
  /// chat and its files, and pops this screen.
  func deleteChat() async {
    await services.actions.deleteChat(conversationID)
  }

  // MARK: Toast

  /// Shows `text` over the composer for 2.5 s. A new toast replaces the current one and restarts the
  /// timer: the old task is cancelled, and the check after its sleep stops it from clearing the new
  /// toast. (Cancellation is cooperative: `cancel()` only sets a flag, so the code checks it.)
  func showToast(_ text: String) {
    toast = text
    toastTask?.cancel()
    toastTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(2.5))  // try?: a cancelled sleep ends early; the guard below handles it
      guard !Task.isCancelled else { return }
      self?.toast = nil
    }
  }

  // MARK: Draft

  /// The draft debounce (D§3.5: `Conversation.draftText`, 500 ms). Each change cancels the pending
  /// save and starts a new one, so only a pause in typing writes to the store.
  private func scheduleDraftSave() {
    draftTask?.cancel()
    // Captured now, as plain values: the task saves the text of this keystroke, and it doesn't
    // need `self`, so a pending save doesn't keep the model alive.
    let text = composerText
    let store = services.store
    let id = conversationID
    let delay = services.draftDebounce
    draftTask = Task {
      try? await Task.sleep(for: delay)  // try?: a cancelled sleep ends early; the guard below handles it
      guard !Task.isCancelled else { return }
      // The guard and this call are not one step: a cancel that lands during the save is too late.
      // The save that cancelled it (the next debounce, or `flushDraft`) then writes the newer text.
      try? await store.setDraft(id, text: text)  // try?: a lost draft save is harmless; the next change saves again
    }
  }

  /// Saves the current text now and drops the pending save. `send()` calls it to store the empty
  /// draft; `onDisappear` calls it so the last keystrokes aren't lost.
  func flushDraft() async {
    draftTask?.cancel()
    draftTask = nil
    try? await services.store.setDraft(conversationID, text: composerText)  // try?: a deleted chat has no draft to save
  }
}
