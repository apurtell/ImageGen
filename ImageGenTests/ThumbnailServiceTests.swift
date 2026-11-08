import CoreGraphics
import Foundation
import Synchronization
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

    // In-memory cache hits avoid redundant disk writes.
    _ = await service.thumbnail(for: source, id: id, px: 240)
    #expect(await service.writes == 2)

    // Subsequent service instances restore cached thumbnails from disk storage without regenerating bitmaps.
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

  @Test func cachedThumbnailNeverDecodes() async throws {
    let root = TestFileRoot()
    let source = root.file("Images/x.jpg")
    try ImageFactory.jpeg(width: 1600, height: 900).write(to: source)
    let service = ThumbnailService(directory: root.directory("thumbs"))
    let id = UUID()
    #expect(service.cachedThumbnail(id: id, px: 800) == nil)
    #expect(await service.writes == 0)
    _ = await service.thumbnail(for: source, id: id, px: 800)
    #expect(service.cachedThumbnail(id: id, px: 800) != nil)
    #expect(service.cachedThumbnail(id: id, px: 400) == nil)
  }

  @Test func cancelledRequestDecodesNothingButCacheHitsStillAnswer() async throws {
    let root = TestFileRoot()
    let source = root.file("Images/x.jpg")
    try ImageFactory.jpeg(width: 1600, height: 900).write(to: source)
    let service = ThumbnailService(directory: root.directory("thumbs"))
    let id = UUID()
    let cancelled = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return await service.thumbnail(for: source, id: id, px: 800)
    }
    #expect(await cancelled.value == nil)
    #expect(await service.writes == 0)
    _ = await service.thumbnail(for: source, id: id, px: 800)
    let hit = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return await service.thumbnail(for: source, id: id, px: 800)
    }
    #expect(await hit.value != nil)
  }

  /// Synchronization gate suspending the initial decode operation following invocation of close().
  private final class DecodeGate: Sendable {
    private let isClosed = Mutex(false)
    private let reached = DispatchSemaphore(value: 0)
    private let opened = DispatchSemaphore(value: 0)

    func close() { isClosed.withLock { $0 = true } }

    func pass() {
      let holds = isClosed.withLock { closed in
        defer { closed = false }
        return closed
      }
      guard holds else { return }
      reached.signal()
      opened.wait()
    }

    func waitUntilReached() async {
      await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
        DispatchQueue.global().async { [reached] in
          reached.wait()
          done.resume()
        }
      }
    }

    func open() { opened.signal() }
  }

  @Test func aLargeDecodeHoldsUpNeitherSmallOnesNorCacheHits() async throws {
    let root = TestFileRoot()
    let source = root.file("Images/x.jpg")
    try ImageFactory.jpeg(width: 1600, height: 900).write(to: source)
    let gate = DecodeGate()
    let timer = DecodeTimer(
      now: {
        gate.pass()
        return ContinuousClock.now
      }, report: { _, _ in })
    let service = ThumbnailService(directory: root.directory("thumbs"), decodeTimer: timer)
    let cached = UUID()
    _ = await service.thumbnail(for: source, id: cached, px: ThumbnailService.bubbleSize)

    gate.close()
    let large = Task { await service.thumbnail(for: source, id: UUID(), px: 1600) }
    await gate.waitUntilReached()

    #expect(service.cachedThumbnail(id: cached, px: ThumbnailService.bubbleSize) != nil)
    #expect(await service.thumbnail(for: source, id: cached, px: ThumbnailService.bubbleSize) != nil)
    let small = Task { await service.thumbnail(for: source, id: UUID(), px: ThumbnailService.listSize) }
    var answered = false
    for _ in 0..<100 where !answered {
      try await Task.sleep(for: .milliseconds(50))
      answered = await service.writes == 2
    }
    #expect(answered, "the small decode waited behind the large one")
    gate.open()
    #expect(await small.value != nil)
    #expect(await large.value != nil)
  }

  @Test func requestsForOneSizeAtOnceDecodeItOnce() async throws {
    let root = TestFileRoot()
    let source = root.file("Images/x.jpg")
    try ImageFactory.jpeg(width: 1600, height: 900).write(to: source)
    let service = ThumbnailService(directory: root.directory("thumbs"))
    let id = UUID()
    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<4 { group.addTask { _ = await service.thumbnail(for: source, id: id, px: 1500) } }
    }
    #expect(await service.writes == 1)
  }

  @Test func aSmallerDrawingUsesALargerSizeInMemory() async throws {
    let root = TestFileRoot()
    let source = root.file("Images/x.jpg")
    try ImageFactory.jpeg(width: 2752, height: 1536).write(to: source)
    let service = ThumbnailService(directory: root.directory("thumbs"))
    let id = UUID()
    #expect(service.cachedThumbnail(id: id, atLeast: 1800, originalLongEdge: 2752) == nil)
    _ = await service.thumbnail(for: source, id: id, px: 2752)
    #expect(service.cachedThumbnail(id: id, atLeast: 1800, originalLongEdge: 2752)?.px == 2752)
    #expect(service.cachedThumbnail(id: id, atLeast: 2752, originalLongEdge: 2752)?.px == 2752)
    _ = await service.thumbnail(for: source, id: id, px: 2400)
    #expect(service.cachedThumbnail(id: id, atLeast: 1800, originalLongEdge: 2752)?.px == 2400)
    // Verify cache hit satisfies request without triggering new rasterization or disk writes.
    #expect(await service.writes == 2)
    #expect(service.cachedThumbnail(id: UUID(), atLeast: 1800, originalLongEdge: 2752) == nil)
  }

  @Test func removingImagesTakesAllTheirSizes() async throws {
    let root = TestFileRoot()
    let source = root.file("Images/x.jpg")
    try ImageFactory.jpeg(width: 1600, height: 900).write(to: source)
    let service = ThumbnailService(directory: root.directory("thumbs"))
    let gone = UUID()
    let kept = UUID()
    // Arbitrary non-standard dimension representing arbitrary source asset long-edge bounds.
    for px in [240, 1200, 1427] { _ = await service.thumbnail(for: source, id: gone, px: px) }
    _ = await service.thumbnail(for: source, id: kept, px: 240)

    await service.remove(imageIDs: [gone])

    for px in [240, 1200, 1427] {
      #expect(!FileManager.default.fileExists(atPath: await service.fileURL(id: gone, px: px).path))
      #expect(service.cachedThumbnail(id: gone, px: px) == nil)
    }
    #expect(FileManager.default.fileExists(atPath: await service.fileURL(id: kept, px: 240).path))
    #expect(service.cachedThumbnail(id: kept, px: 240) != nil)
  }

  @Test func largeRequestIsNeverLargerThanTheOriginal() async throws {
    let root = TestFileRoot()
    let source = root.file("Images/x.jpg")
    try ImageFactory.jpeg(width: 1024, height: 576).write(to: source)
    let service = ThumbnailService(directory: root.directory("thumbs"))
    let px = ThumbnailService.displayPixels(displayed: CGSize(width: 1600, height: 900), scale: 2, originalLongEdge: 1024)
    let image = try #require(await service.thumbnail(for: source, id: UUID(), px: px))
    #expect((image.width, image.height) == (1024, 576))
  }
}

@Suite(.tags(.pure))
struct ThumbnailDisplayPixelsTests {
  private func pixels(_ width: CGFloat, _ height: CGFloat, scale: CGFloat = 2, original: Int = 8192) -> Int {
    ThumbnailService.displayPixels(displayed: CGSize(width: width, height: height), scale: scale, originalLongEdge: original)
  }

  @Test func smallDrawingsUseTheBubbleSize() {
    #expect(pixels(400, 225) == ThumbnailService.bubbleSize)
    #expect(pixels(600, 338) == ThumbnailService.bubbleSize)
    #expect(pixels(1200, 675, scale: 1) == ThumbnailService.bubbleSize)
    #expect(pixels(0, 0) == ThumbnailService.bubbleSize)
  }

  @Test func eachBucketCoversWhatsBelowIt() {
    #expect(pixels(601, 300) == 1800)
    #expect(pixels(900, 500) == 1800)
    #expect(pixels(901, 500) == 2400)
    #expect(pixels(1200, 600) == 2400)
    #expect(pixels(1201, 600) == 3200)
    #expect(pixels(1600, 900) == 3200)
    #expect(pixels(1601, 900) == 4096)
    #expect(pixels(2048, 1000) == 4096)
  }

  @Test func biggestBucketIsTheLimit() {
    #expect(pixels(4000, 2000) == 4096)
  }

  @Test func scaleCounts() {
    #expect(pixels(1600, 900, scale: 1) == 1800)
    #expect(pixels(1600, 900, scale: 2) == 3200)
    #expect(pixels(1600, 900, scale: 3) == 4096)
  }

  @Test func longEdgeDecidesWhicheverWayUpTheImageIs() {
    #expect(pixels(500, 1000) == 2400)
    #expect(pixels(1000, 500) == 2400)
  }

  @Test func neverMoreThanTheOriginal() {
    #expect(pixels(1600, 900, original: 2752) == 2752)
    #expect(pixels(4000, 2000, original: 4000) == 4000)
    #expect(pixels(800, 450, original: 1500) == 1500)
  }

  @Test func originalBelowTheBubbleSizeStaysAtTheSizeItAlreadyHas() {
    #expect(pixels(1600, 900, original: 1024) == ThumbnailService.bubbleSize)
    #expect(pixels(1600, 900, original: 0) == ThumbnailService.bubbleSize)
  }

  @Test func staysPutWithinABucket() {
    let sizes = stride(from: CGFloat(901), through: 1200, by: 25).map { pixels($0, $0 * 0.5) }
    #expect(Set(sizes) == [2400])
  }
}
