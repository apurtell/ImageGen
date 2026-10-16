import Foundation
import Synchronization
import Testing

@testable import ImageGen

extension TrayItem {
  enum FakeState { case ready, preparing, failed }

  /// A tray item with no files behind it, for enablement and ordering checks.
  static func fake(_ state: FakeState) -> TrayItem {
    let id = UUID()
    let s: TrayItem.State =
      switch state {
      case .ready:
        .ready(
          PreparedImage(
            url: URL(fileURLWithPath: "/tmp/\(id.uuidString).jpg"), mimeType: "image/jpeg", byteCount: 100, pixelWidth: 32,
            pixelHeight: 18, longEdgeSetting: 2048))
      case .preparing: .preparing
      case .failed: .failed("Unsupported or damaged image")
      }
    return TrayItem(id: id, origin: .photos, state: s, originalURL: URL(fileURLWithPath: "/tmp/\(id.uuidString).png"))
  }
}

/// Holds callers until opened.
final class Gate: Sendable {
  private let state = Mutex<(open: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

  func wait() async {
    await withCheckedContinuation { c in
      let resume = state.withLock { s in
        if s.open { return true }
        s.waiters.append(c)
        return false
      }
      if resume { c.resume() }
    }
  }

  func open() {
    let waiters = state.withLock { s in
      s.open = true
      defer { s.waiters = [] }
      return s.waiters
    }
    for w in waiters { w.resume() }
  }
}

@MainActor
func waitUntil(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
  for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
  #expect(condition(), sourceLocation: sourceLocation)
}

@MainActor
@Suite(.tags(.integration))
struct ComposerAttachmentsTests {
  typealias Rig = ChatScreenModelTests.Rig

  static let gatedPrepare: (Gate) -> @Sendable (URL, Int, URL, UUID) async throws -> PreparedImage = { gate in
    { source, edge, dir, id in
      await gate.wait()
      return try await ImagePreprocessor.prepare(source: source, maxLongEdge: edge, destinationDir: dir, id: id)
    }
  }

  func files(_ count: Int, in root: TestFileRoot) throws -> [AttachmentCandidate] {
    try (0..<count).map { i in
      let url = root.url.appendingPathComponent("pick-\(i).png")
      try ImageFactory.png(width: 40, height: 30, seed: i).write(to: url)
      return AttachmentCandidate.file(url)
    }
  }

  @Test func capAt14WithToast() async throws {
    let r = try await Rig()
    r.model.tray = (0..<12).map { _ in .fake(.ready) }
    await r.model.attach(try files(4, in: r.s.root), from: .files)
    #expect(r.model.tray.count == 14)
    #expect(r.model.toast == "Up to 14 images per message")
    #expect(r.model.tray.suffix(2).allSatisfy { $0.prepared != nil })
  }

  @Test func fullTrayDisablesAttachEntryPoints() async throws {
    let r = try await Rig()
    r.model.tray = (0..<13).map { _ in .fake(.ready) }
    #expect(r.model.canAddAttachments)
    r.model.tray.append(.fake(.ready))
    #expect(!r.model.canAddAttachments)
  }

  @Test func pickerLimitNeverZero() {
    #expect(ChatScreenModel.pickerLimit(trayCount: 0) == 14)
    #expect(ChatScreenModel.pickerLimit(trayCount: 13) == 1)
    #expect(ChatScreenModel.pickerLimit(trayCount: 14) == 1)
  }

  @Test func reorderMoves() async throws {
    let r = try await Rig()
    let items: [TrayItem] = [.fake(.ready), .fake(.ready), .fake(.ready)]
    r.model.tray = items
    r.model.moveTrayItem(items[1].id, by: -1)
    #expect(r.model.tray.map(\.id) == [items[1].id, items[0].id, items[2].id])
    r.model.moveTrayItem(items[1].id, by: -1)
    #expect(r.model.tray.map(\.id) == [items[1].id, items[0].id, items[2].id])
    r.model.moveTrayItem(items[0].id, by: 1)
    #expect(r.model.tray.map(\.id) == [items[1].id, items[2].id, items[0].id])
  }

  @Test func removeDeletesStagedFiles() async throws {
    let r = try await Rig()
    await r.model.attach([.data(ImageFactory.png(width: 40, height: 30))], from: .photos)
    let item = try #require(r.model.tray.first)
    let original = try #require(item.originalURL)
    let prepared = try #require(item.prepared?.url)
    #expect(FileManager.default.fileExists(atPath: original.path))
    #expect(FileManager.default.fileExists(atPath: prepared.path))
    r.model.removeTrayItem(item.id)
    #expect(r.model.tray.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: original.path))
    #expect(!FileManager.default.fileExists(atPath: prepared.path))
  }

  @Test func projectedSizeMatchesWriter() async throws {
    let r = try await Rig()
    await r.model.attach([.data(ImageFactory.png(width: 40, height: 30)), .data(ImageFactory.heic())], from: .photos)
    r.model.composerText = "combine these"
    let ready = r.model.tray.compactMap(\.prepared)
    #expect(ready.count == 2)
    let spec = RequestBodySpec(
      images: ready.map { BodyImage(fileURL: $0.url, mimeType: $0.mimeType, byteCount: $0.byteCount) },
      promptText: "combine these", settings: r.model.effective)
    let out = r.s.root.url.appendingPathComponent("body.json")
    let written = try await RequestBodyWriter.write(spec, to: out)
    #expect(r.model.projectedBodyBytes == written)
    #expect(r.model.trayCaption.hasPrefix("2 images · "))
    #expect(r.model.trayCaption.hasSuffix(" of 19 MB"))
  }

  @Test func failedItemBlocksSendUntilRemoved() async throws {
    let r = try await Rig()
    r.model.composerText = "a red fox"
    await r.model.attach([.data(Data("not an image".utf8))], from: .paste)
    let item = try #require(r.model.tray.first)
    #expect(item.failure == "Unsupported or damaged image")
    #expect(!r.model.canSend)
    #expect(r.model.trayCaption == "Remove the image that couldn't be prepared")
    r.model.removeTrayItem(item.id)
    #expect(r.model.canSend)
  }

  @Test func preparingItemBlocksSend() async throws {
    let gate = Gate()
    let r = try await Rig(prepareUpload: Self.gatedPrepare(gate))
    r.model.composerText = "a red fox"
    let attach = Task { await r.model.attach([.data(ImageFactory.png())], from: .photos) }
    try await waitUntil { r.model.tray.first?.state == .preparing }
    #expect(!r.model.canSend)
    #expect(r.model.trayCaption == "Preparing images…")
    gate.open()
    await attach.value
    #expect(r.model.canSend)
  }

  @Test func attachmentsOnlyEnablesSend() async throws {
    let r = try await Rig()
    #expect(!r.model.canSend)
    await r.model.attach([.data(ImageFactory.png())], from: .photos)
    #expect(r.model.composerText.isEmpty)
    #expect(r.model.canSend)
  }

  @Test func sendDraftKeepsTrayOrder() async throws {
    let r = try await Rig()
    await r.model.attach(
      [.data(ImageFactory.png(seed: 1)), .data(ImageFactory.png(seed: 2)), .data(ImageFactory.png(seed: 3))], from: .photos)
    r.model.moveTrayItem(r.model.tray[2].id, by: -1)
    let order = r.model.tray.map(\.id)
    await r.model.send()
    let sent = try #require(r.generation.sends.value.first)
    #expect(sent.attachments.map(\.id) == order)
    #expect(sent.attachments.allSatisfy { $0.origin == .photos && $0.prepared.longEdgeSetting == 2048 })
    #expect(r.model.tray.isEmpty)
  }

  // MARK: Log assertions

  @Test func attachLogsSourceAndPreparation() async throws {
    let r = try await Rig()
    await r.model.attach(
      [.data(ImageFactory.heic(width: 64, height: 48)), .data(ImageFactory.jpeg(width: 40, height: 30)), .data(ImageFactory.png())],
      from: .photos)
    let tree = await r.probe.action(named: "Attach")
    let begin = try #require(tree.first)
    #expect(begin.message == "Photos · 3 items · tray 0 · max long edge 2048")
    #expect(begin.origin == .user)
    let children = tree.filter { $0.name == "Prepare attachment" && $0.kind == .begin }
    #expect(children.count == 3)
    #expect(children.allSatisfy { $0.parentID == begin.actionID })
    #expect(children.contains { $0.message.contains("HEIC 64×48") })
    let childResults = tree.filter { e in e.kind == .result && children.contains { $0.actionID == e.actionID } }
    #expect(childResults.count == 3)
    #expect(childResults.allSatisfy { $0.outcome == .success && $0.message.contains("EXIF stripped") })
    let result = try #require(tree.last)
    #expect(result.actionID == begin.actionID && result.kind == .result && result.outcome == .success)
    #expect(result.message.contains("3 imported and prepared"))
    #expect(!(await r.probe.entries()).contains { $0.message.contains("parent finished first") })
    await r.probe.assertPaired()
  }

  @Test func attachPartialFailureEndsFailed() async throws {
    let r = try await Rig()
    await r.model.attach([.data(ImageFactory.png()), .data(Data("nope".utf8)), .data(ImageFactory.png(seed: 2))], from: .photos)
    let tree = await r.probe.action(named: "Attach")
    let begin = try #require(tree.first)
    #expect(tree.contains { $0.kind == .step && $0.message.contains("import failed: ") && $0.message.contains("Unsupported or damaged image") })
    #expect(tree.count(where: { $0.name == "Prepare attachment" && $0.kind == .begin }) == 2)
    let result = try #require(tree.last)
    #expect(result.outcome == .failed)
    #expect(result.message.contains("2 of 3 imported and prepared · 1 failed: Unsupported or damaged image"))
    #expect(ActivityLogQuery.lastError(await r.probe.records()) == begin.actionID)
    await r.probe.assertPaired()
  }

  @Test func attachCapDropIsNotFailure() async throws {
    let r = try await Rig()
    r.model.tray = (0..<12).map { _ in .fake(.ready) }
    await r.model.attach(try files(4, in: r.s.root), from: .files)
    let tree = await r.probe.action(named: "Attach")
    #expect(tree.first?.message == "Files · 4 items · tray 12 · max long edge 2048")
    #expect(tree.contains { $0.kind == .step && $0.message == "dropped 2 over the 14-image cap" })
    let result = try #require(tree.last)
    #expect(result.outcome == .success)
    #expect(result.message.contains("2 imported and prepared · 2 dropped over the cap"))
    await r.probe.assertPaired()
  }

  @Test func removeWhilePreparingCancelsChild() async throws {
    let gate = Gate()
    let r = try await Rig(prepareUpload: Self.gatedPrepare(gate))
    let attach = Task { await r.model.attach([.data(ImageFactory.png())], from: .photos) }
    try await waitUntil { r.model.tray.first?.state == .preparing }
    let id = try #require(r.model.tray.first?.id)
    r.model.removeTrayItem(id)
    gate.open()
    await attach.value
    let entries = await r.probe.entries()
    let child = try #require(entries.first { $0.name == "Prepare attachment" && $0.kind == .begin })
    let childResult = try #require(entries.first { $0.actionID == child.actionID && $0.kind == .result })
    #expect(childResult.outcome == .cancelled)
    #expect(entries.contains { $0.name == "Tray change" && $0.message == "img \(Format.short(id)) · removed (preparing) · tray 0" })
    let staged = try FileManager.default.contentsOfDirectory(atPath: r.s.files.stagingDir.path).filter { $0 != "prepared" }
    #expect(staged.isEmpty)
    await r.probe.assertPaired()
  }

  @Test func trayReorderLogged() async throws {
    let r = try await Rig()
    let items: [TrayItem] = [.fake(.ready), .fake(.ready), .fake(.ready)]
    r.model.tray = items
    r.model.moveTrayItem(items[1].id, by: -1)
    let tree = await r.probe.action(named: "Tray change")
    #expect(tree.first?.message == "img \(Format.short(items[1].id)) · position 2 → 1 · tray 3")
    #expect(tree.last?.outcome == .success)
  }
}

struct FileImportTests {
  @Test func securityScopedCopyKeepsBytes() throws {
    let root = TestFileRoot()
    let source = root.url.appendingPathComponent("picked.jpg")
    let data = ImageFactory.jpeg(width: 64, height: 48)
    try data.write(to: source)
    let id = UUID()
    let copy = try FileImport.copySecurityScoped(source, into: root.url.appendingPathComponent("Staging"), id: id)
    #expect(copy.lastPathComponent == "\(id.uuidString).jpg")
    #expect(GenerationHarness.sha256(try Data(contentsOf: copy)) == GenerationHarness.sha256(data))
  }
}

struct PasteSupportTests {
  @Test(arguments: [("png", "public.png"), ("jpeg", "public.jpeg"), ("heic", "public.heic")])
  func detectsTypeAndStages(kind: String, identifier: String) throws {
    let data =
      switch kind {
      case "png": ImageFactory.png()
      case "jpeg": ImageFactory.jpeg(width: 32, height: 18)
      default: ImageFactory.heic()
      }
    let pasted = PastedImage(data: data)
    #expect(pasted.detectedType?.identifier == identifier)
    let root = TestFileRoot()
    let url = try AttachmentStaging.write(pasted.data, into: root.url, id: UUID())
    #expect(url.pathExtension == (pasted.detectedType?.preferredFilenameExtension ?? ""))
    #expect(try Data(contentsOf: url) == data)
  }

  @Test func nonImageRejected() throws {
    #expect(PastedImage(data: Data("text".utf8)).detectedType == nil)
    #expect(throws: UnsupportedImageError.self) {
      try AttachmentStaging.write(Data("text".utf8), into: TestFileRoot().url, id: UUID())
    }
  }
}
