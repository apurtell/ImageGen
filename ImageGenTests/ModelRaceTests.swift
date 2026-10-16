import Foundation
import Testing

@testable import ImageGen

/// User actions that overlap an await in a screen model (post-M9 concurrency review).
@MainActor
@Suite(.tags(.integration))
struct ModelRaceTests {
  typealias Rig = ChatScreenModelTests.Rig

  /// A ready tray item whose staged files exist.
  func stagedItem(_ r: Rig) throws -> TrayItem {
    let id = UUID()
    let original = r.s.files.stagingURL(id, ext: "png")
    let prepared = r.s.files.stagingDir.appendingPathComponent("prepared/\(id.uuidString)-2048.jpg")
    for url in [original, prepared] {
      try FileStore.createDirectory(url.deletingLastPathComponent())
      try ImageFactory.png().write(to: url)
    }
    return TrayItem(
      id: id, origin: .photos,
      state: .ready(
        PreparedImage(url: prepared, mimeType: "image/jpeg", byteCount: 100, pixelWidth: 32, pixelHeight: 18, longEdgeSetting: 2048)),
      originalURL: original, originalMimeType: "image/png", originalByteCount: 100, pixelWidth: 32, pixelHeight: 18)
  }

  @Test func attachmentsAddedDuringASendStayForTheNextMessage() async throws {
    let r = try await Rig()
    let gate = ManualSleeper()
    r.generation.sendGate.withLock { $0 = { await gate.sleep(.zero) } }
    let sent = try stagedItem(r)
    r.model.tray = [sent]
    r.model.composerText = "first"
    let sending = Task { await r.model.send() }
    try await waitUntil { gate.waitingCount == 1 }
    // The tray empties at once; Send is off until the send returns.
    #expect(r.model.tray.isEmpty)
    #expect(!r.model.canSend)
    let next = try stagedItem(r)
    r.model.tray.append(next)
    r.model.composerText = "second"
    gate.advance()
    await sending.value
    #expect(r.model.tray.map(\.id) == [next.id])
    #expect(r.model.composerText == "second")
    #expect(r.generation.sends.value.first?.attachments.map(\.id) == [sent.id])
  }

  @Test func aSendThatWasNeverRecordedGivesBackItsTextAndItems() async throws {
    let r = try await Rig()
    r.generation.sendError.withLock { $0 = GenerationError.chatBusy }
    let item = try stagedItem(r)
    r.model.tray = [item]
    r.model.composerText = "keep me"
    await r.model.send()
    #expect(r.model.alertMessage == "A request is already running in this chat.")
    #expect(r.model.composerText == "keep me")
    #expect(r.model.tray.map(\.id) == [item.id])
  }

  @Test func aRecordedFailureLeavesTheComposerEmpty() async throws {
    let r = try await Rig()
    r.generation.sendError.withLock { $0 = GenerationError.preparationFailed(.network) }
    r.model.tray = [try stagedItem(r)]
    r.model.composerText = "x"
    await r.model.send()
    #expect(r.model.composerText.isEmpty)
    #expect(r.model.tray.isEmpty)
  }

  @Test func leavingANewChatMidSendKeepsIt() async throws {
    let r = try await Rig()
    let gate = ManualSleeper()
    r.generation.sendGate.withLock { $0 = { await gate.sleep(.zero) } }
    await r.model.onAppear()
    r.model.composerText = "first message"
    let sending = Task { await r.model.send() }
    try await waitUntil { gate.waitingCount == 1 }
    await r.model.onDisappear()
    #expect((try? await r.s.store.conversationTitle(r.conv)) != nil)
    gate.advance()
    await sending.value
  }

  @Test func doubleTapRetryRunsOnce() async throws {
    let r = try await Rig()
    let id = UUID()
    async let a: Void = r.model.retry(requestID: id)
    async let b: Void = r.model.retry(requestID: id)
    _ = await (a, b)
    #expect(r.generation.retries.value.count == 1)
  }

  @Test func untouchedTitleDraftKeepsTheAutomaticTitle() async throws {
    let r = try await Rig()
    r.model.beginTitleEdit()
    // The first send names the chat while the field is open.
    _ = try await r.s.send(r.conv, prompt: "a lighthouse at dusk")
    await r.model.reload()
    let automatic = r.model.title
    #expect(automatic != Conversation.untitled)
    await r.model.commitTitleEdit()
    #expect(r.model.title == automatic)
    #expect(await r.probe.action(named: "Rename chat").isEmpty)
  }

  // MARK: Settings

  @Test func cancellingReplaceKeyDuringValidationKeepsTheOldKey() async throws {
    let rig = OnboardingModelTests.Rig()
    try rig.keyStore.save("AIzaSyOLD-saved-key-0123456789abcdefghij")
    let models = rig.models
    MockURLProtocol.register(
      [.init(status: 200, body: try FixtureLoader.data("Models/models_no_flash.json"), delay: .milliseconds(300))],
      for: ModelsClientTests.list, token: models.token)
    rig.model.keyText = OnboardingModelTests.typed
    let saving = Task { await rig.model.validateAndSave() }
    try await Task.sleep(for: .milliseconds(50))
    rig.model.cancel()
    #expect(await saving.value == false)
    #expect(try rig.keyStore.read() == "AIzaSyOLD-saved-key-0123456789abcdefghij")
    #expect(await rig.probe.action(named: "Save API key").last?.outcome == .cancelled)
  }

  func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
    #expect(condition())
  }
}
