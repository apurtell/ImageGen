import CoreGraphics
import Testing

@testable import ImageGen

@Suite(.tags(.pure))
struct TranscriptLayoutTests {
  /// Computes resulting image height when scaled to maximum constrained width.
  private func height(aspect: CGFloat, transcriptHeight: CGFloat?) -> CGFloat {
    ReplyImageCap.maxWidth(aspect: aspect, transcriptHeight: transcriptHeight) / aspect
  }

  @Test func squareImageFitsInTheTranscriptAtAnOrdinaryWindowSize() {
    // Standard desktop window dimensions with available vertical transcript space.
    #expect(height(aspect: 1, transcriptHeight: 708) == 425)
    #expect(height(aspect: 1, transcriptHeight: 708) < 708 - 180)
  }

  @Test func tallImageIsLimitedByHeightAndNarrower() {
    #expect(height(aspect: 0.5, transcriptHeight: 708) == 425)
    #expect(ReplyImageCap.maxWidth(aspect: 0.5, transcriptHeight: 708) == 212.5)
  }

  @Test func wideImageKeepsTheWidthCapWhenItsHeightFits() {
    #expect(ReplyImageCap.maxWidth(aspect: 16.0 / 9.0, transcriptHeight: 708) == 640)
    #expect(ReplyImageCap.maxWidth(aspect: 3, transcriptHeight: 708) == 640)
  }

  @Test func wideImageShrinksWhenItsHeightWouldNotFit() {
    // Constrained transcript height.
    let width = ReplyImageCap.maxWidth(aspect: 2, transcriptHeight: 400)
    #expect(width == 480)
  }

  @Test func aTallWindowNeverGoesPastTheFixedCap() {
    #expect(ReplyImageCap.maxWidth(aspect: 1, transcriptHeight: 3000) == ReplyImageCap.maxEdge)
    #expect(height(aspect: 0.5, transcriptHeight: 3000) == ReplyImageCap.maxEdge)
  }

  @Test func anUnmeasuredTranscriptUsesTheFixedCap() {
    #expect(ReplyImageCap.maxWidth(aspect: 1, transcriptHeight: nil) == ReplyImageCap.maxEdge)
    #expect(ReplyImageCap.maxWidth(aspect: 0.5, transcriptHeight: nil) == ReplyImageCap.maxEdge / 2)
  }

  @Test func aDegenerateAspectStaysPositive() {
    #expect(ReplyImageCap.maxWidth(aspect: 0, transcriptHeight: 700) > 0)
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
