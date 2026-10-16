import Foundation
import SwiftData
import Synchronization

@testable import ImageGen

/// SwiftData also declares a `DataStore` (custom stores); in tests the name means the app's actor.
typealias DataStore = ImageGen.DataStore

/// An in-memory container, a `DataStore` and a `FileStore` on a `TestFileRoot` (from M2 on).
final class InMemoryStore: Sendable {
  let root: TestFileRoot
  let files: FileStore
  let container: ModelContainer
  let store: DataStore
  let clock: TestClock

  init(clock: TestClock = TestClock()) throws {
    root = TestFileRoot()
    files = FileStore(root: root.url.appendingPathComponent("ImageGen"), cachesRoot: root.url.appendingPathComponent("Caches"))
    container = try StoreFactory.makeContainer(root: files.root, inMemory: true)
    self.clock = clock
    store = DataStore(container: container, files: files, clock: { clock.now })
  }

  /// A second actor on the same container, as after a relaunch.
  func newDataStore() -> DataStore {
    DataStore(container: container, files: files, clock: { [clock] in clock.now })
  }

  /// Writes an original and a prepared file into `Staging/`, as the composer would.
  func stage(
    origin: ImageOrigin = .photos, original: Data = ImageFactory.png(), originalMime: String = "image/png",
    width: Int = 32, height: Int = 18, edge: Int = 2048, seed: Int = 0
  ) throws -> StagedAttachment {
    let id = UUID()
    let ext = MimeTypes.fileExtension(for: originalMime)
    let originalURL = files.stagingURL(id, ext: ext)
    try FileStore.createDirectory(originalURL.deletingLastPathComponent())
    try original.write(to: originalURL)
    let preparedData = ImageFactory.jpeg(width: width, height: height, seed: seed)
    let preparedURL = files.stagingDir.appendingPathComponent("prepared/\(id.uuidString)-\(edge).jpg")
    try FileStore.createDirectory(preparedURL.deletingLastPathComponent())
    try preparedData.write(to: preparedURL)
    return StagedAttachment(
      id: id, origin: origin, originalURL: originalURL, originalMimeType: originalMime, originalByteCount: original.count,
      pixelWidth: width, pixelHeight: height, originalFilename: "IMG_\(seed).png",
      prepared: PreparedImage(
        url: preparedURL, mimeType: "image/jpeg", byteCount: preparedData.count, pixelWidth: width, pixelHeight: height,
        longEdgeSetting: edge))
  }

  static let settings = EffectiveSettings(
    modelID: ModelCatalog.defaultModelID, aspectRatio: .r16x9, imageSize: .s2K, threshold: .blockNone,
    categories: HarmCategory.allCases, includeTextModality: true, coercions: [])

  /// Records a send with the given attachments (selection `.attachments`, or `.noImage` without any).
  @discardableResult
  func send(
    _ conv: UUID, prompt: String, attachments: [StagedAttachment] = [], selection: Selection? = nil,
    settings: EffectiveSettings = InMemoryStore.settings, action: ActionID = ActionID(raw: "ab12")
  ) async throws -> SendRecord {
    let sel =
      selection
      ?? Selection(
        imageIDs: attachments.map(\.id), reason: attachments.isEmpty ? .noImage : .attachments, clearPin: false)
    return try await store.createSend(
      SendRecordInput(
        conversationID: conv, promptText: prompt, attachments: attachments, selection: sel, settings: settings,
        activityActionID: action))
  }
}

/// A settable clock.
final class TestClock: Sendable {
  private let value: Mutex<Date>

  init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) { value = Mutex(start) }

  var now: Date { value.withLock { $0 } }

  func advance(_ seconds: TimeInterval) { value.withLock { $0 += seconds } }

  func set(_ date: Date) { value.withLock { $0 = date } }
}
