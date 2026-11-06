#if os(macOS)
import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers

@testable import ImageGen

@MainActor
@Suite(.tags(.pure))
struct MacPasteboardTests {
  private func pngData() -> Data {
    let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    return rep.representation(using: .png, properties: [:])!
  }

  @Test func imageDataBecomesOneCandidate() {
    let board = SystemPasteboard.unique()
    defer { board.discard() }
    board.setData(pngData(), type: .png)
    #expect(board.imageCandidates().count == 1)
  }

  @Test func textIsNotAnImage() {
    let board = SystemPasteboard.unique()
    defer { board.discard() }
    board.string = "hello"
    #expect(board.imageCandidates().isEmpty)
  }

  @Test func textAlongsideImageDataStaysText() {
    let raw = NSPasteboard(name: NSPasteboard.Name("ImageGenTests-mixed-\(UUID().uuidString)"))
    defer { raw.releaseGlobally() }
    raw.clearContents()
    raw.setString("caption", forType: .string)
    raw.setData(pngData(), forType: .png)
    #expect(SystemPasteboard(board: raw).imageCandidates().isEmpty)
    // Explicit image paste overrides default text preference.
    #expect(SystemPasteboard(board: raw).imageCandidates(preferringText: false).count == 1)
  }

  private func namedBoard() -> NSPasteboard {
    NSPasteboard(name: NSPasteboard.Name("ImageGenTests-\(UUID().uuidString)"))
  }

  /// Populates the pasteboard with file URL items mimicking Finder copy representations.
  private func write(_ urls: [URL], to board: NSPasteboard) {
    board.clearContents()
    board.writeObjects(
      urls.map { url in
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        item.setString(url.lastPathComponent, forType: .string)
        return item
      })
  }

  @Test func everyCopiedImageFileBecomesACandidate() throws {
    let root = TestFileRoot()
    let urls = try ["a.png", "b.png", "c.png"].map { name -> URL in
      let url = root.url.appendingPathComponent(name)
      try pngData().write(to: url)
      return url
    }
    let board = namedBoard()
    defer { board.releaseGlobally() }
    write(urls, to: board)
    #expect(SystemPasteboard(board: board).imageCandidates().count == 3)
  }

  @Test func copiedNonImagesAreCountedNotAttached() throws {
    let root = TestFileRoot()
    let image = root.url.appendingPathComponent("a.png")
    try pngData().write(to: image)
    let text = root.url.appendingPathComponent("b.txt")
    try Data("x".utf8).write(to: text)
    let board = namedBoard()
    defer { board.releaseGlobally() }
    write([image, text], to: board)
    let content = SystemPasteboard(board: board).imageContent(preferringText: false, readsDataNow: false)
    #expect(content.candidates.count == 1)
    #expect(content.rejected == 1)
    write([text], to: board)
    #expect(SystemPasteboard(board: board).imageContent(preferringText: false, readsDataNow: false).candidates.isEmpty)
  }

  @Test func severalRawImagesAreSeveralCandidates() {
    let board = namedBoard()
    defer { board.releaseGlobally() }
    board.clearContents()
    board.writeObjects(
      (0..<2).map { _ in
        let item = NSPasteboardItem()
        item.setData(pngData(), forType: .png)
        return item
      })
    #expect(SystemPasteboard(board: board).imageCandidates().count == 2)
  }

  @Test func rawImageIsStagedWithItsBytes() async throws {
    let root = TestFileRoot()
    let board = SystemPasteboard.unique()
    defer { board.discard() }
    let data = pngData()
    board.setData(data, type: .png)
    let candidate = try #require(board.imageCandidates().first)
    let url = try await candidate.stage(root.url, UUID())
    #expect(try Data(contentsOf: url) == data)
  }
}

@Suite(.tags(.pure))
struct MainWindowSizingTests {
  @Test func opensAtHalfTheVisibleArea() {
    #expect(MainWindowSizing.defaultSize(visible: CGSize(width: 2560, height: 1400)) == CGSize(width: 1280, height: 700))
  }

  @Test func neverBelowTheMinimum() {
    #expect(MainWindowSizing.defaultSize(visible: CGSize(width: 1440, height: 900)) == CGSize(width: 800, height: 560))
    #expect(MainWindowSizing.defaultSize(visible: CGSize(width: 1700, height: 1000)) == CGSize(width: 850, height: 560))
  }

  @Test func neverLargerThanTheDisplay() {
    #expect(MainWindowSizing.defaultSize(visible: CGSize(width: 700, height: 500)) == CGSize(width: 700, height: 500))
  }
}
#endif
