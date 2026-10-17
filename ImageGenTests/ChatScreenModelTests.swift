import Foundation
import Testing

@testable import ImageGen

/// Mock implementation of `GenerationServicing` capturing dispatched requests and providing synchronization test gates.
final class FakeGeneration: GenerationServicing {
  let sends = Locked<[SendDraft]>([])
  let cancels = Locked<[UUID]>([])
  let retries = Locked<[UUID]>([])
  let regenerates = Locked<[UUID]>([])

  /// Optional suspension hook invoked inside `send` to permit concurrent test actions during dispatch.
  let sendGate = Locked<(@Sendable () async -> Void)?>(nil)
  /// Configured error instance thrown by `send` post-gate to simulate dispatch failures.
  let sendError = Locked<(any Error)?>(nil)

  func send(_ d: SendDraft) async throws -> UUID {
    sends.withLock { $0.append(d) }
    if let gate = sendGate.value { await gate() }
    if let error = sendError.value { throw error }
    return UUID()
  }
  func regenerate(sourceRequestID: UUID) async throws -> UUID {
    regenerates.withLock { $0.append(sourceRequestID) }
    return UUID()
  }
  func retry(requestID: UUID) async throws { retries.withLock { $0.append(requestID) } }
  func cancel(requestID: UUID) async { cancels.withLock { $0.append(requestID) } }
}

struct FakeAuthorizer: NotificationAuthorizing {
  let calls = Locked(0)
  func request() async -> (granted: Bool, status: String) {
    calls.withLock { $0 += 1 }
    return (true, "authorized")
  }
}

@MainActor
@Suite(.tags(.integration))
struct ChatScreenModelTests {
  @MainActor
  final class Rig {
    let s: InMemoryStore
    let probe: ActivityLogProbe
    let suite = "ImageGenTests.\(UUID().uuidString)"
    let settings: AppSettings
    let generation = FakeGeneration()
    let connectivity = FakeConnectivityMonitor()
    let activity = AppActivity(isActive: true)
    let navigator = Navigator()
    let authorizer = FakeAuthorizer()
    var copied: [String] = []
    let conv: UUID
    let model: ChatScreenModel

    init(
      prepareUpload: (@Sendable (URL, Int, URL, UUID) async throws -> PreparedImage)? = nil
    ) async throws {
      s = try InMemoryStore()
      probe = ActivityLogProbe(root: s.root)
      let ud = UserDefaults(suiteName: suite)!
      settings = AppSettings(defaults: ud)
      conv = try await s.store.createConversation()
      navigator.path = [conv]
      var services = ChatServices(
        store: s.store, files: s.files, generation: generation, settings: settings, log: probe.log, connectivity: connectivity,
        activity: activity, notifications: NotificationPermission(authorizer: authorizer, defaults: ud, log: probe.log),
        navigator: navigator, thumbnails: ThumbnailService(directory: s.files.thumbnailsDir),
        copyToPasteboard: { _ in }, draftDebounce: .milliseconds(100))
      if let prepareUpload { services.prepareUpload = prepareUpload }
      model = ChatScreenModel(conversationID: conv, services: services)
      await model.load()
    }

    deinit { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

    /// Synthesizes and persists a completed generation turn containing a generated model image, returning the record and image identifier.
    func imageTurn(_ prompt: String = "draw") async throws -> (SendRecord, UUID) {
      let record = try await s.send(conv, prompt: prompt)
      let id = UUID()
      let relative = s.files.imageRelativePath(conv: conv, image: id, ext: "png")
      try FileStore.createDirectory(s.files.url(relative: relative).deletingLastPathComponent())
      try ImageFactory.png().write(to: s.files.url(relative: relative))
      var patch = RequestPatch()
      patch.state = .succeeded
      try await s.store.completeReply(
        requestID: record.requestID, parts: [MessagePart(kind: .image, text: nil, imageID: id)],
        images: [ReplyImage(id: id, relativePath: relative, mimeType: "image/png", byteCount: 10, pixelWidth: 32, pixelHeight: 18)],
        notices: [], outcomeFields: patch)
      await model.reload()
      return (record, id)
    }
  }

  @Test func sendEnablement() async throws {
    let r = try await Rig()
    #expect(!r.model.canSend)
    r.model.composerText = "   "
    #expect(!r.model.canSend)
    r.model.composerText = "a red fox"
    #expect(r.model.canSend)
    r.model.tray = [.fake(.ready), .fake(.preparing)]
    #expect(!r.model.canSend)
    r.model.tray = [.fake(.ready)]
    r.model.composerText = ""
    #expect(r.model.canSend)
    r.model.tray = []
    r.model.composerText = "x"
    let record = try await r.s.send(r.conv, prompt: "running")
    try await r.s.store.updateRequest(record.requestID) { $0.state = .inFlight }
    await r.model.reload()
    #expect(!r.model.canSend)
  }

  @Test func pillsShowDefaults16x9And2K() async throws {
    let r = try await Rig()
    #expect(r.model.modelPillLabel == "3.1 Flash")
    #expect(r.model.aspectPillLabel == "16:9")
    #expect(r.model.sizePillLabel == "2K")
    #expect(!r.model.modelOverridden && !r.model.aspectOverridden && !r.model.sizeOverridden)
  }

  @Test func defaultItemLabelFollowsGlobalDefault() async throws {
    let r = try await Rig()
    #expect(r.model.defaultAspectItemLabel == "Default (16:9)")
    #expect(r.model.defaultSizeItemLabel == "Default (2K)")
    r.settings.defaultAspectRatio = .r1x1
    r.settings.defaultImageSize = .s1K
    #expect(r.model.defaultAspectItemLabel == "Default (1:1)")
    #expect(r.model.defaultSizeItemLabel == "Default (1K)")
    r.settings.defaultAspectRatio = .r1x8
    await r.model.setModel("gemini-3-pro-image", from: .pill)
    #expect(r.model.defaultAspectItemLabel == "Default (16:9 ⚠︎)")
  }

  @Test func overrideSetsDotAndPersists() async throws {
    let r = try await Rig()
    await r.model.setAspect(.r1x1, from: .pill)
    #expect(r.model.aspectOverridden)
    #expect(r.model.aspectPillLabel == "1:1")
    #expect(try await r.s.store.overrides(r.conv).aspectRatio == .r1x1)
  }

  @Test func chooseDefaultClearsOverride() async throws {
    let r = try await Rig()
    await r.model.setSize(.s4K, from: .pill)
    await r.model.setSize(nil, from: .pill)
    #expect(!r.model.sizeOverridden)
    #expect(r.model.sizePillLabel == "2K")
    #expect(try await r.s.store.overrides(r.conv).imageSize == nil)
  }

  @Test func proHidesExtremeRatiosAnd512() async throws {
    let r = try await Rig()
    #expect(r.model.aspectSections.contains { $0.group == .extreme })
    #expect(r.model.sizes.contains(.s512))
    await r.model.setModel("gemini-3-pro-image", from: .pill)
    #expect(!r.model.aspectSections.contains { $0.group == .extreme })
    #expect(!r.model.sizes.contains(.s512))
    #expect(r.model.modelPillLabel == "3 Pro")
  }

  @Test func coercionShowsCaution() async throws {
    let r = try await Rig()
    await r.model.setAspect(.r1x8, from: .pill)
    #expect(!r.model.isCoerced(.aspectRatio))
    await r.model.setModel("gemini-3-pro-image", from: .pill)
    #expect(r.model.isCoerced(.aspectRatio))
    #expect(r.model.aspectPillLabel == "16:9")
  }

  @Test func disabledModelOverrideShowsFlashWithCaution() async throws {
    let r = try await Rig()
    await r.model.setModel("gemini-3-pro-image", from: .pill)
    r.settings.setModel("gemini-3-pro-image", enabled: false)
    #expect(r.model.modelPillLabel == "3.1 Flash")
    #expect(r.model.isCoerced(.model))
    #expect(!r.model.menuModels.contains { $0.id == "gemini-3-pro-image" })
  }

  @Test func menuModelsFollowAvailability() async throws {
    let r = try await Rig()
    #expect(!r.model.menuModels.contains { $0.id == "gemini-3-pro-image-preview" })
    #expect(r.model.menuModels.count == 5)
    r.settings.modelAvailabilityCache = ModelAvailabilityCache(
      models: ["gemini-3-pro-image": true, "gemini-3-pro-image-preview": true], checkedAt: Date())
    #expect(r.model.menuModels.map(\.id) == ["gemini-3.1-flash-image", "gemini-3-pro-image", "gemini-3-pro-image-preview"])
  }

  @Test func implicitChipIsInformational() async throws {
    let r = try await Rig()
    #expect(!r.model.showsImplicitChip)
    let (_, image) = try await r.imageTurn()
    #expect(r.model.showsImplicitChip)
    #expect(r.model.implicitBaseID == image)
    #expect(r.model.implicitBaseURL != nil)
    #expect(!r.model.showsPinChip)
    let history = try await r.s.store.selectorHistory(conv: r.conv)
    let selection = InputSelector.select(SelectionInput(attachments: [], pinnedImageID: nil, pinnedImageExists: false, history: history))
    #expect(selection.reason == .latest)
    #expect(selection.imageIDs == [image])
  }

  @Test func editFromHereTakesTheImagesAspectAndSize() async throws {
    let r = try await Rig()
    // Simulates an image generated under 16:9 · 2K defaults while current conversation settings have diverged to 9:16 · 4K.
    let (_, image) = try await r.imageTurn()
    await r.model.setAspect(.r9x16, from: .pill)
    await r.model.setSize(.s4K, from: .pill)
    await r.model.pin(image)
    #expect(r.model.pinnedImageID == image)
    #expect(r.model.overrides.aspectRatio == nil && r.model.overrides.imageSize == nil)
    #expect(r.model.aspectPillLabel == "16:9" && r.model.sizePillLabel == "2K")
    let changes = await r.probe.entries().filter { $0.name == "Chat setting change" && $0.kind == .begin }
    #expect(changes.filter { $0.message.hasSuffix("Edit from here") }.count == 2)
  }

  @Test func editFromHereWithoutRecordedSettingsLeavesThePills() async throws {
    let r = try await Rig()
    await r.model.setAspect(.r9x16, from: .pill)
    // Evaluates pinning an unassociated image identifier lacking recorded generation settings.
    await r.model.pin(UUID())
    #expect(r.model.overrides.aspectRatio == .r9x16)
  }

  @Test func pinChipDimmedWithAttachments() async throws {
    let r = try await Rig()
    let (_, image) = try await r.imageTurn()
    await r.model.pin(image)
    #expect(r.model.showsPinChip)
    #expect(!r.model.pinChipDimmed)
    #expect(!r.model.showsImplicitChip)
    r.model.tray = [.fake(.ready)]
    #expect(r.model.pinChipDimmed)
    await r.model.unpin()
    #expect(!r.model.showsPinChip)
  }

  @Test func waitingForNetworkLabel() async throws {
    let r = try await Rig()
    await r.model.onAppear()
    let record = try await r.s.send(r.conv, prompt: "x")
    try await r.s.store.updateRequest(record.requestID) { $0.state = .inFlight }
    await r.model.reload()
    r.connectivity.set(false)
    try await waitUntil { r.model.isNetworkUnavailable }
    #expect(r.model.showsWaitingForNetwork)
    r.connectivity.set(true)
    try await waitUntil { !r.model.isNetworkUnavailable }
    #expect(!r.model.showsWaitingForNetwork)
    try await r.s.store.updateRequest(record.requestID) { $0.state = .preparing }
    await r.model.reload()
    r.connectivity.set(false)
    try await waitUntil { r.model.isNetworkUnavailable }
    #expect(!r.model.showsWaitingForNetwork)
    await r.model.onDisappear()
  }

  func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
    #expect(condition())
  }

  @Test func stopCancels() async throws {
    let r = try await Rig()
    let record = try await r.s.send(r.conv, prompt: "x")
    try await r.s.store.updateRequest(record.requestID) { $0.state = .inFlight }
    await r.model.reload()
    await r.model.stop()
    #expect(r.generation.cancels.value == [record.requestID])
  }

  @Test func sendForwardsDraftAndClearsComposer() async throws {
    let r = try await Rig()
    r.model.composerText = "  a red fox  "
    await r.model.send()
    let sent = try #require(r.generation.sends.value.first)
    #expect(sent.promptText == "a red fox")
    #expect(sent.settings.aspectRatio == .r16x9)
    #expect(r.model.composerText.isEmpty)
    #expect(r.model.sendCount == 1)
  }

  @Test func draftDebounced() async throws {
    let r = try await Rig()
    r.model.composerText = "a"
    r.model.composerText = "ab"
    r.model.composerText = "abc"
    #expect(try await r.s.store.draftText(conv: r.conv) == "")
    try await Task.sleep(for: .milliseconds(300))
    #expect(try await r.s.store.draftText(conv: r.conv) == "abc")
  }

  @Test func refusedCardEditLoadsComposerAndFocuses() async throws {
    let r = try await Rig()
    let (_, image) = try await r.imageTurn()
    let refused = try await r.s.send(
      r.conv, prompt: "a red fox", selection: Selection(imageIDs: [image], reason: .latest, clearPin: false))
    try await r.s.store.updateRequest(refused.requestID) { $0.state = .refused }
    await r.model.reload()

    // Requires confirmation before overwriting non-empty existing composer draft content.
    r.model.composerText = "draft in progress"
    await r.model.editRefused(requestID: refused.requestID)
    #expect(r.model.pendingEdit != nil)
    #expect(r.model.composerText == "draft in progress")

    await r.model.editAndResend(userMessageID: r.model.pendingEdit!.userMessageID, requestID: refused.requestID, confirmed: true)
    #expect(r.model.composerText == "a red fox")
    #expect(r.model.isTextFieldFocused)
    #expect(try await r.s.store.pinState(conv: r.conv).id == image)
    #expect(r.generation.sends.value.isEmpty)
  }

  @Test func refusedCardEditOnRegeneratedReplyTargetsSourceMessage() async throws {
    let r = try await Rig()
    let first = try await r.s.send(r.conv, prompt: "the original prompt")
    try await r.s.store.updateRequest(first.requestID) { $0.state = .succeeded }
    let regen = try #require(try await r.s.store.createRegenerate(sourceRequestID: first.requestID, activityActionID: ActionID(raw: "0001")))
    try await r.s.store.updateRequest(regen.requestID) { $0.state = .refused }
    await r.model.editRefused(requestID: regen.requestID)
    #expect(r.model.composerText == "the original prompt")
  }

  @Test func refusedCardNewChatCreatesAndNavigates() async throws {
    let r = try await Rig()
    try await r.s.send(r.conv, prompt: "x")
    await r.model.newChat()
    let newID = try #require(r.navigator.path.last)
    #expect(r.navigator.path.count == 1)
    #expect(newID != r.conv)
    #expect(try await r.s.store.selectorHistory(conv: newID).isEmpty)
    #expect(try await r.s.store.selectorHistory(conv: r.conv).count == 2)
  }

  @Test func chatActionsLogged() async throws {
    let r = try await Rig()
    let (record, image) = try await r.imageTurn("Lighthouse prompt")
    try await r.s.store.rename(r.conv, to: "Lighthouse")
    await r.model.rename(to: "Harbor")
    await r.model.pin(image)
    await r.model.unpin()
    r.model.copy("Lighthouse prompt", kind: .prompt)
    await r.model.deleteMessage(record.userMessageID)
    await r.model.newChat()
    await r.model.deleteChat()

    let entries = await r.probe.entries()
    for name in ["New chat", "Rename chat", "Delete chat", "Delete message", "Pin", "Unpin", "Copy"] {
      #expect(entries.contains { $0.name == name && $0.kind == .begin && $0.origin == .user }, "\(name) begin")
      #expect(entries.contains { $0.name == name && $0.kind == .result && $0.outcome == .success }, "\(name) result")
    }
    let rename = try #require(entries.first { $0.name == "Rename chat" && $0.kind == .begin })
    #expect(rename.message == "chat \(Format.short(r.conv)) · \"Lighthouse\" → \"Harbor\"")
    #expect(entries.contains { $0.name == "Pin" && $0.message == "chat \(Format.short(r.conv)) · img \(Format.short(image))" })
    #expect(entries.contains { $0.name == "Copy" && $0.message == "prompt · 17 characters" })
    let mirror = try #require(r.probe.mirrorCalls.first { $0.entry.name == "Rename chat" && $0.entry.kind == .begin })
    #expect(mirror.publicText == "chat \(Format.short(r.conv)) · <private> → <private>")
    await r.probe.assertPaired()
  }

  @Test func leavingEmptyChatDeletesItAndLogs() async throws {
    let r = try await Rig()
    await r.model.onDisappear()
    await #expect(throws: (any Error).self) { try await r.s.store.messageCount(conv: r.conv) }
    let entries = await r.probe.entries().filter { $0.name == "Delete empty chat" }
    #expect(entries.map(\.kind) == [.begin, .result])
    #expect(entries.first?.origin == .system)
    #expect(entries.first?.message == "chat \(Format.short(r.conv)) · left with no messages")
    #expect(entries.last?.outcome == .success)
    await r.probe.assertPaired()
  }

  @Test func leavingChatWithMessagesKeepsItAndLogsNothing() async throws {
    let r = try await Rig()
    _ = try await r.imageTurn()
    await r.model.onDisappear()
    #expect(try await r.s.store.messageCount(conv: r.conv) == 2)
    #expect(!(await r.probe.entries().contains { $0.name == "Delete empty chat" }))
  }

  @Test func inlineTitleEditCommitsRename() async throws {
    let r = try await Rig()
    try await r.s.store.rename(r.conv, to: "Lighthouse")
    await r.model.reload()
    r.model.beginTitleEdit()
    #expect(r.model.isEditingTitle)
    #expect(r.model.titleDraft == "Lighthouse")
    r.model.titleDraft = "  Harbor at night  "
    await r.model.commitTitleEdit()
    #expect(!r.model.isEditingTitle)
    #expect(r.model.title == "Harbor at night")
    #expect(try await r.s.store.conversationTitle(r.conv) == "Harbor at night")
    let rename = await r.probe.action(named: "Rename chat")
    #expect(rename.first?.message == "chat \(Format.short(r.conv)) · \"Lighthouse\" → \"Harbor at night\"")
    #expect(rename.last?.outcome == .success)
  }

  @Test func inlineTitleEditCancelKeepsTitle() async throws {
    let r = try await Rig()
    try await r.s.store.rename(r.conv, to: "Lighthouse")
    await r.model.reload()
    r.model.beginTitleEdit()
    r.model.titleDraft = "Something else"
    r.model.cancelTitleEdit()
    #expect(!r.model.isEditingTitle)
    await r.model.commitTitleEdit()
    #expect(try await r.s.store.conversationTitle(r.conv) == "Lighthouse")
    #expect(await r.probe.action(named: "Rename chat").isEmpty)
  }

  @Test func inlineTitleEditUnchangedIsNotLogged() async throws {
    let r = try await Rig()
    try await r.s.store.rename(r.conv, to: "Lighthouse")
    await r.model.reload()
    r.model.beginTitleEdit()
    r.model.titleDraft = "Lighthouse "
    await r.model.commitTitleEdit()
    #expect(!r.model.isEditingTitle)
    #expect(await r.probe.action(named: "Rename chat").isEmpty)
  }

  @Test func inlineTitleEditEmptyRevertsToAutomaticTitle() async throws {
    let r = try await Rig()
    try await r.s.send(r.conv, prompt: "a red fox in the snow")
    try await r.s.store.rename(r.conv, to: "Fox")
    await r.model.reload()
    r.model.beginTitleEdit()
    r.model.titleDraft = "   "
    await r.model.commitTitleEdit()
    #expect(r.model.title == "a red fox in the snow")
  }

  @Test func chatSettingChangesLogged() async throws {
    let r = try await Rig()
    await r.model.setAspect(.r1x1, from: .pill)
    await r.model.setAspect(nil, from: .pill)
    await r.model.setModel("gemini-3-pro-image", from: .chatSettings)
    await r.model.setSize(.s512, from: .chatSettings)
    let changes = await r.probe.entries().filter { $0.name == "Chat setting change" }
    let begins = changes.filter { $0.kind == .begin }.map(\.message)
    let c = Format.short(r.conv)
    #expect(begins == [
      "chat \(c) · aspect ratio 16:9 → 1:1 · pill", "chat \(c) · aspect ratio 1:1 → Default · pill",
      "chat \(c) · model 3.1 Flash → 3 Pro · Chat settings…", "chat \(c) · resolution 2K → 512 · Chat settings…",
    ])
    let results = changes.filter { $0.kind == .result }
    #expect(results.last?.message == "saved · effective 1K (coerced)")
    #expect(results.first?.message == "saved · effective 1:1")
    await r.probe.assertPaired()
  }

  @Test func notificationPermissionLogged() async throws {
    let r = try await Rig()
    let send = r.probe.log.begin("Send", origin: .user, "first")
    r.model.composerText = "one"
    await r.model.send()
    r.probe.log.result(send, .success, "")
    r.model.composerText = "two"
    await r.model.send()
    let actions = await r.probe.entries().filter { $0.name == "Notification permission" }
    #expect(actions.count == 2)
    #expect(actions.first?.origin == .system)
    #expect(actions.last?.message == "granted · authorization authorized")
    #expect(r.authorizer.calls.value == 1)
    #expect(ActivityLogQuery.lastAction(await r.probe.records()) == send)
  }
}

@Suite(.tags(.pure))
struct TitleEditTests {
  @Test func changeRule() {
    #expect(TitleEdit.change(draft: "  Harbor  ", current: "Lighthouse") == "Harbor")
    #expect(TitleEdit.change(draft: "Lighthouse ", current: "Lighthouse") == nil)
    #expect(TitleEdit.change(draft: "   ", current: "Lighthouse") == "")
  }
}
