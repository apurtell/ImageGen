import Foundation
import SwiftData
import Testing

@testable import ImageGen

@Suite(.tags(.io))
struct DataStoreTests {
  @Test func createSendMovesStagedFiles() async throws {
    let s = try InMemoryStore()
    let conv = try await s.store.createConversation()
    let a = try s.stage()
    let originalBytes = try Data(contentsOf: a.originalURL)
    let preparedBytes = try Data(contentsOf: a.prepared.url)
    let record = try await s.send(conv, prompt: "edit this", attachments: [a])

    #expect(!FileManager.default.fileExists(atPath: a.originalURL.path))
    #expect(!FileManager.default.fileExists(atPath: a.prepared.url.path))
    let snaps = try await s.store.imageSnapshots(messageID: record.userMessageID)
    let snap = try #require(snaps.first)
    #expect(snap.originalRelativePath == "Images/\(conv.uuidString)/\(a.id.uuidString).png")
    #expect(try Data(contentsOf: s.files.url(relative: snap.originalRelativePath)) == originalBytes)
    let prepared = try #require(snap.prepared)
    #expect(prepared.preparedRelativePath == "Images/\(conv.uuidString)/prepared/\(a.id.uuidString)-2048.jpg")
    #expect(try Data(contentsOf: s.files.url(relative: prepared.preparedRelativePath)) == preparedBytes)
  }

  @Test func createSendRecordsSettingsAndReason() async throws {
    let s = try InMemoryStore()
    let conv = try await s.store.createConversation()
    let a = try s.stage()
    var settings = InMemoryStore.settings
    settings.aspectRatio = .r9x16
    settings.imageSize = .s4K
    settings.threshold = .blockOnlyHigh
    settings.categories = Array(HarmCategory.allCases.prefix(4))
    settings.coercions = [Coercion(field: .imageSize, requested: "512", used: "4K", reason: "test")]
    let record = try await s.send(conv, prompt: "go", attachments: [a], settings: settings, action: ActionID(raw: "c0de"))

    let snap = try #require(try await s.store.requestSnapshot(record.requestID))
    var recorded = settings
    recorded.coercions = []
    #expect(snap.settings == recorded)
    #expect(snap.selectionReason == .attachments)
    #expect(snap.state == .preparing)
    #expect(snap.attempt == 0)
    #expect(snap.autoRetriesUsed == 0)
    #expect(!snap.civicFallbackUsed)
    #expect(snap.maxAutoRetries == 2)
    #expect(snap.activityActionID == ActionID(raw: "c0de"))
    #expect(snap.userMessageID == record.userMessageID)
    #expect(snap.replyMessageID == record.replyMessageID)
    #expect(snap.promptText == "go")
    #expect(snap.inputs.map(\.imageID) == [a.id])
    #expect(snap.inputs.first?.mimeType == "image/jpeg")
    #expect(snap.inputAssets.map(\.imageID) == [a.id])
  }

  @Test func createSendOrdinalsFollowTrayOrder() async throws {
    let s = try InMemoryStore()
    let conv = try await s.store.createConversation()
    let a = try s.stage(seed: 1)
    let b = try s.stage(seed: 2)
    let c = try s.stage(seed: 3)
    // The tray was reordered to b, c, a before sending.
    let record = try await s.send(conv, prompt: "", attachments: [b, c, a])
    let history = try await s.store.selectorHistory(conv: conv)
    let user = try #require(history.first { $0.role == .user })
    #expect(user.images.map(\.id) == [b.id, c.id, a.id])
    #expect(user.images.map(\.ordinal) == [0, 1, 2])
    #expect(try await s.store.imageSnapshots(messageID: record.userMessageID).map(\.imageID) == [b.id, c.id, a.id])
    #expect(try await s.store.requestSnapshot(record.requestID)?.inputs.map(\.imageID) == [b.id, c.id, a.id])
  }

  @Test func createSendCopiesPreparedFields() async throws {
    let s = try InMemoryStore()
    let conv = try await s.store.createConversation()
    let a = try s.stage(width: 40, height: 30, edge: 3072)
    let record = try await s.send(conv, prompt: "x", attachments: [a])
    let snap = try #require(try await s.store.imageSnapshots(messageID: record.userMessageID).first)
    #expect(snap.prepared?.mimeType == "image/jpeg")
    #expect(snap.prepared?.byteCount == a.prepared.byteCount)
    #expect(snap.prepared?.pixelWidth == 40)
    #expect(snap.prepared?.pixelHeight == 30)
    #expect(snap.preparedLongEdgeSetting == 3072)
    #expect(snap.origin == .photos)
    #expect(snap.originalMimeType == "image/png")
  }

  @Test func completeReplyOrdinalsFollowImagePartOrder() async throws {
    let s = try InMemoryStore()
    let conv = try await s.store.createConversation()
    let record = try await s.send(conv, prompt: "two images")
    let i1 = UUID()
    let i2 = UUID()
    let parts = [
      MessagePart(kind: .text, text: "First", imageID: nil), MessagePart(kind: .image, text: nil, imageID: i1),
      MessagePart(kind: .text, text: "Second", imageID: nil), MessagePart(kind: .image, text: nil, imageID: i2),
    ]
    let images = [i1, i2].map {
      ReplyImage(id: $0, relativePath: "Images/\(conv.uuidString)/\($0.uuidString).png", mimeType: "image/png", byteCount: 10, pixelWidth: 16, pixelHeight: 9)
    }
    var patch = RequestPatch()
    patch.state = .succeeded
    patch.finishReason = "STOP"
    try await s.store.completeReply(requestID: record.requestID, parts: parts, images: images, notices: [], outcomeFields: patch)

    let reply = try #require(try await s.store.selectorHistory(conv: conv).first { $0.role == .model })
    #expect(reply.images == [SelectorImage(id: i1, ordinal: 0), SelectorImage(id: i2, ordinal: 1)])
    #expect(reply.replyState == .succeeded)
    #expect(try await s.store.imageSnapshots(messageID: record.replyMessageID).map(\.origin) == [.model, .model])
    #expect(try await s.store.requestSnapshot(record.requestID)?.state == .succeeded)
  }

  @Test func completeReplyStoresNotices() async throws {
    let s = try InMemoryStore()
    let conv = try await s.store.createConversation()
    let record = try await s.send(conv, prompt: "x")
    var patch = RequestPatch()
    patch.state = .succeeded
    try await s.store.completeReply(
      requestID: record.requestID, parts: [MessagePart(kind: .text, text: "hi", imageID: nil)], images: [],
      notices: ["1 image could not be decoded"], outcomeFields: patch)
    let notices = try await s.store.withRequest(record.requestID) { $0.notices }
    #expect(notices == ["1 image could not be decoded"])
  }

  @Test func setPreparedFileUpdatesAsset() async throws {
    let s = try InMemoryStore()
    let conv = try await s.store.createConversation()
    let a = try s.stage(edge: 2048)
    let record = try await s.send(conv, prompt: "x", attachments: [a])
    let input = RequestInput(
      imageID: a.id, preparedRelativePath: "Images/\(conv.uuidString)/prepared/\(a.id.uuidString)-4096.jpg", mimeType: "image/jpeg",
      byteCount: 999, pixelWidth: 64, pixelHeight: 36)
    try await s.store.setPreparedFile(imageID: a.id, input, longEdgeSetting: 4096)
    let snap = try #require(try await s.store.imageSnapshots(messageID: record.userMessageID).first)
    #expect(snap.prepared == input)
    #expect(snap.preparedLongEdgeSetting == 4096)
  }

  @Test func retryCountersPersisted() async throws {
    let s = try InMemoryStore()
    let conv = try await s.store.createConversation()
    let record = try await s.send(conv, prompt: "x")
    let when = Date(timeIntervalSince1970: 1_800_000_100)
    try await s.store.updateRequest(record.requestID) {
      $0.autoRetriesUsed = 2
      $0.civicFallbackUsed = true
      $0.attempt = 3
      $0.state = .retryScheduled
      $0.nextAttemptAt = .some(when)
      $0.nextAttemptCreatedInBackground = true
      $0.taskIdentifier = .some(17)
    }
    let fresh = s.newDataStore()
    let snap = try #require(try await fresh.requestSnapshot(record.requestID))
    #expect(snap.autoRetriesUsed == 2)
    #expect(snap.civicFallbackUsed)
    #expect(snap.attempt == 3)
    #expect(snap.nextAttemptAt == when)
    #expect(snap.nextAttemptCreatedInBackground)
    #expect(snap.taskIdentifier == 17)
    #expect(try await fresh.nonTerminalRequests().map(\.id) == [record.requestID])

    // `.some(nil)` clears.
    try await fresh.updateRequest(record.requestID) {
      $0.taskIdentifier = .some(nil)
      $0.nextAttemptAt = .some(nil)
    }
    let cleared = try #require(try await s.store.requestSnapshot(record.requestID))
    #expect(cleared.taskIdentifier == nil)
    #expect(cleared.nextAttemptAt == nil)
  }

  @Test func firstSendSetsAutoTitle() async throws {
    let s = try InMemoryStore()
    let conv = try await s.store.createConversation()
    #expect(try await s.store.withConversation(conv) { $0.title } == "New Chat")
    try await s.send(conv, prompt: "A lighthouse on a rocky point at dusk with a purple sky and gulls")
    #expect(try await s.store.withConversation(conv) { $0.title } == "A lighthouse on a rocky point at dusk with a")
    try await s.send(conv, prompt: "make it night")
    #expect(try await s.store.withConversation(conv) { $0.title } == "A lighthouse on a rocky point at dusk with a")
  }

  @Test(arguments: [
    ("short prompt", "short prompt"),
    ("  padded\nacross lines  ", "padded across lines"),
    ("exactly forty-eight characters long, no more!!!", "exactly forty-eight characters long, no more!!!"),
    (String(repeating: "x", count: 60), String(repeating: "x", count: 48)),
    ("", "New Chat"),
  ])
  func automaticTitle(prompt: String, title: String) {
    #expect(DataStore.automaticTitle(prompt) == title)
  }

  @Test func renameEmptyRevertsToAutoTitle() async throws {
    let s = try InMemoryStore()
    let conv = try await s.store.createConversation()
    try await s.send(conv, prompt: "a lighthouse at dusk")
    try await s.store.rename(conv, to: "My lighthouse")
    #expect(try await s.store.withConversation(conv) { ($0.title, $0.titleIsUserSet) } == ("My lighthouse", true))
    try await s.store.rename(conv, to: "   ")
    #expect(try await s.store.withConversation(conv) { ($0.title, $0.titleIsUserSet) } == ("a lighthouse at dusk", false))
  }

  @Test func pinClearedWhenSelectionSaysSo() async throws {
    let s = try InMemoryStore()
    let conv = try await s.store.createConversation()
    let a = try s.stage()
    let first = try await s.send(conv, prompt: "x", attachments: [a])
    try await s.store.setPin(conv, imageID: a.id)
    #expect(try await s.store.pinState(conv: conv) == (a.id, true))

    try await s.send(conv, prompt: "keep", selection: Selection(imageIDs: [a.id], reason: .latest, clearPin: false))
    #expect(try await s.store.pinState(conv: conv).id == a.id)
    let pinned = try await s.send(conv, prompt: "use pin", selection: Selection(imageIDs: [a.id], reason: .pinned, clearPin: true))
    #expect(try await s.store.pinState(conv: conv).id == nil)
    // The reused upload is recorded as its prepared file.
    let inputs = try #require(try await s.store.requestSnapshot(pinned.requestID)?.inputs)
    #expect(inputs.map(\.imageID) == [a.id])
    #expect(inputs.first?.preparedRelativePath.contains("/prepared/") == true)
    _ = first

    // A pin whose asset is gone reports exists: false.
    let ghost = UUID()
    try await s.store.setPin(conv, imageID: ghost)
    #expect(try await s.store.pinState(conv: conv) == (ghost, false))
  }

  @Test func regenerateCopiesRecordedValuesAndAppendsReply() async throws {
    let s = try InMemoryStore()
    let conv = try await s.store.createConversation()
    let a = try s.stage()
    var settings = InMemoryStore.settings
    settings.imageSize = .s1K
    settings.includeTextModality = false
    let original = try await s.send(conv, prompt: "regen me", attachments: [a], settings: settings)
    try await s.store.updateRequest(original.requestID) { $0.state = .succeeded }

    let regen = try #require(try await s.store.createRegenerate(sourceRequestID: original.requestID, activityActionID: ActionID(raw: "beef")))
    #expect(regen.userMessageID == original.userMessageID)
    let snap = try #require(try await s.store.requestSnapshot(regen.requestID))
    let source = try #require(try await s.store.requestSnapshot(original.requestID))
    #expect(snap.settings == source.settings)
    #expect(snap.inputs == source.inputs)
    #expect(snap.promptText == "regen me")
    #expect(snap.selectionReason == .attachments)
    #expect(snap.sourceRequestID == original.requestID)
    #expect(snap.userMessageID == nil)
    #expect(snap.state == .preparing)
    #expect(snap.activityActionID == ActionID(raw: "beef"))

    let history = try await s.store.selectorHistory(conv: conv)
    #expect(history.map(\.role) == [.user, .model, .model])
    #expect(history.map(\.sequence) == [0, 1, 2])

    // A regenerate of the regenerate still finds the user message.
    let again = try #require(try await s.store.createRegenerate(sourceRequestID: regen.requestID, activityActionID: ActionID(raw: "beef")))
    #expect(again.userMessageID == original.userMessageID)
  }

  @Test func regenerateNilWhenInputMissing() async throws {
    let s = try InMemoryStore()
    let conv = try await s.store.createConversation()
    let a = try s.stage()
    let record = try await s.send(conv, prompt: "x", attachments: [a])
    let input = try #require(try await s.store.requestSnapshot(record.requestID)?.inputs.first)
    try FileManager.default.removeItem(at: s.files.url(relative: input.preparedRelativePath))
    #expect(try await s.store.createRegenerate(sourceRequestID: record.requestID, activityActionID: ActionID(raw: "0001")) == nil)
    #expect(try await s.store.selectorHistory(conv: conv).count == 2)
  }

  @Test func deleteConversationRemovesFilesAndReturnsLiveRequests() async throws {
    let s = try InMemoryStore()
    let conv = try await s.store.createConversation()
    let done = try await s.send(conv, prompt: "a", attachments: [try s.stage()])
    try await s.store.updateRequest(done.requestID) { $0.state = .succeeded }
    let live = try await s.send(conv, prompt: "b", attachments: [try s.stage()])
    try FileStore.createDirectory(s.files.requestDir(live.requestID))
    try Data("{}".utf8).write(to: s.files.bodyURL(live.requestID))
    let other = try await s.store.createConversation()
    let kept = try await s.send(other, prompt: "c", attachments: [try s.stage()])

    let result = try await s.store.deleteConversation(conv)
    #expect(result.liveRequestIDs == [live.requestID])
    #expect(result.filesRemoved == 5)  // 2 originals, 2 prepared, 1 body
    #expect(result.bytesFreed > 0)
    #expect(result.failures == 0)
    #expect(!FileManager.default.fileExists(atPath: s.files.conversationDir(conv).path))
    #expect(!FileManager.default.fileExists(atPath: s.files.requestDir(live.requestID).path))
    #expect(try await s.store.requestSnapshot(live.requestID) == nil)
    await #expect(throws: DataStoreError.conversationNotFound(conv)) { try await s.store.selectorHistory(conv: conv) }
    // The other chat is untouched.
    #expect(try await s.store.imageSnapshots(messageID: kept.userMessageID).count == 1)
    #expect(FileManager.default.fileExists(atPath: s.files.conversationDir(other).path))
  }

  @Test func deleteUserMessageKeepsReplies() async throws {
    let s = try InMemoryStore()
    let conv = try await s.store.createConversation()
    let a = try s.stage()
    let record = try await s.send(conv, prompt: "x", attachments: [a])
    let result = try await s.store.deleteMessage(record.userMessageID)
    #expect(result.filesRemoved == 2)
    #expect(result.liveRequestIDs.isEmpty)
    let history = try await s.store.selectorHistory(conv: conv)
    #expect(history.map(\.role) == [.model])
    #expect(try await s.store.requestSnapshot(record.requestID) != nil)

    // Deleting the reply also deletes its (live) request.
    let replyResult = try await s.store.deleteMessage(record.replyMessageID)
    #expect(replyResult.liveRequestIDs == [record.requestID])
    #expect(try await s.store.requestSnapshot(record.requestID) == nil)
  }

  @Test func deleteIfEmpty() async throws {
    let s = try InMemoryStore()
    let empty = try await s.store.createConversation()
    let used = try await s.store.createConversation()
    try await s.send(used, prompt: "x")
    #expect(try await s.store.deleteIfEmpty(empty))
    #expect(!(try await s.store.deleteIfEmpty(used)))
    #expect(!(try await s.store.deleteIfEmpty(empty)))
    #expect(try await s.store.selectorHistory(conv: used).count == 2)
  }

  @Test func selectorHistoryOrderAndStates() async throws {
    let s = try InMemoryStore()
    let conv = try await s.store.createConversation()
    let r1 = try await s.send(conv, prompt: "one")
    let r2 = try await s.send(conv, prompt: "two", attachments: [try s.stage()])
    try await s.store.updateRequest(r1.requestID) { $0.state = .refused }
    try await s.store.updateRequest(r2.requestID) { $0.state = .succeeded }
    let history = try await s.store.selectorHistory(conv: conv)
    #expect(history.map(\.sequence) == [0, 1, 2, 3])
    #expect(history.map(\.role) == [.user, .model, .user, .model])
    #expect(history.map(\.replyState) == [.refused, .refused, .succeeded, .succeeded])
    #expect(history.map(\.images.count) == [0, 0, 1, 0])
    #expect(InputSelector.implicitBase(history: history) == history[2].images.first?.id)
  }

  @Test func overridesAndDraftRoundTrip() async throws {
    let s = try InMemoryStore()
    let conv = try await s.store.createConversation()
    let o = ChatOverrides(modelID: "gemini-3-pro-image", aspectRatio: .r9x16, imageSize: .s4K)
    try await s.store.setOverrides(conv, o)
    #expect(try await s.store.overrides(conv) == o)
    try await s.store.setDraft(conv, text: "draft")
    #expect(try await s.store.withConversation(conv) { $0.draftText } == "draft")
  }

  @Test func editAndResendClonesAssets() async throws {
    let s = try InMemoryStore()
    let conv = try await s.store.createConversation()
    let a = try s.stage(seed: 1)
    let b = try s.stage(seed: 2)
    let record = try await s.send(conv, prompt: "x", attachments: [a, b])
    let snaps = try await s.store.imageSnapshots(messageID: record.userMessageID)
    #expect(snaps.map(\.imageID) == [a.id, b.id])
    for snap in snaps {
      let clone = UUID()
      let original = s.files.url(relative: snap.originalRelativePath)
      let cloneURL = s.files.stagingURL(clone, ext: original.pathExtension)
      try s.files.cloneItem(at: original, to: cloneURL)
      #expect(try Data(contentsOf: cloneURL) == (try Data(contentsOf: original)))
      let prepared = s.files.url(relative: try #require(snap.prepared).preparedRelativePath)
      let preparedClone = s.files.stagingDir.appendingPathComponent("prepared/\(clone.uuidString)-2048.jpg")
      try s.files.cloneItem(at: prepared, to: preparedClone)
      #expect(try Data(contentsOf: preparedClone) == (try Data(contentsOf: prepared)))
      // The originals stay where they are.
      #expect(FileManager.default.fileExists(atPath: original.path))
    }
  }
}

extension DataStore {
  /// Test access to a request's stored fields.
  func withRequest<T: Sendable>(_ id: UUID, _ body: (GenerationRequest) -> T) throws -> T {
    let d = FetchDescriptor<GenerationRequest>(predicate: #Predicate { $0.id == id })
    guard let r = try modelContext.fetch(d).first else { throw DataStoreError.requestNotFound(id) }
    return body(r)
  }

  /// Test access to a conversation's stored fields.
  func withConversation<T: Sendable>(_ id: UUID, _ body: (Conversation) -> T) throws -> T {
    let d = FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == id })
    guard let c = try modelContext.fetch(d).first else { throw DataStoreError.conversationNotFound(id) }
    return body(c)
  }
}
