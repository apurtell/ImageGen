import CoreGraphics
import Foundation
import Testing

@testable import ImageGen

@Suite(.tags(.io))
struct ThumbnailServiceTests {
  @Test func makesBothSizesAndCaches() async throws {
    let root = TestFileRoot()
    let source = root.file("Images/x.jpg")
    try ImageFactory.jpeg(width: 1600, height: 900).write(to: source)
    let dir = root.directory("Caches/Thumbnails")
    let service = ThumbnailService(directory: dir)
    let id = UUID()

    let small = try #require(await service.thumbnail(for: source, id: id, px: ThumbnailService.listSize))
    #expect((small.width, small.height) == (240, 135))
    let large = try #require(await service.thumbnail(for: source, id: id, px: ThumbnailService.bubbleSize))
    #expect((large.width, large.height) == (1200, 675))
    #expect(await service.writes == 2)
    #expect(FileManager.default.fileExists(atPath: await service.fileURL(id: id, px: 240).path))
    #expect(try ImageInspector.inspect(url: await service.fileURL(id: id, px: 1200)).mimeType == "image/jpeg")

    // A cache hit writes nothing.
    _ = await service.thumbnail(for: source, id: id, px: 240)
    #expect(await service.writes == 2)

    // A new service reads the file from disk instead of making it again.
    let fresh = ThumbnailService(directory: dir)
    let fromDisk = try #require(await fresh.thumbnail(for: source, id: id, px: 240))
    #expect((fromDisk.width, fromDisk.height) == (240, 135))
    #expect(await fresh.writes == 0)
  }

  @Test func keepsAspectAndOrientation() async throws {
    let root = TestFileRoot()
    let service = ThumbnailService(directory: root.directory("thumbs"))
    let image = try #require(await service.thumbnail(for: try FixtureLoader.url("Images/rotated_exif6.jpg"), id: UUID(), px: 240))
    #expect((image.width, image.height) == (180, 240))
    let tiny = try #require(await service.thumbnail(for: try FixtureLoader.url("Images/tiny_16x9.png"), id: UUID(), px: 240))
    #expect((tiny.width, tiny.height) == (32, 18))
  }

  @Test func unreadableImageGivesNil() async throws {
    let root = TestFileRoot()
    let bad = root.file("bad.png")
    try Data("nope".utf8).write(to: bad)
    let service = ThumbnailService(directory: root.directory("thumbs"))
    #expect(await service.thumbnail(for: bad, id: UUID(), px: 240) == nil)
    #expect(await service.writes == 0)
  }
}
