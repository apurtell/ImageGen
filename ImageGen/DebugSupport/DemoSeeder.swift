#if DEBUG
import Foundation

/// `-SeedDemoData 1` (plan §2.6): five chats in terminal states, with images made by the mock's
/// renderer, keyed for `-Scene chat:<key>`.
enum DemoSeeder {
  static let keysDefault = "DemoSeedKeys"

  static func storedKeys() -> [String: UUID] {
    (UserDefaults.standard.dictionary(forKey: keysDefault) as? [String: String] ?? [:]).compactMapValues(UUID.init(uuidString:))
  }

  /// Seeds when the store has no chats; returns the seed keys.
  static func seedIfEmpty(store: DataStore, files: FileStore) async -> [String: UUID] {
    if let existing = try? await store.janitorSnapshot(), !existing.requests.isEmpty { return storedKeys() }
    var keys: [String: UUID] = [:]
    let s = Seeder(store: store, files: files)
    do {
      // Oldest first, so the list (newest first) reads empty-overrides, textonly, refused, uploads, lighthouse… reversed below.
      keys["empty-overrides"] = try await s.emptyOverrides()
      keys["textonly"] = try await s.textOnly()
      keys["uploads"] = try await s.uploads()
      keys["refused"] = try await s.refused()
      keys["lighthouse"] = try await s.lighthouse()
    } catch {
      Log.store.error("demo seed failed: \(error.localizedDescription, privacy: .public)")
    }
    UserDefaults.standard.set(keys.mapValues(\.uuidString), forKey: keysDefault)
    return keys
  }

  /// `-SeedLargeChat 1` (M9): one chat with 60 messages and 40 images, keyed "large", for
  /// scrolling and decode-timing checks. Seeded once per store.
  static func seedLargeChat(store: DataStore, files: FileStore) async -> UUID? {
    var keys = storedKeys()
    if let existing = keys["large"], (try? await store.conversationTitle(existing)) != nil { return existing }
    do {
      let id = try await Seeder(store: store, files: files).large()
      keys["large"] = id
      UserDefaults.standard.set(keys.mapValues(\.uuidString), forKey: keysDefault)
      return id
    } catch {
      Log.store.error("large chat seed failed: \(error.localizedDescription, privacy: .public)")
      return nil
    }
  }

  private struct Seeder {
    let store: DataStore
    let files: FileStore

    static let flash = EffectiveSettings(
      modelID: ModelCatalog.defaultModelID, aspectRatio: .r16x9, imageSize: .s2K, threshold: .blockNone,
      categories: HarmCategory.allCases, includeTextModality: true, coercions: [])

    func send(_ conv: UUID, _ prompt: String, attachments: [StagedAttachment] = [], reason: SelectionReason? = nil,
              imageIDs: [UUID] = [], settings: EffectiveSettings = flash) async throws -> SendRecord {
      let r = reason ?? (attachments.isEmpty ? .noImage : .attachments)
      return try await store.createSend(
        SendRecordInput(
          conversationID: conv, promptText: prompt, attachments: attachments,
          selection: Selection(imageIDs: r == .attachments ? attachments.map(\.id) : imageIDs, reason: r, clearPin: false),
          settings: settings, activityActionID: ActionID(raw: "0000")))
    }

    /// Completes a request with a rendered image (and optional text) at the mock's size.
    @discardableResult
    func succeed(_ requestID: UUID, conv: UUID, prompt: String, text: String? = nil, aspect: AspectRatio = .r16x9,
                 size: ImageSize = .s2K, withImage: Bool = true) async throws -> UUID? {
      var parts: [MessagePart] = []
      var images: [ReplyImage] = []
      if let text { parts.append(MessagePart(kind: .text, text: text, imageID: nil)) }
      var imageID: UUID?
      if withImage {
        let (w, h) = MockImageSizes.size(aspect: aspect, size: size)
        let id = UUID()
        let relative = files.imageRelativePath(conv: conv, image: id, ext: "jpg")
        try FileStore.createDirectory(files.url(relative: relative).deletingLastPathComponent())
        let data = MockImageRenderer.jpeg(width: w, height: h, prompt: prompt, caption: "\(aspect.rawValue) · \(size.rawValue) · \(w)×\(h)")
        try data.write(to: files.url(relative: relative))
        images.append(ReplyImage(id: id, relativePath: relative, mimeType: "image/jpeg", byteCount: data.count, pixelWidth: w, pixelHeight: h))
        parts.append(MessagePart(kind: .image, text: nil, imageID: id))
        imageID = id
      }
      var patch = RequestPatch()
      patch.state = .succeeded
      patch.attempt = 1
      patch.httpStatus = 200
      patch.finishReason = "STOP"
      patch.modelVersion = "gemini-3.1-flash-image"
      patch.responseID = "seed-\(requestID.uuidString.prefix(8))"
      patch.completedAt = Date()
      patch.outputWidth = images.first?.pixelWidth
      patch.outputHeight = images.first?.pixelHeight
      patch.details = #"{"candidates": [{"finishReason": "STOP"}], "modelVersion": "gemini-3.1-flash-image"}"#
      try await store.completeReply(requestID: requestID, parts: parts, images: images, notices: [], outcomeFields: patch)
      return imageID
    }

    func stage(_ seed: Int) throws -> StagedAttachment {
      let id = UUID()
      let (w, h) = (1200, 900)
      let data = MockImageRenderer.jpeg(width: w, height: h, prompt: "Upload \(seed)", caption: "photo \(seed)")
      let original = files.stagingURL(id, ext: "jpg")
      try FileStore.createDirectory(original.deletingLastPathComponent())
      try data.write(to: original)
      let preparedURL = files.stagingDir.appendingPathComponent("prepared/\(id.uuidString)-2048.jpg")
      try FileStore.createDirectory(preparedURL.deletingLastPathComponent())
      try data.write(to: preparedURL)
      return StagedAttachment(
        id: id, origin: .photos, originalURL: original, originalMimeType: "image/jpeg", originalByteCount: data.count,
        pixelWidth: w, pixelHeight: h, originalFilename: "IMG_000\(seed).JPG",
        prepared: PreparedImage(url: preparedURL, mimeType: "image/jpeg", byteCount: data.count, pixelWidth: w, pixelHeight: h, longEdgeSetting: 2048))
    }

    func lighthouse() async throws -> UUID {
      let conv = try await store.createConversation()
      let p1 = "A lighthouse on a rocky point at dusk"
      let t1 = try await send(conv, p1)
      let first = try await succeed(t1.requestID, conv: conv, prompt: p1, text: "Here is a lighthouse at dusk.")
      let p2 = "Make the sky purple"
      let t2 = try await send(conv, p2, reason: .latest, imageIDs: first.map { [$0] } ?? [])
      _ = try await succeed(t2.requestID, conv: conv, prompt: p2)
      var latest: UUID?
      if let regen = try await store.createRegenerate(sourceRequestID: t2.requestID, activityActionID: ActionID(raw: "0000")) {
        latest = try await succeed(regen.requestID, conv: conv, prompt: p2 + " (regenerated)")
      }
      let p3 = "Add a full moon"
      let t3 = try await send(conv, p3, reason: .latest, imageIDs: latest.map { [$0] } ?? [])
      _ = try await succeed(t3.requestID, conv: conv, prompt: p3)
      if let first { try await store.setPin(conv, imageID: first) }
      return conv
    }

    /// 30 turns: every reply has an image (30), and every sixth turn sends two uploads (10).
    func large() async throws -> UUID {
      let conv = try await store.createConversation()
      let aspects: [AspectRatio] = [.r16x9, .r1x1, .r9x16, .r4x3, .r21x9, .r3x4]
      for turn in 1...30 {
        let prompt = "Scene \(turn): a harbor at a different hour"
        let uploads = turn % 6 == 0 ? [try stage(turn * 10 + 1), try stage(turn * 10 + 2)] : []
        let t = try await send(conv, prompt, attachments: uploads, reason: uploads.isEmpty && turn > 1 ? .latest : nil)
        try await succeed(t.requestID, conv: conv, prompt: prompt, text: "Turn \(turn).", aspect: aspects[turn % aspects.count])
      }
      try await store.rename(conv, to: "Large chat (60 messages)")
      return conv
    }

    func uploads() async throws -> UUID {
      let conv = try await store.createConversation()
      let prompt = "Combine these three photos into one scene"
      let t = try await send(conv, prompt, attachments: [try stage(1), try stage(2), try stage(3)])
      _ = try await succeed(t.requestID, conv: conv, prompt: prompt, text: "Combined.")
      return conv
    }

    func refused() async throws -> UUID {
      let conv = try await store.createConversation()
      let p1 = "Make this photo dramatic"
      let t1 = try await send(conv, p1, attachments: [try stage(4)])
      try await store.updateRequest(t1.requestID) { p in
        p.state = .refused
        p.attempt = 1
        p.httpStatus = 200
        p.refusalReason = "IMAGE_SAFETY"
        p.errorMessage = "Mock: image blocked by safety filter"
        p.details = #"{"candidates": [{"finishReason": "IMAGE_SAFETY", "finishMessage": "Mock: image blocked by safety filter"}]}"#
        p.completedAt = Date()
      }
      let p2 = "Try a calmer version"
      let t2 = try await send(conv, p2, reason: .latest, imageIDs: [])
      try await store.updateRequest(t2.requestID) { p in
        p.state = .failed
        p.attempt = 3
        p.autoRetriesUsed = 2
        p.httpStatus = 429
        p.errorStatus = "RESOURCE_EXHAUSTED"
        p.errorMessage = "You exceeded your current quota, please check your plan and billing details."
        p.details = #"{"error": {"code": 429, "status": "RESOURCE_EXHAUSTED", "message": "You exceeded your current quota"}}"#
        p.completedAt = Date()
      }
      return conv
    }

    func textOnly() async throws -> UUID {
      let conv = try await store.createConversation()
      let prompt = "Explain how to light a night scene"
      let t = try await send(conv, prompt)
      let markdown = """
        ## Lighting a night scene
        - Use a **cool** key light for moonlight
        - Add warm practicals in windows
        - Keep the shadows deep

        ```
        key: 4100K, fill: off, rim: 3200K
        ```
        """
      _ = try await succeed(t.requestID, conv: conv, prompt: prompt, text: markdown, withImage: false)
      return conv
    }

    func emptyOverrides() async throws -> UUID {
      let conv = try await store.createConversation()
      try await store.setOverrides(conv, ChatOverrides(modelID: "gemini-3-pro-image", aspectRatio: .r9x16, imageSize: .s4K))
      let prompt = "What sizes can you make?"
      let t = try await send(conv, prompt)
      _ = try await succeed(t.requestID, conv: conv, prompt: prompt, text: "Up to 4K in many ratios.", withImage: false)
      return conv
    }
  }
}
#endif
