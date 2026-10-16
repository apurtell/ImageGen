import Foundation
import Testing

@testable import ImageGen

@Suite
struct BudgetPlannerTests {
  /// Bytes whose base64 is exactly `mb` million bytes.
  static func bytes(base64MB mb: Double) -> Int { Int(mb * 1_000_000) / 4 * 3 }

  @Test(.tags(.pure)) func fitsWithoutShrink() {
    let inputs = [PreparedSize(byteCount: Self.bytes(base64MB: 6), longEdge: 2048), PreparedSize(byteCount: Self.bytes(base64MB: 6), longEdge: 2048)]
    #expect(BudgetPlanner.plan(inputs: inputs, envelopeBytes: 1000) == .fits(bodyBytes: 12_001_000))
  }

  @Test(.tags(.pure)) func shrinksLargestFirst() {
    let inputs = [
      PreparedSize(byteCount: Self.bytes(base64MB: 5), longEdge: 4096),
      PreparedSize(byteCount: Self.bytes(base64MB: 9), longEdge: 3072),
      PreparedSize(byteCount: Self.bytes(base64MB: 7), longEdge: 4096),
    ]
    guard case .shrink(let index, let edge, let body) = BudgetPlanner.plan(inputs: inputs, envelopeBytes: 0) else {
      Issue.record("expected a shrink")
      return
    }
    #expect(index == 1)
    #expect(edge == 2304)
    #expect(body == 21_000_000)
  }

  @Test(.tags(.pure)) func failsBelow1024() {
    let inputs = [PreparedSize(byteCount: Self.bytes(base64MB: 10), longEdge: 1024), PreparedSize(byteCount: Self.bytes(base64MB: 10), longEdge: 900)]
    #expect(BudgetPlanner.plan(inputs: inputs, envelopeBytes: 0) == .cannotFit(bodyBytes: 20_000_000))
    // A shrink never goes below 1024.
    let near = [PreparedSize(byteCount: Self.bytes(base64MB: 20), longEdge: 1200)]
    #expect(BudgetPlanner.plan(inputs: near, envelopeBytes: 0) == .shrink(index: 0, toLongEdge: 1024, bodyBytes: 20_000_000))
  }

  static func fake(_ mb: Double, edge: Int) -> PreparedImage {
    PreparedImage(
      url: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).jpg"), mimeType: "image/jpeg", byteCount: bytes(base64MB: mb),
      pixelWidth: edge, pixelHeight: edge * 3 / 4, longEdgeSetting: 4096)
  }

  /// Shrinking scales the bytes with the pixel count.
  static let fakeShrink: @Sendable (PreparedImage, Int) async throws -> PreparedImage = { image, edge in
    let scale = Double(edge) / Double(image.pixelWidth)
    return PreparedImage(
      url: image.url, mimeType: "image/jpeg", byteCount: Int(Double(image.byteCount) * scale * scale), pixelWidth: edge,
      pixelHeight: edge * 3 / 4, longEdgeSetting: image.longEdgeSetting)
  }

  @Test(.tags(.pure)) func repeatsUntilFits() async throws {
    let images = [Self.fake(16, edge: 4096), Self.fake(14, edge: 4096)]
    let fitted = try await BudgetPlanner.fit(images, envelopeBytes: 2000, shrink: Self.fakeShrink)
    #expect(fitted.bodyBytes <= BudgetPlanner.budget)
    // 30 MB: the 16 MB image shrinks first, then the 14 MB one is the largest.
    #expect(fitted.shrinks == [
      BudgetPlanner.Shrink(index: 0, fromLongEdge: 4096, toLongEdge: 3072),
      BudgetPlanner.Shrink(index: 1, fromLongEdge: 4096, toLongEdge: 3072),
    ])
    #expect(fitted.images.allSatisfy { $0.pixelWidth >= 1024 })
  }

  @Test(.tags(.pure)) func driverThrowsWhenItCannotFit() async throws {
    let images = [Self.fake(25, edge: 1024)]
    await #expect(throws: BudgetTooLarge(bodyBytes: 25_000_000 + 10)) {
      _ = try await BudgetPlanner.fit(images, envelopeBytes: 10, shrink: Self.fakeShrink)
    }
    #expect(BudgetTooLarge(bodyBytes: 25_000_000).localizedDescription.hasPrefix("Images too large to send together (25.0 MB)."))
  }

  @Test(.tags(.pure)) func driverChecksCancellation() async throws {
    let task = Task {
      try await BudgetPlanner.fit([Self.fake(30, edge: 4096)], envelopeBytes: 0) { image, edge in
        try await Task.sleep(for: .seconds(10))
        return try await Self.fakeShrink(image, edge)
      }
    }
    task.cancel()
    await #expect(throws: CancellationError.self) { _ = try await task.value }
  }

  @Test(.tags(.io)) func alphaFlattenedOnShrink() async throws {
    let root = TestFileRoot()
    let source = root.file("alpha.png")
    try ImageFactory.encode(ImagePreprocessorTests.transparentWithSquare(width: 2048, height: 1536), type: .png).write(to: source)
    let prepared = try await ImagePreprocessor.prepare(source: source, maxLongEdge: 2048, destinationDir: root.directory("prepared"), id: UUID())
    #expect(prepared.mimeType == "image/png")
    let shrunk = try await BudgetPlanner.shrinkWithPreprocessor(prepared, 1536)
    #expect(shrunk.mimeType == "image/jpeg")
    #expect(shrunk.url.pathExtension == "jpg")
    #expect((shrunk.pixelWidth, shrunk.pixelHeight) == (1536, 1152))
    #expect(!(try ImageInspector.inspect(url: shrunk.url)).hasAlpha)
    #expect(shrunk.url.lastPathComponent == prepared.url.lastPathComponent.replacingOccurrences(of: "-2048.png", with: "-1536.jpg"))
    #expect(shrunk.longEdgeSetting == 2048)
  }
}
