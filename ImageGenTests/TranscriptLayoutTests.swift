import CoreGraphics
import Testing

@testable import ImageGen

@Suite(.tags(.pure))
struct TranscriptLayoutTests {
  /// Computes image render dimensions for a given aspect ratio within specified viewport constraints.
  private func imageSize(aspect: CGFloat, _ width: CGFloat, _ height: CGFloat, gutter: CGFloat = 0) -> CGSize {
    let w = TranscriptLayout.imageWidth(aspect: aspect, viewport: CGSize(width: width, height: height), gutter: gutter)
    return CGSize(width: w, height: w / aspect)
  }

  @Test func columnGrowsWithTheWindowUpToItsLimit() {
    #expect(TranscriptLayout.columnWidth(viewportWidth: 580) == 580)
    #expect(TranscriptLayout.columnWidth(viewportWidth: 1400) == 1400)
    #expect(TranscriptLayout.columnWidth(viewportWidth: 1632) == 1632)
    #expect(TranscriptLayout.columnWidth(viewportWidth: 5000) == 1632)
  }

  @Test func gutterIsReservedOnBothSidesAndKeepsTheColumnCentred() {
    #expect(TranscriptLayout.columnWidth(viewportWidth: 780, gutter: 17) == 746)
    #expect(TranscriptLayout.columnOrigin(viewportWidth: 780, gutter: 17) == 17)
    let width: CGFloat = 780
    for gutter: CGFloat in [0, 15, 17] {
      let origin = TranscriptLayout.columnOrigin(viewportWidth: width, gutter: gutter)
      let column = TranscriptLayout.columnWidth(viewportWidth: width, gutter: gutter)
      #expect(origin + column / 2 == width / 2)
    }
    #expect(TranscriptLayout.columnOrigin(viewportWidth: 3000) == 684)
  }

  @Test func columnNeverGoesNegative() {
    #expect(TranscriptLayout.columnWidth(viewportWidth: 10, gutter: 17) == 0)
    #expect(TranscriptLayout.imageWidth(aspect: 1, viewport: CGSize(width: 10, height: 500)) == 0)
  }

  @Test func wideImageFillsTheColumn() {
    let size = imageSize(aspect: 16.0 / 9.0, 1100, 1000)
    #expect(size.width == 1100 - 2 * TranscriptLayout.sideMargin)
  }

  @Test func imageWidthStopsAtTheColumnLimit() {
    #expect(TranscriptLayout.imageWidth(aspect: 3, viewport: CGSize(width: 4000, height: 2000)) == TranscriptLayout.maxContentWidth)
  }

  @Test func heightCapPreservesTheAspect() {
    let size = imageSize(aspect: 1, 2000, 1250)
    #expect(size.height == 1000)
    #expect(size.width == 1000)
    let tall = imageSize(aspect: 0.5, 2000, 1250)
    #expect(tall.height == 1000)
    #expect(tall.width == 500)
  }

  @Test func fullDisplayIsMuchLargerThanTheOldCap() {
    // Verifies expanded viewport scaling extends beyond legacy 640 pt constraints.
    #expect(imageSize(aspect: 1, 1700, 1100).height == 880)
    #expect(imageSize(aspect: 16.0 / 9.0, 1700, 1100).width > 1500)
  }

  @Test func shortWindowLeavesRoomForTheComposer() {
    // Minimum window baseline: reserves composer clearance within constrained vertical bounds.
    let height = TranscriptLayout.maxImageHeight(transcriptHeight: 508)
    #expect(height == 508 - TranscriptLayout.composerReserve)
    #expect(height + 147 <= 508)
    #expect(TranscriptLayout.maxImageHeight(transcriptHeight: 1250) == 1000)
  }

  @Test func heightLimitHasAFloor() {
    #expect(TranscriptLayout.maxImageHeight(transcriptHeight: 200) == TranscriptLayout.minimumImageHeight)
  }

  @Test func veryTallImageKeepsAMinimumWidthUnlessTheColumnIsNarrower() {
    #expect(TranscriptLayout.imageWidth(aspect: 0.125, viewport: CGSize(width: 800, height: 700)) == TranscriptLayout.minimumImageWidth)
    #expect(TranscriptLayout.imageWidth(aspect: 0.125, viewport: CGSize(width: 150, height: 700)) == 150 - 2 * TranscriptLayout.sideMargin)
  }

  @Test func imageDoesNotDependOnAGutterItFitsInside() {
    let plain = TranscriptLayout.imageWidth(aspect: 1, viewport: CGSize(width: 1400, height: 800))
    let barred = TranscriptLayout.imageWidth(aspect: 1, viewport: CGSize(width: 1400, height: 800), gutter: 17)
    #expect(plain == barred)
  }

  @Test func unmeasuredHasASensibleLimit() {
    #expect(TranscriptLayout.imageWidth(aspect: 1, viewport: nil) == 640)
    #expect(TranscriptLayout.imageWidth(aspect: 0.5, viewport: nil) == 320)
    #expect(TranscriptLayout.imageWidth(aspect: 2, viewport: nil) == 640)
  }

  @Test func degenerateAspectStaysPositive() {
    #expect(TranscriptLayout.imageWidth(aspect: 0, viewport: CGSize(width: 800, height: 700)) > 0)
  }

  @Test func geminiShapesAreCloseToTheirNames() {
    for ratio in AspectRatio.allCases {
      let pixels = ratio.oneKPixels
      let aspect = Double(pixels.width) / Double(pixels.height)
      #expect(abs(aspect / ratio.ratio - 1) < 0.03, "\(ratio.rawValue)")
    }
  }

  @Test func settlingStopsForAnyScrollByTheUser() {
    let quiet = TranscriptSettling.wheelQuietPeriod + 1
    #expect(!TranscriptSettling.shouldStop(userScrolled: false, isUserScrolling: false, sinceLastWheel: quiet))
    #expect(TranscriptSettling.shouldStop(userScrolled: true, isUserScrolling: false, sinceLastWheel: quiet))
    #expect(TranscriptSettling.shouldStop(userScrolled: false, isUserScrolling: true, sinceLastWheel: quiet))
    #expect(TranscriptSettling.shouldStop(userScrolled: false, isUserScrolling: false, sinceLastWheel: 0.1))
  }

  @Test func settlingScrollsOnlyWhenTheBottomIsOutOfPlace() {
    #expect(!TranscriptSettling.needsScroll(distanceFromBottom: 0))
    #expect(!TranscriptSettling.needsScroll(distanceFromBottom: 0.92))
    #expect(TranscriptSettling.needsScroll(distanceFromBottom: 12))
    // Content height smaller than viewport requires no scroll adjustments.
    #expect(!TranscriptSettling.needsScroll(distanceFromBottom: -49))
  }
}
