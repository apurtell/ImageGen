import Foundation
import Testing

@testable import ImageGen

@MainActor
@Suite(.tags(.integration))
struct EditAndResendTests {
  typealias Rig = ChatScreenModelTests.Rig

  /// A user turn with real uploads: originals and prepared files, as a send records them.
  func uploadTurn(_ r: Rig, count: Int, edge: Int = 2048, prompt: String = "combine these") async throws -> SendRecord {
    let staged = try (0..<count).map { i in
      try r.s.stage(original: ImageFactory.png(width: 40, height: 30, seed: i), width: 40, height: 30, edge: edge, seed: i)
    }
    let record = try await r.s.send(r.conv, prompt: prompt, attachments: staged)
    try await r.s.store.updateRequest(record.requestID) { $0.state = .succeeded }
    return record
  }

  /// Records a send of the tray as it stands (what GenerationService.send does with the draft).
  func recordTray(_ r: Rig) async throws -> SendRecord {
    let staged = r.model.tray.compactMap(\.staged)
    return try await r.s.store.createSend(
      SendRecordInput(
        conversationID: r.conv, promptText: r.model.trimmedText, attachments: staged,
        selection: Selection(imageIDs: staged.map(\.id), reason: .attachments, clearPin: false),
        settings: InMemoryStore.settings, activityActionID: ActionID(raw: "cd34")))
  }

  @Test func clonesAttachmentsIntoTray() async throws {
    let r = try await Rig()
    let turn = try await uploadTurn(r, count: 2)
    let sources = try await r.s.store.uploadSources(messageID: turn.userMessageID)
    await r.model.editAndResend(userMessageID: turn.userMessageID)
    #expect(r.model.composerText == "combine these")
    #expect(r.model.tray.count == 2)
    #expect(r.model.tray.allSatisfy { $0.prepared != nil })
    #expect(Set(r.model.tray.map(\.id)).isDisjoint(with: sources.map(\.snapshot.imageID)))
    for (item, source) in zip(r.model.tray, sources) {
      let clone = try #require(item.originalURL)
      #expect(clone.path.hasPrefix(r.s.files.stagingDir.path))
      #expect(try Data(contentsOf: clone) == (try Data(contentsOf: r.s.files.url(relative: source.snapshot.originalRelativePath))))
      #expect(item.pixelWidth == 40 && item.pixelHeight == 30)
    }
  }

  @Test func clonesKeepOrderAndGetNewOrdinals() async throws {
    let r = try await Rig()
    let turn = try await uploadTurn(r, count: 3)
    await r.model.editAndResend(userMessageID: turn.userMessageID)
    r.model.moveTrayItem(r.model.tray[2].id, by: -1)
    let order = r.model.tray.map(\.id)
    let resend = try await recordTray(r)
    let uploads = try await r.s.store.uploadSources(messageID: resend.userMessageID)
    #expect(uploads.map(\.snapshot.imageID) == order)
    // The original turn keeps its own images.
    #expect(try await r.s.store.uploadSources(messageID: turn.userMessageID).count == 3)
  }

  @Test func clonesRepreparedAfterMaxEdgeChange() async throws {
    let r = try await Rig()
    let old = try await uploadTurn(r, count: 1, edge: 2048, prompt: "old")
    r.settings.maxUploadLongEdge = 3072
    await r.model.editAndResend(userMessageID: old.userMessageID)
    let item = try #require(r.model.tray.first)
    let prepared = try #require(item.prepared)
    #expect(prepared.longEdgeSetting == 3072)
    #expect(prepared.url.lastPathComponent == "\(item.id.uuidString)-3072.jpg")
    let resend = try await recordTray(r)
    let input = try #require(try await r.s.store.requestSnapshot(resend.requestID)?.inputs.first)
    #expect(input.preparedRelativePath.hasSuffix("-3072.jpg"))

    // A clone made at the current setting is reused as is.
    let current = try await uploadTurn(r, count: 1, edge: 3072, prompt: "current")
    r.model.tray = []
    r.model.composerText = ""
    await r.model.editAndResend(userMessageID: current.userMessageID)
    let tree = await r.probe.action(named: "Edit and Resend")
    #expect(tree.last?.message == "clones made 1 · clones re-prepared 0 · pin not restored")
    #expect(!tree.contains { $0.name == "Prepare attachment" })
  }

  @Test func restoresPinForLatestReason() async throws {
    let r = try await Rig()
    let (_, image) = try await r.imageTurn()
    let edit = try await r.s.send(r.conv, prompt: "make it night", selection: Selection(imageIDs: [image], reason: .latest, clearPin: false))
    #expect(try await r.s.store.pinState(conv: r.conv).id == nil)
    await r.model.editAndResend(userMessageID: edit.userMessageID)
    #expect(try await r.s.store.pinState(conv: r.conv).id == image)
    #expect(r.model.tray.isEmpty)
  }

  @Test func confirmationWhenDraftNonEmpty() async throws {
    let r = try await Rig()
    let turn = try await uploadTurn(r, count: 1)
    r.model.composerText = "a draft"
    await r.model.editAndResend(userMessageID: turn.userMessageID)
    #expect(r.model.pendingEdit?.userMessageID == turn.userMessageID)
    #expect(r.model.tray.isEmpty)

    // Attachments alone are a draft too; confirming replaces them.
    r.model.composerText = ""
    await r.model.attach([.data(ImageFactory.png(seed: 9))], from: .photos)
    let draftItem = try #require(r.model.tray.first)
    await r.model.editAndResend(userMessageID: turn.userMessageID)
    #expect(r.model.pendingEdit != nil)
    await r.model.editAndResend(userMessageID: turn.userMessageID, confirmed: true)
    #expect(r.model.pendingEdit == nil)
    #expect(r.model.tray.count == 1)
    #expect(r.model.tray.first?.id != draftItem.id)
    #expect(!FileManager.default.fileExists(atPath: draftItem.originalURL!.path))
    #expect(r.model.composerText == "combine these")
  }

  @Test func refusedCardEditClonesAttachments() async throws {
    let r = try await Rig()
    let staged = try r.s.stage(original: ImageFactory.png(width: 40, height: 30), width: 40, height: 30)
    let refused = try await r.s.send(r.conv, prompt: "Make this photo dramatic", attachments: [staged])
    try await r.s.store.updateRequest(refused.requestID) { $0.state = .refused }
    await r.model.editRefused(requestID: refused.requestID)
    #expect(r.model.composerText == "Make this photo dramatic")
    #expect(r.model.tray.count == 1)
    #expect(r.model.tray.first?.prepared != nil)
    #expect(r.model.isTextFieldFocused)
    #expect(r.generation.sends.value.isEmpty)
  }

  @Test func editAndResendLogged() async throws {
    let r = try await Rig()
    let turn = try await uploadTurn(r, count: 2, edge: 2048)
    r.settings.maxUploadLongEdge = 3072
    await r.model.editAndResend(userMessageID: turn.userMessageID)
    let tree = await r.probe.action(named: "Edit and Resend")
    let begin = try #require(tree.first)
    #expect(begin.message == "message \(Format.short(turn.userMessageID)) · text 13 characters · attachments to clone 2 · pin to restore none")
    let children = tree.filter { $0.name == "Prepare attachment" && $0.kind == .begin }
    #expect(children.count == 2)
    #expect(children.allSatisfy { $0.parentID == begin.actionID && $0.message.contains("re-prepare: edge setting changed from 2048") })
    let result = try #require(tree.last)
    #expect(result.actionID == begin.actionID && result.kind == .result && result.outcome == .success)
    #expect(result.message == "clones made 2 · clones re-prepared 2 · pin not restored")
    await r.probe.assertPaired()
  }
}
