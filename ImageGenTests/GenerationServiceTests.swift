import CryptoKit
import Foundation
import Testing

@testable import ImageGen

@Suite(.tags(.integration))
struct GenerationServiceTests {
  typealias H = GenerationHarness

  /// A response with text, image, text, image (two different real images).
  static func textImageTextImage() throws -> Data {
    let png = try FixtureLoader.data("Images/tiny_16x9.png").base64EncodedString()
    let jpg = try FixtureLoader.data("Images/tiny_square.jpg").base64EncodedString()
    return try JSONSerialization.data(withJSONObject: [
      "candidates": [[
        "content": ["role": "model", "parts": [
          ["text": "First"], ["inlineData": ["mimeType": "image/png", "data": png]], ["text": "Second"],
          ["inlineData": ["mimeType": "image/jpeg", "data": jpg]],
        ]], "finishReason": "STOP",
      ]]
    ])
  }

  static func fixtureImageBytes(_ fixture: String, index: Int = 0) throws -> Data {
    let json = try #require(try JSONSerialization.jsonObject(with: FixtureLoader.data(fixture)) as? [String: Any])
    let parts = try #require(
      (((json["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any])?["parts"]) as? [[String: Any]])
    let datas = parts.compactMap { ($0["inlineData"] as? [String: String])?["data"] }
    return try #require(Data(base64Encoded: datas[index]))
  }

  // MARK: End to end

  @Test func endToEndTextToImage() async throws {
    let h = try H()
    try h.respond("Responses/resp_text_image.json")
    let conv = try await h.s.store.createConversation()
    let snap = try await h.sendAndWait(h.draft(conv, "a lighthouse at dusk"))
    #expect(snap.state == .succeeded)
    #expect(snap.attempt == 1)
    let parts = try #require(try await h.s.store.messageParts(snap.replyMessageID))
    #expect(parts.map(\.kind) == [.text, .image])
    #expect(parts.first?.text == "Here is your lighthouse at dusk.")
    let images = try await h.s.store.imageSnapshots(messageID: snap.replyMessageID)
    let image = try #require(images.first)
    let stored = try Data(contentsOf: h.s.files.url(relative: image.originalRelativePath))
    #expect(H.sha256(stored) == H.sha256(try Self.fixtureImageBytes("Responses/resp_text_image.json")))
    #expect(image.originalRelativePath.hasPrefix("Images/\(conv.uuidString)/"))
    let fields = try #require(try await h.s.store.outcomeFields(snap.id))
    #expect(fields.outputWidth == 16)
    #expect(fields.outputHeight == 9)
    #expect(fields.httpStatus == 200)
    #expect(fields.finishReason == "STOP")
    #expect(h.recorded.count == 1)
    #expect(h.recorded.first?.request.value(forHTTPHeaderField: "x-goog-api-key") == "test-key")
    #expect(h.recorded.first?.request.url?.query == nil)
    await h.probe.assertPaired()
  }

  @Test func recordsSentValues() async throws {
    let h = try H()
    try h.respond("Responses/resp_text_image.json", "Responses/resp_text_image.json")
    let conv = try await h.s.store.createConversation()
    let first = try await h.sendAndWait(h.draft(conv, "default"))
    #expect(first.settings.aspectRatio == .r16x9)
    #expect(first.settings.imageSize == .s2K)
    let override = try await h.sendAndWait(h.draft(conv, "override", overrides: ChatOverrides(aspectRatio: .r9x16, imageSize: .s4K)))
    #expect(override.settings.aspectRatio == .r9x16)
    #expect(override.settings.imageSize == .s4K)
    let configs = h.sentBodies.map { ($0["generationConfig"] as? [String: Any])?["imageConfig"] as? [String: String] }
    #expect(configs == [["aspectRatio": "16:9", "imageSize": "2K"], ["aspectRatio": "9:16", "imageSize": "4K"]])
    #expect(h.jobs.value.map(\.expectedReceiveBytes) == [8_000_000, 24_000_000])
  }

  @Test func editLatestSendsOriginalBytes() async throws {
    let h = try H()
    try h.respond("Responses/resp_text_image.json", "Responses/resp_text_image.json")
    let conv = try await h.s.store.createConversation()
    let first = try await h.sendAndWait(h.draft(conv, "draw"))
    let edit = try await h.sendAndWait(h.draft(conv, "make it night"))
    #expect(edit.selectionReason == .latest)
    let sent = try #require(H.images(in: h.sentBodies[1]).first)
    #expect(sent.data == (try Self.fixtureImageBytes("Responses/resp_text_image.json")))
    #expect(sent.mime == "image/png")
    let original = try #require(try await h.s.store.imageSnapshots(messageID: first.replyMessageID).first)
    #expect(edit.inputs.map(\.imageID) == [original.imageID])
    #expect(edit.inputs.first?.preparedRelativePath == original.originalRelativePath)
  }

  @Test func pinnedSendClearsPin() async throws {
    let h = try H()
    try h.respond("Responses/resp_two_images.json", "Responses/resp_text_image.json")
    let conv = try await h.s.store.createConversation()
    let first = try await h.sendAndWait(h.draft(conv, "two"))
    let images = try await h.s.store.imageSnapshots(messageID: first.replyMessageID)
    try await h.s.store.setPin(conv, imageID: images[0].imageID)
    let pinned = try await h.sendAndWait(h.draft(conv, "edit the first"))
    #expect(pinned.selectionReason == .pinned)
    #expect(pinned.inputs.map(\.imageID) == [images[0].imageID])
    #expect(try await h.s.store.pinState(conv: conv).id == nil)
    #expect(H.images(in: h.sentBodies[1]).first?.data == (try Self.fixtureImageBytes("Responses/resp_two_images.json", index: 0)))
  }

  /// Turn 1 uploads a HEIC (prepared to JPEG) and gets a text-only reply, so the upload is the latest image.
  func uploadThenText(_ h: H) async throws -> (conv: UUID, upload: StagedAttachment) {
    try h.respond("Responses/resp_text_only.json")
    let conv = try await h.s.store.createConversation()
    let heic = try FixtureLoader.data("Images/sample.heic")
    let upload = try h.s.stage(original: heic, originalMime: "image/heic", width: 640, height: 480, edge: 2048)
    _ = try await h.sendAndWait(h.draft(conv, "describe", attachments: [upload]))
    return (conv, upload)
  }

  @Test func latestUserUploadSendsPreparedBytes() async throws {
    let h = try H()
    let (conv, upload) = try await uploadThenText(h)
    try h.respond("Responses/resp_text_image.json")
    let second = try await h.sendAndWait(h.draft(conv, "edit it"))
    #expect(second.selectionReason == .latest)
    let sent = try #require(H.images(in: h.sentBodies[1]).first)
    #expect(sent.mime == "image/jpeg")
    let prepared = try #require(try await h.s.store.inputSnapshots([upload.id]).first?.prepared)
    #expect(sent.data == (try Data(contentsOf: h.s.files.url(relative: prepared.preparedRelativePath))))
    #expect(sent.data != (try FixtureLoader.data("Images/sample.heic")))
  }

  @Test func pinnedUserUploadSendsPreparedBytes() async throws {
    let h = try H()
    let (conv, upload) = try await uploadThenText(h)
    try await h.s.store.setPin(conv, imageID: upload.id)
    try h.respond("Responses/resp_text_image.json")
    let second = try await h.sendAndWait(h.draft(conv, "edit the pinned upload"))
    #expect(second.selectionReason == .pinned)
    #expect(H.images(in: h.sentBodies[1]).first?.mime == "image/jpeg")
  }

  @Test func reusedUploadRepreparedAfterMaxEdgeChange() async throws {
    let h = try H()
    let (conv, upload) = try await uploadThenText(h)
    h.edge.withLock { $0 = 3072 }
    try h.respond("Responses/resp_text_image.json")
    let second = try await h.sendAndWait(h.draft(conv, "edit"))
    #expect(second.state == .succeeded)
    let asset = try #require(try await h.s.store.inputSnapshots([upload.id]).first)
    #expect(asset.preparedLongEdgeSetting == 3072)
    let prepared = try #require(asset.prepared)
    #expect(prepared.preparedRelativePath.hasSuffix("-3072.jpg"))
    #expect(second.inputs.first?.preparedRelativePath == prepared.preparedRelativePath)
    #expect(H.images(in: h.sentBodies[1]).first?.data == (try Data(contentsOf: h.s.files.url(relative: prepared.preparedRelativePath))))
  }

  @Test func reusedUploadRepreparedWhenPreparedFileMissing() async throws {
    let h = try H()
    let (conv, upload) = try await uploadThenText(h)
    let old = try #require(try await h.s.store.inputSnapshots([upload.id]).first?.prepared)
    try FileManager.default.removeItem(at: h.s.files.url(relative: old.preparedRelativePath))
    try h.respond("Responses/resp_text_image.json")
    let second = try await h.sendAndWait(h.draft(conv, "edit"))
    #expect(second.state == .succeeded)
    let asset = try #require(try await h.s.store.inputSnapshots([upload.id]).first?.prepared)
    #expect(FileManager.default.fileExists(atPath: h.s.files.url(relative: asset.preparedRelativePath).path))
  }

  @Test func multipleAttachmentsInOrder() async throws {
    let h = try H()
    try h.respond("Responses/resp_text_image.json")
    let conv = try await h.s.store.createConversation()
    let a = try h.s.stage(seed: 1)
    let b = try h.s.stage(seed: 2)
    let c = try h.s.stage(seed: 3)
    let snap = try await h.sendAndWait(h.draft(conv, "combine", attachments: [c, a, b]))
    #expect(snap.inputs.map(\.imageID) == [c.id, a.id, b.id])
    let sent = H.images(in: h.sentBodies[0])
    #expect(sent.count == 3)
    for (image, staged) in zip(sent, [c, a, b]) {
      let prepared = try #require(try await h.s.store.inputSnapshots([staged.id]).first?.prepared)
      #expect(image.data == (try Data(contentsOf: h.s.files.url(relative: prepared.preparedRelativePath))))
    }
  }

  @Test func heicUploadSentAsJpeg() async throws {
    let h = try H()
    try h.respond("Responses/resp_text_image.json")
    let conv = try await h.s.store.createConversation()
    let id = UUID()
    let heic = ImageFactory.heic(width: 64, height: 48)
    let original = h.s.files.stagingURL(id, ext: "heic")
    try FileStore.createDirectory(h.s.files.stagingDir)
    try heic.write(to: original)
    let preparedDir = h.s.files.stagingDir.appendingPathComponent("prepared")
    try FileStore.createDirectory(preparedDir)
    let prepared = try await ImagePreprocessor.prepare(source: original, maxLongEdge: 2048, destinationDir: preparedDir, id: id)
    let staged = StagedAttachment(
      id: id, origin: .photos, originalURL: original, originalMimeType: "image/heic", originalByteCount: heic.count,
      pixelWidth: 64, pixelHeight: 48, originalFilename: "IMG_0001.HEIC", prepared: prepared)
    _ = try await h.sendAndWait(h.draft(conv, "edit this", attachments: [staged]))
    let sent = try #require(H.images(in: h.sentBodies[0]).first)
    #expect(sent.mime == "image/jpeg")
    #expect(sent.data == (try Data(contentsOf: h.s.files.url(relative: try #require(try await h.s.store.inputSnapshots([id]).first?.prepared).preparedRelativePath))))
    let kept = try #require(try await h.s.store.inputSnapshots([id]).first)
    #expect(kept.originalMimeType == "image/heic")
    #expect(kept.originalRelativePath.hasSuffix(".heic"))
    #expect(try Data(contentsOf: h.s.files.url(relative: kept.originalRelativePath)) == heic)
  }

  @Test func modelImagesOrdinalFollowsPartsOrder() async throws {
    let h = try H()
    h.respond(status: 200, body: try Self.textImageTextImage())
    try h.respond("Responses/resp_text_image.json")
    let conv = try await h.s.store.createConversation()
    let first = try await h.sendAndWait(h.draft(conv, "two"))
    let reply = try #require(try await h.s.store.selectorHistory(conv: conv).first { $0.role == .model })
    #expect(reply.images.map(\.ordinal) == [0, 1])
    let parts = try #require(try await h.s.store.messageParts(first.replyMessageID))
    #expect(parts.map(\.kind) == [.text, .image, .text, .image])
    #expect(parts.compactMap(\.imageID) == reply.images.map(\.id))
    _ = try await h.sendAndWait(h.draft(conv, "edit the last"))
    #expect(H.images(in: h.sentBodies[1]).first?.data == (try FixtureLoader.data("Images/tiny_square.jpg")))
  }

  // MARK: Refusals

  @Test func refusedOutcomeStoredNotAutoRetried() async throws {
    let h = try H()
    try h.respond("Responses/resp_image_safety.json")
    let conv = try await h.s.store.createConversation()
    let snap = try await h.sendAndWait(h.draft(conv, "x"))
    #expect(snap.state == .refused)
    #expect(snap.attempt == 1)
    #expect(!snap.civicFallbackUsed)
    let fields = try #require(try await h.s.store.outcomeFields(snap.id))
    #expect(fields.refusalReason == "IMAGE_SAFETY")
    #expect(fields.errorMessage == "The image was blocked by the safety filter.")
    #expect(fields.details?.contains("IMAGE_SAFETY") == true)
    #expect(try await h.s.store.messageParts(snap.replyMessageID) == [])
    #expect(h.recorded.count == 1)
  }

  @Test func refusedWithTextKeepsTextOutOfReply() async throws {
    let h = try H()
    try h.respond("Responses/resp_refused_with_text.json")
    let conv = try await h.s.store.createConversation()
    let snap = try await h.sendAndWait(h.draft(conv, "x"))
    #expect(snap.state == .refused)
    #expect(try await h.s.store.messageParts(snap.replyMessageID) == [])
    #expect(try await h.s.store.outcomeFields(snap.id)?.details?.contains("Sorry, I can't generate that image.") == true)
  }

  @Test(arguments: [("Responses/resp_text_image.json", RequestState.succeeded), ("Responses/resp_image_safety.json", .refused)])
  func userRetryAfterRefusal(second: String, expected: RequestState) async throws {
    let h = try H()
    try h.respond("Responses/resp_image_safety.json")
    let conv = try await h.s.store.createConversation()
    let refused = try await h.sendAndWait(h.draft(conv, "x"))
    try h.respond(second)
    try await h.service.retry(requestID: refused.id)
    let snap = try await h.wait(refused.id)
    #expect(snap.state == expected)
    #expect(snap.attempt == 2)
    let fields = try #require(try await h.s.store.outcomeFields(snap.id))
    if expected == .succeeded {
      #expect(fields.refusalReason == nil)
      #expect(fields.errorMessage == nil)
      #expect(fields.details?.contains("IMAGE_SAFETY") == false)
      #expect(try await h.s.store.messageParts(snap.replyMessageID)?.count == 2)
    } else {
      #expect(fields.refusalReason == "IMAGE_SAFETY")
    }
    #expect(h.recorded.count == 2)
  }

  // MARK: Errors and notices

  @Test func apiErrorStoredWithDetails() async throws {
    let h = try H()
    try h.respond("Errors/err_400_invalid_argument.json")
    let conv = try await h.s.store.createConversation()
    let snap = try await h.sendAndWait(h.draft(conv, "x"))
    #expect(snap.state == .failed)
    let fields = try #require(try await h.s.store.outcomeFields(snap.id))
    #expect(fields.httpStatus == 400)
    #expect(fields.errorStatus == "INVALID_ARGUMENT")
    #expect(fields.errorMessage?.contains("Unsupported value") == true)
    #expect(fields.details?.contains("INVALID_ARGUMENT") == true)
    #expect(h.recorded.count == 1)
  }

  @Test func noticesPersistedAndReloaded() async throws {
    let h = try H()
    try h.respond("Responses/resp_bad_image.json")
    let conv = try await h.s.store.createConversation()
    let snap = try await h.sendAndWait(h.draft(conv, "x"))
    #expect(snap.state == .succeeded)
    let fresh = h.s.newDataStore()
    #expect(try await fresh.outcomeFields(snap.id)?.notices == ["1 image could not be decoded"])
  }

  @Test func undecodableImageKeepsPreviousEditBase() async throws {
    let h = try H()
    try h.respond("Responses/resp_text_image.json", "Responses/resp_bad_image.json", "Responses/resp_text_image.json")
    let conv = try await h.s.store.createConversation()
    let one = try await h.sendAndWait(h.draft(conv, "draw"))
    let two = try await h.sendAndWait(h.draft(conv, "change"))
    #expect(try await h.s.store.outcomeFields(two.id)?.notices == ["1 image could not be decoded"])
    #expect(try await h.s.store.imageSnapshots(messageID: two.replyMessageID).isEmpty)
    let three = try await h.sendAndWait(h.draft(conv, "again"))
    let base = try #require(try await h.s.store.imageSnapshots(messageID: one.replyMessageID).first)
    #expect(three.selectionReason == .latest)
    #expect(three.inputs.map(\.imageID) == [base.imageID])
    #expect(H.images(in: h.sentBodies[2]).first?.data == (try Self.fixtureImageBytes("Responses/resp_text_image.json")))
  }

  // MARK: Retries

  @Test func rateLimitRetriesThenSucceeds() async throws {
    let h = try H(manualSleeper: true)
    try h.respond("Errors/err_429_retryinfo.json", "Responses/resp_text_image.json")
    let conv = try await h.s.store.createConversation()
    let id = try await h.service.send(h.draft(conv, "x"))
    let scheduled = try await h.wait(id, for: [.retryScheduled])
    #expect(scheduled.attempt == 2)
    #expect(scheduled.autoRetriesUsed == 1)
    #expect(scheduled.nextAttemptAt == h.clock.now.addingTimeInterval(30))
    #expect(h.jobs.value.last?.earliestBegin == h.clock.now.addingTimeInterval(30))
    try await h.until { h.sleeper!.waitingCount == 1 }
    #expect(h.recorded.count == 1)
    h.sleeper!.advance()
    let snap = try await h.wait(id)
    #expect(snap.state == .succeeded)
    #expect(snap.attempt == 2)
    #expect(snap.autoRetriesUsed == 1)
    #expect(h.recorded.count == 2)

    // logsRetryDecisionAndAttempts
    let tree = await h.probe.action(named: "Send")
    let attempt1 = try #require(tree.last { $0.name == "Attempt 1" && $0.kind == .result })
    #expect(attempt1.message.contains("HTTP 429"))
    #expect(tree.contains { $0.kind == .step && $0.name == "Send" && $0.message == "auto-retry 1/2 in 30.0 s: HTTP 429 RESOURCE_EXHAUSTED (RetryInfo 30s)" })
    let attempt2 = try #require(tree.last { $0.name == "Attempt 2" && $0.kind == .result })
    #expect(attempt2.message.contains("HTTP 200"))
    #expect(tree.filter { $0.kind == .step && $0.message.hasPrefix("upload task") }.allSatisfy { $0.name.hasPrefix("Attempt") })
    #expect(tree.filter { $0.kind == .step && $0.message.hasPrefix("upload task") }.count == 2)
    await h.probe.assertPaired()
  }

  @Test func retryCountersSurviveRelaunch() async throws {
    let h = try H(scripted: true)
    let conv = try await h.s.store.createConversation()
    let id = try await h.service.send(h.draft(conv, "x"))
    try await h.wait(id, for: [.inFlight])
    let body429 = try FixtureLoader.data("Errors/err_429_retryinfo.json")
    h.scripted!.complete(id, attempt: 1, status: 429, body: body429)
    try await h.wait(id, for: [.retryScheduled])
    #expect(try await h.snapshot(id).autoRetriesUsed == 1)

    // A new process: new log, store actor, transport and service on the same files.
    h.service.stop()
    let h2 = try H(scripted: true, reuse: h)
    h2.scripted!.complete(id, attempt: 2, status: 429, body: body429)
    try await h2.until { try await h2.snapshot(id).attempt == 3 }
    let retried = try await h2.wait(id, for: [.retryScheduled])
    #expect(retried.attempt == 3)
    #expect(retried.autoRetriesUsed == 2)
    h2.scripted!.complete(id, attempt: 3, status: 429, body: body429)
    let snap = try await h2.wait(id)
    #expect(snap.state == .failed)
    #expect(snap.autoRetriesUsed == 2)
    #expect(try await h2.s.store.outcomeFields(id)?.errorStatus == "RESOURCE_EXHAUSTED")
  }

  @Test func manualRetryResetsAutoBudget() async throws {
    let h = try H()
    for _ in 0..<3 { try h.respond("Errors/err_503.json") }
    let conv = try await h.s.store.createConversation()
    let failed = try await h.sendAndWait(h.draft(conv, "x"))
    #expect(failed.state == .failed)
    #expect(failed.autoRetriesUsed == 2)
    #expect(failed.attempt == 3)
    try h.respond("Responses/resp_text_image.json")
    try await h.service.retry(requestID: failed.id)
    let snap = try await h.wait(failed.id)
    #expect(snap.state == .succeeded)
    #expect(snap.attempt == 4)
    #expect(snap.autoRetriesUsed == 0)
  }

  @Test func civicFallbackRebuildsOnceAndPersistsFlag() async throws {
    let h = try H()
    try h.respond("Errors/err_400_civic.json", "Responses/resp_text_image.json")
    let conv = try await h.s.store.createConversation()
    let snap = try await h.sendAndWait(h.draft(conv, "x"))
    #expect(snap.state == .succeeded)
    #expect(snap.civicFallbackUsed)
    #expect(snap.attempt == 2)
    #expect(snap.autoRetriesUsed == 0)
    #expect(snap.settings.categories.count == 4)
    #expect(h.civicCalls.value == 1)
    let categories = h.sentBodies.map { ($0["safetySettings"] as? [[String: String]])?.count }
    #expect(categories == [5, 4])
  }

  @MainActor @Test func nextSendAfterCivicFallbackHasFourCategories() async throws {
    let suite = "ImageGenTests.\(UUID().uuidString)"
    let ud = UserDefaults(suiteName: suite)!
    defer { ud.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: ud)
    let h = try H()
    try h.respond("Errors/err_400_civic.json", "Responses/resp_text_image.json")
    let conv = try await h.s.store.createConversation()
    _ = try await h.sendAndWait(h.draft(conv, "x"))
    // What AppEnvironment's setOmitCivicOnMain does.
    if h.civicCalls.value > 0 { settings.omitCivicIntegrity = true }
    let next = GenerationSettingsResolver.resolve(ChatOverrides(), settings.generationDefaults())
    #expect(next.categories.count == 4)
    #expect(AppSettings.readDefaults(ud).omitCivicIntegrity)
  }

  @Test func emptyBodyRetriedWithinSharedBudget() async throws {
    let h = try H()
    for _ in 0..<3 { h.respond(status: 200, body: Data()) }
    let conv = try await h.s.store.createConversation()
    let snap = try await h.sendAndWait(h.draft(conv, "x"))
    #expect(snap.state == .failed)
    #expect(snap.attempt == 3)
    #expect(snap.autoRetriesUsed == 2)
    #expect(try await h.s.store.outcomeFields(snap.id)?.errorStatus == "MALFORMED")
    #expect(h.recorded.count == 3)
  }

  @Test func resourceTimeoutNotRetried() async throws {
    let h = try H(scripted: true)
    let conv = try await h.s.store.createConversation()
    let id = try await h.service.send(h.draft(conv, "x"))
    try await h.wait(id, for: [.inFlight])
    h.scripted!.complete(id, attempt: 1, error: .timedOut, elapsed: .seconds(1800))
    let snap = try await h.wait(id)
    #expect(snap.state == .failed)
    #expect(snap.attempt == 1)
    let fields = try #require(try await h.s.store.outcomeFields(id))
    #expect(fields.errorStatus == "TIMED_OUT")
    #expect(fields.errorMessage == "No response within 30 min.")
  }

  @Test func idleTimeoutRetried() async throws {
    let h = try H(scripted: true)
    let conv = try await h.s.store.createConversation()
    let id = try await h.service.send(h.draft(conv, "x"))
    try await h.wait(id, for: [.inFlight])
    h.scripted!.complete(id, attempt: 1, error: .timedOut, elapsed: .seconds(300))
    let snap = try await h.wait(id, for: [.retryScheduled])
    #expect(snap.attempt == 2)
  }

  @Test func backgroundCreatedRetryRecreatedOnActive() async throws {
    let h = try H(manualSleeper: true, active: false)
    try h.respond("Errors/err_503.json", "Responses/resp_text_image.json")
    let conv = try await h.s.store.createConversation()
    let id = try await h.service.send(h.draft(conv, "x"))
    let scheduled = try await h.wait(id, for: [.retryScheduled])
    #expect(scheduled.nextAttemptCreatedInBackground)
    let oldTask = try #require(scheduled.taskIdentifier)
    try await h.until { h.sleeper!.waitingCount == 1 }

    h.activity.setActive(true)
    await h.service.appBecameActive()
    let replaced = try await h.snapshot(id)
    #expect(!replaced.nextAttemptCreatedInBackground)
    #expect(replaced.taskIdentifier != oldTask)
    // A new attempt number, so the replaced task's events can't touch it.
    #expect(replaced.attempt == 3)
    try await h.until { h.sleeper!.waitingCount == 2 }
    h.sleeper!.advance()
    let snap = try await h.wait(id)
    #expect(snap.state == .succeeded)
    #expect(h.recorded.count == 2)
    let tree = await h.probe.action(named: "Send")
    #expect(tree.contains { $0.message == "background-created retry re-created in the foreground" })
  }

  @Test func beganEventMovesToInFlight() async throws {
    let h = try H(manualSleeper: true)
    try h.respond("Errors/err_503.json")
    try h.respond("Responses/resp_text_image.json", delay: .milliseconds(500))
    let conv = try await h.s.store.createConversation()
    let id = try await h.service.send(h.draft(conv, "x"))
    try await h.wait(id, for: [.retryScheduled])
    try await h.until { h.sleeper!.waitingCount == 1 }
    h.sleeper!.advance()
    let inFlight = try await h.wait(id, for: [.inFlight])
    #expect(inFlight.attempt == 2)
    #expect(try await h.wait(id).state == .succeeded)
  }

  // MARK: Cancels

  @Test func systemCancelBecomesInterrupted() async throws {
    let h = try H(scripted: true)
    let conv = try await h.s.store.createConversation()
    let id = try await h.service.send(h.draft(conv, "x"))
    try await h.wait(id, for: [.inFlight])
    h.scripted!.complete(id, attempt: 1, error: .cancelled, cancelReason: NSURLErrorCancelledReasonUserForceQuitApplication)
    #expect(try await h.wait(id).state == .interrupted)
    // logsCancelAndSystemCancel (system half)
    let result = try #require(await h.probe.action(named: "Send").last)
    #expect(result.outcome == .interrupted)
    #expect(result.message.contains("force quit"))
  }

  @Test func userCancelStaysCancelled() async throws {
    let h = try H()
    try h.respond("Responses/resp_text_image.json", delay: .seconds(5))
    let conv = try await h.s.store.createConversation()
    let id = try await h.service.send(h.draft(conv, "x"))
    try await h.wait(id, for: [.inFlight])
    await h.service.cancel(requestID: id)
    #expect(try await h.wait(id).state == .cancelled)
    // logsCancelAndSystemCancel (user half)
    let cancel = await h.probe.action(named: "Cancel")
    #expect(cancel.first?.origin == .user)
    #expect(cancel.last?.outcome == .success)
    #expect(await h.probe.action(named: "Send").last?.outcome == .cancelled)
    await h.probe.assertPaired()
  }

  @Test func cancelInFlight() async throws {
    let h = try H()
    try h.respond("Responses/resp_text_image.json", delay: .seconds(5))
    let conv = try await h.s.store.createConversation()
    let id = try await h.service.send(h.draft(conv, "x"))
    await h.service.cancel(requestID: id)
    let snap = try await h.wait(id)
    #expect(snap.state == .cancelled)
    // The chat is free again.
    try h.respond("Responses/resp_text_image.json")
    #expect(try await h.sendAndWait(h.draft(conv, "again")).state == .succeeded)
  }

  @Test func deleteWhileInFlightDiscardsLateCompletion() async throws {
    let h = try H(scripted: true)
    let conv = try await h.s.store.createConversation()
    let id = try await h.service.send(h.draft(conv, "x"))
    try await h.wait(id, for: [.inFlight])
    let deleted = try await h.s.store.deleteConversation(conv)
    #expect(deleted.liveRequestIDs == [id])
    h.scripted!.complete(id, attempt: 1, status: 200, body: try FixtureLoader.data("Responses/resp_text_image.json"))
    try await h.until { !FileManager.default.fileExists(atPath: h.s.files.requestDir(id).path) }
    #expect(try await h.s.store.requestSnapshot(id) == nil)
    #expect(!FileManager.default.fileExists(atPath: h.s.files.conversationDir(conv).path))
    let result = try #require(await h.probe.action(named: "Send").last)
    #expect(result.outcome == .cancelled)
  }

  // MARK: Background assertion

  @Test func preparationHoldsBackgroundAssertion() async throws {
    let h = try H()
    try h.respond("Responses/resp_text_image.json")
    let conv = try await h.s.store.createConversation()
    _ = try await h.sendAndWait(h.draft(conv, "x"))
    let events = h.tasks.events.value
    #expect(events.count == 2)
    #expect(events.first == .begin("gen-prepare"))
    guard case .end(let lines) = events.last else {
      Issue.record("no end")
      return
    }
    // assertionEndFlushesFirst: by the end, the Send Begin, Prepare request and Attempt Begin are written.
    #expect(lines >= 4)
    let begins = await h.probe.entries().prefix(lines)
    #expect(begins.contains { $0.name == "Attempt 1" && $0.kind == .begin })
  }

  @Test func assertionExpiryMarksInterrupted() async throws {
    let gate = WeakHarness()
    let h = try H(
      budget: 100,
      shrink: { _, _ in
        await gate.value?.tasks.fireExpiry()
        try await Task.sleep(for: .seconds(30))
        throw CancellationError()
      })
    gate.value = h
    let conv = try await h.s.store.createConversation()
    let big = try h.s.stage(original: ImageFactory.png(width: 2048, height: 1536), width: 2048, height: 1536)
    await #expect(throws: GenerationError.interrupted) { _ = try await h.service.send(h.draft(conv, "x", attachments: [big])) }
    let history = try await h.s.store.selectorHistory(conv: conv)
    #expect(history.last?.replyState == .interrupted)
    #expect(h.jobs.value.isEmpty)
    #expect(h.recorded.isEmpty)
    let requests = (try? FileManager.default.contentsOfDirectory(atPath: h.s.files.requestsDir.path)) ?? []
    for r in requests {
      #expect(!FileManager.default.fileExists(atPath: h.s.files.requestsDir.appendingPathComponent("\(r)/body.json").path))
    }
    // The expiry's interrupted Result is in the file by the time the flush returned.
    guard case .expired(let lines) = h.tasks.events.value.first(where: { if case .expired = $0 { true } else { false } }) else {
      Issue.record("expiry not recorded")
      return
    }
    let written = await h.probe.entries().prefix(lines)
    #expect(written.contains { $0.name == "Send" && $0.kind == .result && $0.outcome == .interrupted })
    await h.probe.assertPaired()
  }

  @Test func noKeyFailsPreparation() async throws {
    let h = try H(key: nil)
    let conv = try await h.s.store.createConversation()
    await #expect(throws: GenerationError.preparationFailed(.noAPIKey)) { _ = try await h.service.send(h.draft(conv, "x")) }
    let history = try await h.s.store.selectorHistory(conv: conv)
    #expect(history.last?.replyState == .failed)
    #expect(h.recorded.isEmpty)
    #expect(await h.probe.action(named: "Send").last?.outcome == .failed)
  }

  @Test func tooLargeFailsBeforeNetwork() async throws {
    let h = try H(budget: 100)
    let conv = try await h.s.store.createConversation()
    let a = try h.s.stage()
    await #expect(throws: GenerationError.preparationFailed(.tooLarge)) {
      _ = try await h.service.send(h.draft(conv, "x", attachments: [a]))
    }
    #expect(h.recorded.isEmpty)
    #expect(h.jobs.value.isEmpty)
  }

  // MARK: Concurrency limits

  @Test func onePerChatEnforced() async throws {
    let h = try H()
    try h.respond("Responses/resp_text_image.json", delay: .seconds(1))
    let conv = try await h.s.store.createConversation()
    let id = try await h.service.send(h.draft(conv, "first"))
    await #expect(throws: GenerationError.chatBusy) { _ = try await h.service.send(h.draft(conv, "second")) }
    #expect(try await h.wait(id).state == .succeeded)
  }

  @Test func parallelChatsAllowed() async throws {
    let h = try H()
    try h.respond("Responses/resp_text_image.json", "Responses/resp_text_image.json", delay: .milliseconds(300))
    let a = try await h.s.store.createConversation()
    let b = try await h.s.store.createConversation()
    let ra = try await h.service.send(h.draft(a, "a"))
    let rb = try await h.service.send(h.draft(b, "b"))
    #expect(try await h.wait(ra).state == .succeeded)
    #expect(try await h.wait(rb).state == .succeeded)
  }

  // MARK: Regenerate and Retry

  @Test func regenerateUsesRecordedSettings() async throws {
    let h = try H()
    try h.respond("Responses/resp_text_image.json", "Responses/resp_text_image.json")
    let conv = try await h.s.store.createConversation()
    let first = try await h.sendAndWait(h.draft(conv, "x", overrides: ChatOverrides(aspectRatio: .r21x9, imageSize: .s1K)))
    // Defaults and overrides change after the first send; the regenerate ignores them.
    h.edge.withLock { $0 = 4096 }
    try await h.s.store.setOverrides(conv, ChatOverrides(aspectRatio: .r1x1, imageSize: .s4K))
    let regenID = try await h.service.regenerate(sourceRequestID: first.id)
    let regen = try await h.wait(regenID)
    #expect(regen.state == .succeeded)
    #expect(regen.settings == first.settings)
    let config = (h.sentBodies[1]["generationConfig"] as? [String: Any])?["imageConfig"] as? [String: String]
    #expect(config == ["aspectRatio": "21:9", "imageSize": "1K"])
  }

  @Test func regenerateKeepsPriorReply() async throws {
    let h = try H()
    try h.respond("Responses/resp_text_image.json", "Responses/resp_two_images.json")
    let conv = try await h.s.store.createConversation()
    let first = try await h.sendAndWait(h.draft(conv, "x"))
    let regen = try await h.wait(try await h.service.regenerate(sourceRequestID: first.id))
    #expect(regen.sourceRequestID == first.id)
    let history = try await h.s.store.selectorHistory(conv: conv)
    #expect(history.map(\.role) == [.user, .model, .model])
    #expect(history.map(\.images.count) == [0, 1, 2])
    #expect(await h.probe.action(named: "Regenerate").first?.message.contains("recorded values reused") == true)
  }

  @Test func retryInPlaceIncrementsAttempt() async throws {
    let h = try H()
    try h.respond("Errors/err_400_invalid_argument.json", "Responses/resp_text_image.json")
    let conv = try await h.s.store.createConversation()
    let failed = try await h.sendAndWait(h.draft(conv, "x"))
    #expect(failed.attempt == 1)
    try await h.service.retry(requestID: failed.id)
    let snap = try await h.wait(failed.id)
    #expect(snap.state == .succeeded)
    #expect(snap.attempt == 2)
    #expect(snap.replyMessageID == failed.replyMessageID)
    #expect(try await h.s.store.selectorHistory(conv: conv).count == 2)
    await #expect(throws: GenerationError.notRetryable(.succeeded)) { try await h.service.retry(requestID: failed.id) }
  }

  // MARK: Notifications

  @Test func notificationPostedWhenInactive() async throws {
    let h = try H(active: false)
    try h.respond("Responses/resp_text_image.json", "Responses/resp_image_safety.json")
    let conv = try await h.s.store.createConversation()
    _ = try await h.sendAndWait(h.draft(conv, "a lighthouse"))
    _ = try await h.sendAndWait(h.draft(conv, "b"))
    let bodies = h.notifications.value.map(\.body)
    #expect(bodies == ["Image ready", "Request refused: IMAGE_SAFETY"])
    #expect(h.notifications.value.first?.title == "a lighthouse")
    #expect(h.notifications.value.allSatisfy { $0.conversationID == conv })
    // logsNotificationStep
    #expect(await h.probe.entries().contains { $0.kind == .step && $0.message == "notification posted: Image ready" })
  }

  @Test func notificationSuppressedWhenChatVisible() async throws {
    let h = try H(active: true)
    let conv = try await h.s.store.createConversation()
    h.activity.setVisible(conv)
    try h.respond("Responses/resp_text_image.json")
    _ = try await h.sendAndWait(h.draft(conv, "x"))
    #expect(h.notifications.value.isEmpty)
    #expect(await h.probe.entries().contains { $0.kind == .step && $0.message == "notification not posted: chat is on screen" })
    // Another chat on screen: posted.
    let other = try await h.s.store.createConversation()
    try h.respond("Responses/resp_text_image.json")
    _ = try await h.sendAndWait(h.draft(other, "y"))
    #expect(h.notifications.value.count == 1)
  }

  @Test func failedPostIsLoggedAsNotPosted() async throws {
    struct Refused: Error {}
    let poster = NotificationPoster(activity: AppActivity(isActive: false), isEnabled: { true }, deliver: { _ in throw Refused() })
    let outcome = await poster.post(ReplyNotification(conversationID: UUID(), title: "t", body: "b"))
    guard case .failed = outcome else {
      Issue.record("expected a failed post, got \(outcome)")
      return
    }
    #expect(outcome.logText.hasPrefix("notification not posted:"))
  }

  @Test func notificationSuppressedWhenToggleOff() async throws {
    let h = try H(active: false)
    h.notifyEnabled.withLock { $0 = false }
    try h.respond("Responses/resp_text_image.json")
    let conv = try await h.s.store.createConversation()
    _ = try await h.sendAndWait(h.draft(conv, "x"))
    #expect(h.notifications.value.isEmpty)
    #expect(await h.probe.entries().contains { $0.message == "notification not posted: turned off in Settings" })
  }

  @Test func finishedEventsCallsRelayAfterParse() async throws {
    let h = try H(scripted: true)
    let conv = try await h.s.store.createConversation()
    let id = try await h.service.send(h.draft(conv, "x"))
    try await h.wait(id, for: [.inFlight])
    h.scripted!.complete(id, attempt: 1, status: 200, body: try FixtureLoader.data("Responses/resp_text_image.json"))
    h.scripted!.yield(.finishedEvents(sessionIdentifier: "bg"))
    try await h.until { !h.finishedCalls.value.isEmpty }
    let call = try #require(h.finishedCalls.value.first)
    #expect(call.id == "bg")
    #expect(call.handled == 1)
    #expect(call.statesAtCall.isEmpty)
    #expect(try await h.snapshot(id).state == .succeeded)
  }

  // MARK: Log assertions

  @Test func logsSendBeginParametersAndResult() async throws {
    let h = try H()
    try h.respond("Responses/resp_text_image.json")
    let conv = try await h.s.store.createConversation()
    let snap = try await h.sendAndWait(h.draft(conv, "a lighthouse at dusk"))
    let tree = await h.probe.action(named: "Send")
    let begin = try #require(tree.first)
    #expect(begin.origin == .user)
    #expect(begin.message.contains("gemini-3.1-flash-image · 16:9 · 2K · safety BLOCK_NONE · modalities TEXT+IMAGE"))
    #expect(begin.message.contains("input none"))
    #expect(begin.message.contains("prompt \"a lighthouse at dusk\""))
    for name in ["Prepare request", "Attempt 1", "Parse"] {
      #expect(tree.first { $0.name == name && $0.kind == .begin }?.parentID == begin.actionID, "\(name)")
    }
    let attempt = try #require(tree.first { $0.name == "Attempt 1" && $0.kind == .begin })
    #expect(attempt.message.contains("POST /v1beta/models/gemini-3.1-flash-image:generateContent"))
    let bodySize = try FileManager.default.attributesOfItem(atPath: h.s.files.bodyURL(snap.id).path)[.size] as? Int ?? 0
    #expect(attempt.message.contains("body \(Format.mb(bodySize))"))
    let result = try #require(tree.last)
    #expect(result.kind == .result && result.actionID == begin.actionID)
    #expect(result.outcome == .success)
    #expect(result.message.contains("HTTP 200"))
    #expect(result.message.contains("16×9 PNG"))
    #expect(result.message.contains("finish STOP"))
    #expect(try await h.snapshot(snap.id).activityActionID == begin.actionID)
    await h.probe.assertPaired()
  }

  @Test func logsInputSelectionAndCoercion() async throws {
    let h = try H()
    try h.respond("Responses/resp_text_image.json", "Responses/resp_text_image.json")
    let conv = try await h.s.store.createConversation()
    _ = try await h.sendAndWait(h.draft(conv, "draw"))
    _ = try await h.sendAndWait(h.draft(conv, "edit"))
    let sends = await h.probe.entries().filter { $0.name == "Send" && $0.kind == .begin }
    #expect(sends[1].message.contains("input latest (model output img "))
    #expect(sends[1].message.contains("16×9 PNG"))
    #expect(sends[1].message.contains(", sent as original)"))
    let prepare = await h.probe.entries().filter { $0.name == "Prepare request" && $0.kind == .begin }
    #expect(prepare[1].message.contains("original bytes (model output)"))

    // A reused upload.
    let h2 = try H()
    let (conv2, _) = try await uploadThenText(h2)
    try h2.respond("Responses/resp_text_image.json")
    _ = try await h2.sendAndWait(h2.draft(conv2, "edit"))
    let sends2 = await h2.probe.entries().filter { $0.name == "Send" && $0.kind == .begin }
    #expect(sends2[1].message.contains("input latest (upload img "))
    #expect(sends2[1].message.contains("640×480 HEIC"))
    #expect(sends2[1].message.contains("→ sent 640×480 JPEG"))

    // Coercion for 3 Pro.
    let h3 = try H()
    try h3.respond("Responses/resp_text_image.json", model: "gemini-3-pro-image")
    let conv3 = try await h3.s.store.createConversation()
    _ = try await h3.sendAndWait(
      h3.draft(conv3, "x", overrides: ChatOverrides(modelID: "gemini-3-pro-image", aspectRatio: .r1x8, imageSize: .s512)))
    let begin3 = try #require(await h3.probe.action(named: "Send").first)
    #expect(begin3.message.contains("aspect 1:8 → 16:9"))
    #expect(begin3.message.contains("size 512 → 1K"))
  }

  @Test func logsRefusedResult() async throws {
    let h = try H()
    try h.respond("Responses/resp_image_safety.json")
    let conv = try await h.s.store.createConversation()
    _ = try await h.sendAndWait(h.draft(conv, "x"))
    let tree = await h.probe.action(named: "Send")
    let result = try #require(tree.last)
    #expect(result.outcome == .refused)
    #expect(result.message.hasPrefix("IMAGE_SAFETY · HTTP 200"))
    #expect(ActivityLogQuery.lastError(await h.probe.records()) == result.actionID)
  }

  @Test func logsEmptyReplyAsFailed() async throws {
    let h = try H()
    try h.respond("Responses/resp_no_parts_max_tokens.json")
    let conv = try await h.s.store.createConversation()
    let snap = try await h.sendAndWait(h.draft(conv, "x"))
    #expect(snap.state == .failed)
    #expect(try await h.s.store.outcomeFields(snap.id)?.errorStatus == "EMPTY")
    let tree = await h.probe.action(named: "Send")
    let parse = try #require(tree.last { $0.name == "Parse" && $0.kind == .result })
    #expect(parse.outcome == .failed)
    #expect(parse.message.hasPrefix("empty reply · finish MAX_TOKENS"))
    let result = try #require(tree.last)
    #expect(result.outcome == .failed)
    #expect(result.message.hasPrefix("empty reply · finish MAX_TOKENS"))
    #expect(ActivityLogQuery.lastError(await h.probe.records()) == result.actionID)
  }

  @Test func flushesBeforeStoringActionID() async throws {
    let h = try H(logLimits: ActivityLogStore.Limits(rotateAbove: 1 << 30, keepAfterRotation: 1 << 29, writeDelay: .milliseconds(30)))
    try h.respond("Responses/resp_text_image.json")
    let conv = try await h.s.store.createConversation()
    let id = try await h.service.send(h.draft(conv, "x"))
    let snap = try await h.snapshot(id)
    // By the time the record exists with the ID, the Begin was already in the file (read raw, no flush).
    let raw = try String(contentsOf: h.probe.fileURL, encoding: .utf8)
    #expect(raw.contains("\"actionID\":\"\(snap.activityActionID!.raw)\""))
    _ = try await h.wait(id)
  }

  @Test func logsApiErrorTruncated() async throws {
    let h = try H()
    let text = String(repeating: "upstream connect error or disconnect/reset before headers. ", count: 90)
    #expect(text.utf8.count > 5000)
    h.respond(status: 500, body: Data(text.utf8))
    h.respond(status: 500, body: Data(text.utf8))
    h.respond(status: 500, body: Data(text.utf8))
    let conv = try await h.s.store.createConversation()
    _ = try await h.sendAndWait(h.draft(conv, "x"))
    let result = try #require(await h.probe.action(named: "Send").last)
    #expect(result.outcome == .failed)
    #expect(result.message.contains("… (+"))
    #expect(result.message.utf8.count < 2048 + 200)
  }

  @Test func relaunchContinuesSendAction() async throws {
    let h = try H(scripted: true)
    let conv = try await h.s.store.createConversation()
    let id = try await h.service.send(h.draft(conv, "x"))
    try await h.wait(id, for: [.inFlight])
    let sendID = try #require(try await h.snapshot(id).activityActionID)
    _ = await h.probe.lines()
    h.service.stop()

    let h2 = try H(scripted: true, reuse: h)
    h2.scripted!.complete(id, attempt: 1, status: 200, body: try FixtureLoader.data("Responses/resp_text_image.json"))
    #expect(try await h2.wait(id).state == .succeeded)
    let entries = await h2.probe.entries()
    let tree = ActivityLogQuery.tree(sendID, in: entries)
    let attemptResult = try #require(tree.entries.first { $0.name == "Attempt 1" && $0.kind == .result })
    #expect(attemptResult.outcome == .success)
    #expect(tree.entries.contains { $0.name == "Parse" && $0.kind == .begin && $0.parentID == sendID })
    #expect(tree.entries.last?.actionID == sendID)
    #expect(tree.entries.last?.outcome == .success)
    #expect(tree.entries.last?.name == "Send")
    #expect(!entries.contains { $0.outcome == .interrupted })
    await h2.probe.assertPaired()
  }

  @Test func adoptedRetryRecreationFailureClosesAction() async throws {
    let h = try H(scripted: true)
    let conv = try await h.s.store.createConversation()
    let id = try await h.service.send(h.draft(conv, "x"))
    try await h.wait(id, for: [.inFlight])
    h.scripted!.complete(id, attempt: 1, status: 503, body: try FixtureLoader.data("Errors/err_503.json"))
    let scheduled = try await h.wait(id, for: [.retryScheduled])
    #expect(scheduled.nextAttemptCreatedInBackground)
    let sendID = try #require(scheduled.activityActionID)
    _ = await h.probe.lines()
    h.service.stop()

    let h2 = try H(scripted: true, active: true, reuse: h)
    // The background-created task is still waiting in the session.
    let old = try #require(scheduled.taskIdentifier)
    h2.scripted!.live.withLock { $0 = [LiveTask(requestID: id, attempt: 2, taskIdentifier: old, countOfBytesSent: 0)] }
    h2.scripted!.failStarts.withLock { $0 = true }
    await h2.service.appBecameActive()
    #expect(try await h2.wait(id).state == .failed)
    let tree = ActivityLogQuery.tree(sendID, in: await h2.probe.entries())
    let last = try #require(tree.entries.last)
    #expect(last.actionID == sendID && last.kind == .result && last.outcome == .failed)
    #expect(!tree.entries.contains { $0.message.contains("parent finished first") })
    await h2.probe.assertPaired()
  }

  @Test func deletingAdoptedRequestClosesItsActions() async throws {
    let h = try H(scripted: true)
    let conv = try await h.s.store.createConversation()
    let id = try await h.service.send(h.draft(conv, "x"))
    try await h.wait(id, for: [.inFlight])
    let sendID = try #require(try await h.snapshot(id).activityActionID)
    _ = await h.probe.lines()
    h.service.stop()

    let h2 = try H(scripted: true, reuse: h)
    await h2.service.cancel(requestID: id)
    _ = try await h2.s.store.deleteConversation(conv)
    h2.scripted!.complete(id, attempt: 1, error: .cancelled)
    try await h2.until { await h2.probe.entries().contains { $0.actionID == sendID && $0.kind == .result } }
    let tree = ActivityLogQuery.tree(sendID, in: await h2.probe.entries())
    #expect(tree.entries.last?.outcome == .cancelled)
    let attempt = try #require(tree.entries.first { $0.name == "Attempt 1" && $0.kind == .result })
    #expect(attempt.outcome == .cancelled)
    #expect(attempt.message == "the request was deleted")
    await h2.probe.assertPaired()
  }

  @Test func lateCompletionLoggedAsNewAction() async throws {
    let h = try H(scripted: true)
    let conv = try await h.s.store.createConversation()
    let id = try await h.service.send(h.draft(conv, "x"))
    try await h.wait(id, for: [.inFlight])
    await h.service.markInterrupted(id, reason: "the app was closed before this finished")
    let sendID = try #require(try await h.snapshot(id).activityActionID)
    #expect(ActivityLogQuery.lastError(await h.probe.records()) == sendID)

    h.scripted!.complete(id, attempt: 1, status: 200, body: try FixtureLoader.data("Responses/resp_text_image.json"))
    #expect(try await h.wait(id, for: [.succeeded]).state == .succeeded)
    try await h.until { await h.probe.entries().contains { $0.name == "Late completion" && $0.kind == .result } }
    let entries = await h.probe.entries()
    let late = try #require(entries.first { $0.name == "Late completion" && $0.kind == .begin })
    #expect(late.relatedID == sendID)
    #expect(late.message.contains("req \(Format.short(id))"))
    #expect(entries.last { $0.actionID == late.actionID && $0.kind == .result }?.outcome == .success)
    #expect(ActivityLogQuery.tree(sendID, in: entries).lateCompletionIDs.contains(late.actionID))
    #expect(ActivityLogQuery.lastError(await h.probe.records()) != sendID)
    await h.probe.assertPaired()
  }

  @Test func retryPointsRequestAtRetryAction() async throws {
    let h = try H()
    try h.respond("Errors/err_400_invalid_argument.json", "Responses/resp_text_image.json")
    let conv = try await h.s.store.createConversation()
    let failed = try await h.sendAndWait(h.draft(conv, "x"))
    try await h.service.retry(requestID: failed.id)
    _ = try await h.wait(failed.id)
    let retry = await h.probe.action(named: "Retry")
    let begin = try #require(retry.first)
    #expect(begin.message.contains("attempt 2"))
    #expect(begin.message.contains("auto-retry budget reset"))
    #expect(try await h.snapshot(failed.id).activityActionID == begin.actionID)
    #expect(retry.last?.outcome == .success)
    await h.probe.assertPaired()
  }
}
