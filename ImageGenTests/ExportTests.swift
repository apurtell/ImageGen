import CoreTransferable
import Foundation
import Photos
import Testing
import UniformTypeIdentifiers

@testable import ImageGen

/// Controllable mock implementing `PhotoLibraryAccess` for testing photo authorization and persistence behaviors.
final class FakePhotoLibrary: PhotoLibraryAccess {
  let status: PHAuthorizationStatus
  let failure: String?
  let added = Locked<[(url: URL, name: String)]>([])

  init(status: PHAuthorizationStatus, failure: String? = nil) {
    self.status = status
    self.failure = failure
  }

  struct Failure: LocalizedError {
    let errorDescription: String?
  }

  func requestAddAuthorization() async -> PHAuthorizationStatus { status }

  func addPhoto(fileURL: URL, originalFilename: String) async throws {
    if let failure { throw Failure(errorDescription: failure) }
    added.withLock { $0.append((fileURL, originalFilename)) }
  }
}

/// Writes synthetic image data to a temporary file, returning an `ExportItem` model representing the asset.
func exportItem(in root: TestFileRoot, data: Data, mime: String, ext: String, width: Int = 64, height: Int = 48)
  throws -> ExportItem
{
  let id = UUID()
  let url = root.url.appendingPathComponent("\(id.uuidString).\(ext)")
  try data.write(to: url)
  return ExportItem(
    id: id, url: url, mimeType: mime, byteCount: data.count, pixelWidth: width, pixelHeight: height,
    createdAt: Date(timeIntervalSince1970: 1_800_000_000))
}

@MainActor
@Suite(.tags(.io))
struct ExportTests {
  static let originals: [(mime: String, ext: String, type: String)] = [
    ("image/jpeg", "jpg", "public.jpeg"), ("image/png", "png", "public.png"), ("image/webp", "webp", "org.webmproject.webp"),
    ("image/heic", "heic", "public.heic"),
  ]

  static func bytes(_ mime: String) -> Data {
    switch mime {
    case "image/jpeg": ImageFactory.jpeg()
    case "image/png": ImageFactory.png()
    case "image/heic": ImageFactory.heic()
    // Encodes synthetic RIFF/WebP headers since ImageIO lacks built-in WebP export encoding support.
    default: Data("RIFF\u{0}\u{0}\u{0}\u{0}WEBPVP8 fake".utf8)
    }
  }

  @Test(arguments: [0, 1, 2, 3])
  func imageFileExportsByteIdentical(index: Int) async throws {
    let o = Self.originals[index]
    let root = TestFileRoot()
    let data = Self.bytes(o.mime)
    let item = try exportItem(in: root, data: data, mime: o.mime, ext: o.ext)
    let file = item.file
    #expect(file.utType.identifier == o.type)

    // Asserts uniform type identifier fidelity across the exported representation.
    let provider = file.itemProvider
    #expect(provider.registeredTypeIdentifiers == [o.type])

    // Verifies byte-identical payload integrity through asynchronous file representation export.
    let copied: Data = try await withCheckedThrowingContinuation { c in
      _ = provider.loadFileRepresentation(forTypeIdentifier: o.type) { url, error in
        if let url, let d = try? Data(contentsOf: url) { c.resume(returning: d) } else { c.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
      }
    }
    #expect(GenerationHarness.sha256(copied) == GenerationHarness.sha256(data))
    #expect(try await file.exported(as: file.utType) == data)
  }

  @Test func suggestedNameFormat() {
    let id = UUID(uuidString: "7F3A9C12-0000-4000-8000-000000000000")!
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC")!
    let date = utc.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 14, minute: 32, second: 50))!
    #expect(ImageFile.suggestedName(date: date, id: id, ext: "jpg", timeZone: TimeZone(identifier: "UTC")!)
      == "ImageGen-2026-10-15-1432-7f3a9c.jpg")
  }

  @Test func utTypeFromMime() {
    #expect(ImageFile.utType(forMime: "image/jpeg") == .jpeg)
    #expect(ImageFile.utType(forMime: "image/png") == .png)
    #expect(ImageFile.utType(forMime: "image/heic") == .heic)
    #expect(ImageFile.utType(forMime: "image/webp") == .webP)
  }

  @Test func pasteboardHoldsOriginalBytesOnlyOneType() async throws {
    let probe = ActivityLogProbe(root: TestFileRoot())
    let pasteboard = SystemPasteboard.unique()
    defer { pasteboard.discard() }
    let data = ImageFactory.png()
    let item = try exportItem(in: probe.root, data: data, mime: "image/png", ext: "png")
    #expect(await PasteboardWriter(pasteboard: pasteboard, log: probe.log).copy(item))
    #expect(pasteboard.itemCount == 1)
    #if os(iOS)
    #expect(pasteboard.typeIdentifiers == ["public.png"])
    #else
    // AppKit adds converted image types automatically, but the original bytes remain under the primary type.
    #expect(pasteboard.typeIdentifiers.first == "public.png")
    #endif
    #expect(pasteboard.data(for: .png) == data)
  }

  @Test func saveToPhotosLogged() async throws {
    let probe = ActivityLogProbe(root: TestFileRoot())
    let item = try exportItem(in: probe.root, data: ImageFactory.jpeg(), mime: "image/jpeg", ext: "jpg", width: 2752, height: 1536)
    let library = FakePhotoLibrary(status: .authorized)
    let model = ImageExportModel(log: probe.log, photoLibrary: library, pasteboard: SystemPasteboard.unique())
    await model.saveToPhotos(item)
    #expect(library.added.value.map(\.name) == [item.suggestedName])
    #expect(library.added.value.first?.url == item.url)
    #expect(model.toast == "Saved to Photos")
    let tree = await probe.action(named: "Save to Photos")
    #expect(tree.first?.message == "img \(Format.short(item.id)) · JPEG · \(Format.mb(item.byteCount)) · 2752×1536")
    #expect(tree.last?.outcome == .success)
    #expect(tree.last?.message == "authorization authorized · saved as \(item.suggestedName)")

    let denied = ImageExportModel(log: probe.log, photoLibrary: FakePhotoLibrary(status: .denied))
    await denied.saveToPhotos(item)
    #expect(denied.showPhotosDenied)
    let deniedTree = await probe.action(named: "Save to Photos")
    #expect(deniedTree.last?.outcome == .failed)
    #expect(deniedTree.last?.message == "authorization denied · not saved")
    await probe.assertPaired()
  }

  @Test func saveToFilesLogged() async throws {
    let probe = ActivityLogProbe(root: TestFileRoot())
    let item = try exportItem(in: probe.root, data: ImageFactory.jpeg(), mime: "image/jpeg", ext: "jpg")
    let model = ImageExportModel(log: probe.log, photoLibrary: FakePhotoLibrary(status: .authorized))
    model.saveToFiles(item)
    #expect(model.fileExport == item)
    model.filesFinished(.success(URL(fileURLWithPath: "/tmp/\(item.suggestedName)")))
    #expect(model.fileExport == nil)
    var tree = await probe.action(named: "Save to Files")
    #expect(tree.first?.message.hasSuffix(" · \(item.suggestedName)") == true)
    #expect(tree.last?.outcome == .success)
    #expect(tree.last?.message == "saved \(item.suggestedName)")

    model.saveToFiles(item)
    model.filesFinished(nil)
    model.filesFinished(nil)
    tree = await probe.action(named: "Save to Files")
    #expect(tree.last?.outcome == .cancelled)
    await probe.assertPaired()
  }

  @Test func copyLogged() async throws {
    let probe = ActivityLogProbe(root: TestFileRoot())
    let pasteboard = SystemPasteboard.unique()
    defer { pasteboard.discard() }
    let data = ImageFactory.jpeg()
    let item = try exportItem(in: probe.root, data: data, mime: "image/jpeg", ext: "jpg")
    let model = ImageExportModel(log: probe.log, photoLibrary: FakePhotoLibrary(status: .authorized), pasteboard: pasteboard)
    await model.copy(item)
    #expect(pasteboard.data(for: .jpeg) == data)
    let tree = await probe.action(named: "Copy")
    #expect(tree.first?.message == "image · \(item.logDescription)")
    #expect(tree.last?.message == "pasteboard written (1 item, public.jpeg)")
    await probe.assertPaired()
  }

  @Test func shareLogged() async throws {
    let probe = ActivityLogProbe(root: TestFileRoot())
    let item = try exportItem(in: probe.root, data: ImageFactory.png(), mime: "image/png", ext: "png")
    let model = ImageExportModel(log: probe.log, photoLibrary: FakePhotoLibrary(status: .authorized))

    model.beginShare(item)
    let ticket = try #require(model.share)
    var tree = await probe.action(named: "Share")
    #expect(tree.first?.message == item.logDescription)
    #expect(tree.count == 1)
    model.shareFinished(ticket, activityType: "com.apple.UIKit.activity.AirDrop", completed: true, error: nil)
    model.shareFinished(ticket, activityType: nil, completed: false, error: nil)
    model.shareDisappeared(ticket)
    #expect(model.share == nil)
    tree = await probe.action(named: "Share")
    #expect(tree.count == 2)
    #expect(tree.last?.outcome == .success)
    #expect(tree.last?.message == "via com.apple.UIKit.activity.AirDrop")

    model.beginShare(item)
    let second = try #require(model.share)
    model.shareFinished(second, activityType: nil, completed: false, error: nil)
    tree = await probe.action(named: "Share")
    #expect(tree.last?.outcome == .cancelled)

    // Verifies uncompleted share activities are cancelled on view dismissal.
    model.beginShare(item)
    let third = try #require(model.share)
    model.shareDisappeared(third)
    model.shareDisappeared(third)
    tree = await probe.action(named: "Share")
    #expect(tree.last?.outcome == .cancelled)
    await probe.assertPaired()
  }

  @Test func openExportsClosedWhenSupersededOrScreenCloses() async throws {
    let probe = ActivityLogProbe(root: TestFileRoot())
    let item = try exportItem(in: probe.root, data: ImageFactory.png(), mime: "image/png", ext: "png")
    let model = ImageExportModel(log: probe.log, photoLibrary: FakePhotoLibrary(status: .authorized))
    model.saveToFiles(item)
    model.saveToFiles(item)
    model.beginShare(item)
    model.beginShare(item)
    model.closeOpenActions()
    let entries = await probe.entries()
    #expect(entries.filter { $0.name == "Save to Files" && $0.kind == .result }.map(\.outcome) == [.cancelled, .cancelled])
    #expect(entries.filter { $0.name == "Share" && $0.kind == .result }.map(\.outcome) == [.cancelled, .cancelled])
    #expect(entries.contains { $0.message == "superseded by another Save to Files" })
    await probe.assertPaired()
  }

  @Test(arguments: ["image/jpeg", "image/png", "image/webp", "image/heic", "image/heif", "image/gif", "image/avif"])
  func documentCanWriteEveryExportType(mime: String) {
    #expect(ImageFileDocument.writableContentTypes.contains(ImageFile.utType(forMime: mime)))
  }

  @Test func exportScratchHoldsNamedCopiesUntilSwept() throws {
    let root = TestFileRoot()
    let source = root.url.appendingPathComponent("stored.png")
    try ImageFactory.png().write(to: source)
    let copy = try ExportScratch.namedCopy(of: source, name: "ImageGen-friendly.png")
    #expect(copy.lastPathComponent == "ImageGen-friendly.png")
    #expect(try Data(contentsOf: copy) == Data(contentsOf: source))
    #expect(copy.path.hasPrefix(ExportScratch.root.path))
  }

  @Test func draggedCopyIsAFileUnderTheSuggestedName() async throws {
    let root = TestFileRoot()
    let data = ImageFactory.jpeg()
    let item = try exportItem(in: root, data: data, mime: "image/jpeg", ext: "jpg")
    let provider = item.file.draggedCopyProvider()
    // File URLs preserve exact suggested filename extensions rather than uniform type identifiers.
    #expect(provider.registeredTypeIdentifiers.contains(UTType.fileURL.identifier))
    #expect(!provider.registeredTypeIdentifiers.contains(UTType.jpeg.identifier))
    let url: URL? = await withCheckedContinuation { continuation in
      _ = provider.loadObject(ofClass: NSURL.self) { object, _ in continuation.resume(returning: object as? URL) }
    }
    let copy = try #require(url)
    #expect(copy.lastPathComponent == item.suggestedName)
    #expect(copy.pathExtension == "jpg")
    #expect(copy.path.hasPrefix(ExportScratch.root.path))
    #expect(try Data(contentsOf: copy) == data)
  }

  @Test func writingAFileKeepsItsBytes() throws {
    let root = TestFileRoot()
    let data = ImageFactory.jpeg()
    let item = try exportItem(in: root, data: data, mime: "image/jpeg", ext: "jpg")
    let destination = root.url.appendingPathComponent("saved.jpg")
    try item.file.write(to: destination)
    #expect(try Data(contentsOf: destination) == data)
    #expect(try Data(contentsOf: item.url) == data)
  }

  @Test func writingOverAFileReplacesIt() throws {
    let root = TestFileRoot()
    let data = ImageFactory.jpeg()
    let item = try exportItem(in: root, data: data, mime: "image/jpeg", ext: "jpg")
    let destination = root.url.appendingPathComponent("saved.jpg")
    try Data("older".utf8).write(to: destination)
    try item.file.write(to: destination)
    #expect(try Data(contentsOf: destination) == data)
    #expect(try Data(contentsOf: item.url) == data)
  }

  @Test func aFailedWriteLeavesTheExistingFile() throws {
    let root = TestFileRoot()
    let destination = root.url.appendingPathComponent("saved.jpg")
    try Data("older".utf8).write(to: destination)
    let file = ImageFile(url: root.url.appendingPathComponent("missing.jpg"), utType: .jpeg, suggestedName: "x.jpg")
    #expect(throws: (any Error).self) { try file.write(to: destination) }
    #expect(try Data(contentsOf: destination) == Data("older".utf8))
  }

  @Test func shareProviderCarriesOriginalType() throws {
    let root = TestFileRoot()
    let item = try exportItem(in: root, data: ImageFactory.heic(), mime: "image/heic", ext: "heic")
    let provider = item.file.itemProvider
    #expect(provider.registeredTypeIdentifiers == [UTType.heic.identifier])
    #expect(provider.suggestedName == item.suggestedName)
  }
}

@Suite(.tags(.pure))
struct PhotoLibrarySaverTests {
  @Test(arguments: [
    (PHAuthorizationStatus.authorized, PhotoSaveResult.saved), (.limited, .saved), (.denied, .denied),
    (.restricted, .denied), (.notDetermined, .denied),
  ])
  func authorizationMapping(status: PHAuthorizationStatus, expected: PhotoSaveResult) async throws {
    let probe = ActivityLogProbe(root: TestFileRoot())
    let library = FakePhotoLibrary(status: status)
    let item = try exportItem(in: probe.root, data: ImageFactory.jpeg(), mime: "image/jpeg", ext: "jpg")
    #expect(await PhotoLibrarySaver(library: library, log: probe.log).save(item) == expected)
    #expect(library.added.value.count == (expected == .saved ? 1 : 0))
    let tree = await probe.action(named: "Save to Photos")
    #expect(tree.last?.message.hasPrefix("authorization \(PhotoLibrarySaver.name(status))") == true)
  }

  @Test func addFailureReported() async throws {
    let probe = ActivityLogProbe(root: TestFileRoot())
    let item = try exportItem(in: probe.root, data: ImageFactory.jpeg(), mime: "image/jpeg", ext: "jpg")
    let result = await PhotoLibrarySaver(library: FakePhotoLibrary(status: .authorized, failure: "disk full"), log: probe.log).save(item)
    #expect(result == .failed("disk full"))
    #expect(await probe.action(named: "Save to Photos").last?.outcome == .failed)
  }

  @Test(.tags(.integration), .enabled(if: ProcessInfo.processInfo.environment["IMAGEGEN_PHOTOS_GRANTED"] == "1"))
  func savesToSimulatorLibrary() async throws {
    let probe = ActivityLogProbe(root: TestFileRoot())
    let item = try exportItem(in: probe.root, data: ImageFactory.jpeg(width: 320, height: 180), mime: "image/jpeg", ext: "jpg", width: 320, height: 180)
    #expect(await PhotoLibrarySaver(library: SystemPhotoLibrary(), log: probe.log).save(item) == .saved)
  }
}

@Suite(.tags(.pure))
struct ZoomMathTests {
  @Test func fitScale() {
    #expect(ZoomMath.fitScale(image: CGSize(width: 2752, height: 1536), bounds: CGSize(width: 440, height: 956)) == CGFloat(440) / 2752)
    #expect(ZoomMath.fitScale(image: CGSize(width: 1000, height: 4000), bounds: CGSize(width: 400, height: 800)) == 0.2)
  }

  @Test func maxScaleIsLargerOfPixelDoubleAndFourTimesFit() {
    // High-resolution images prioritize 2x 1:1 pixel scale over 4x fit bounds.
    #expect(abs(ZoomMath.maxScale(fit: 0.08, screenScale: 3) - 2.0 / 3.0) < 1e-9)
    // Low-resolution images bound maximum zoom to 4x fit scale.
    #expect(ZoomMath.maxScale(fit: 1.5, screenScale: 3) == 6)
  }

  @Test func doubleTapRectCentersOnPoint() {
    let rect = ZoomMath.zoomRect(center: CGPoint(x: 1000, y: 600), scale: 0.4, bounds: CGSize(width: 400, height: 800))
    #expect(rect == CGRect(x: 500, y: -400, width: 1000, height: 2000))
    #expect(rect.midX == 1000 && rect.midY == 600)
  }

  @Test func centeringInsets() {
    let i = ZoomMath.centeringInsets(content: CGSize(width: 440, height: 245), bounds: CGSize(width: 440, height: 956))
    #expect(i.horizontal == 0 && i.vertical == 355.5)
  }
}
