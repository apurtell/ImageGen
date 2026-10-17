import Foundation
import Testing
import UIKit

@testable import ImageGen

/// Verifies serialized full resolution image decoding and single item cache retention for viewer operations.
@Suite(.tags(.io))
struct FullDecoderTests {
  func jpeg(_ root: TestFileRoot) throws -> URL {
    let url = root.file("full.jpg")
    try ImagePreprocessor.write(ImageFactory.cgImage(width: 1600, height: 900, seed: 3), to: url, type: .jpeg, quality: 0.8)
    return url
  }

  @Test func keepsTheLastImageForTheRebuildAfterARotation() async throws {
    let root = TestFileRoot()
    let url = try jpeg(root)
    let decoder = FullDecoder()
    let id = UUID()
    let first = try #require(await decoder.decode(url: url, id: id))
    let again = try #require(await decoder.decode(url: url, id: id))
    #expect(first === again)
    await decoder.clear()
    let afterClear = try #require(await decoder.decode(url: url, id: id))
    #expect(afterClear !== first)
  }

  @Test func skipsARequestWithdrawnWhileItWaited() async throws {
    let root = TestFileRoot()
    let url = try jpeg(root)
    let decoder = FullDecoder()
    // Simulates task cancellation triggered when the user scrolls away prior to decode scheduling.
    let result = await Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return await decoder.decode(url: url, id: UUID())
    }.value
    #expect(result == nil)
  }
}
