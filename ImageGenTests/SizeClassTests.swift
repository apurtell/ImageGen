import Foundation
import Testing

@testable import ImageGen

@Suite(.tags(.pure))
struct SizeClassTests {
  @Test func flash16x9_2K_2752x1536_honored() {
    #expect(SizeClass.isSizeHonored(requested: .s2K, width: 2752, height: 1536))
    #expect(SizeClass.isAspectHonored(requested: .r16x9, width: 2752, height: 1536))
    #expect(SizeClass.classify(width: 2752, height: 1536) == .s2K)
  }

  @Test func oneK1x8_384x3072_honored() {
    // Total pixel count determines size classification: 1.18 MP resolves to 1K despite an elongated 3072 px dimension.
    #expect(SizeClass.isSizeHonored(requested: .s1K, width: 384, height: 3072))
    #expect(SizeClass.classify(width: 384, height: 3072) == .s1K)
    #expect(SizeClass.isAspectHonored(requested: .r1x8, width: 384, height: 3072))
  }

  @Test func returned1KFor2KFlagged() {
    #expect(!SizeClass.isSizeHonored(requested: .s2K, width: 1376, height: 768))
    #expect(SizeClass.classify(width: 1376, height: 768) == .s1K)
  }

  @Test func aspect1x1For16x9Flagged() {
    #expect(!SizeClass.isAspectHonored(requested: .r16x9, width: 2048, height: 2048))
    #expect(SizeClass.nearestAspect(width: 2048, height: 2048) == .r1x1)
  }

  @Test(arguments: [
    (5504, 3072, ImageSize.s4K), (1024, 1024, .s1K), (792, 336, .s512), (2752, 1536, .s2K), (3072, 5504, .s4K),
  ])
  func classifiesMockSizes(width: Int, height: Int, size: ImageSize) {
    #expect(SizeClass.classify(width: width, height: height) == size)
    #expect(SizeClass.isSizeHonored(requested: size, width: width, height: height))
  }

  @Test func aspectToleranceIsThreePercent() {
    #expect(SizeClass.isAspectHonored(requested: .r16x9, width: 1376, height: 768))  // 1.792 vs 1.778 within tolerance limit.
    #expect(SizeClass.isAspectHonored(requested: .r21x9, width: 1584, height: 672))
    #expect(!SizeClass.isAspectHonored(requested: .r16x9, width: 1600, height: 1000))
    #expect(SizeClass.nearestAspect(width: 1584, height: 672) == .r21x9)
    #expect(!SizeClass.isSizeHonored(requested: .s1K, width: 0, height: 0))
  }
}
