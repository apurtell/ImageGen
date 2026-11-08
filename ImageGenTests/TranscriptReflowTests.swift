import CoreGraphics
import Foundation
import Testing

@testable import ImageGen

@Suite(.tags(.pure))
struct TranscriptReflowTests {
  private let a = UUID()
  private let b = UUID()
  private let c = UUID()

  private func metrics(offset: CGFloat, distance: CGFloat = 500, container: CGFloat = 600) -> TranscriptScrollMetrics {
    TranscriptScrollMetrics(
      offset: offset, topInset: 50, distanceFromBottom: distance, containerSize: CGSize(width: 800, height: container))
  }

  private func frame(_ y: CGFloat, _ height: CGFloat, width: CGFloat = 700) -> CGRect {
    CGRect(x: 16, y: y, width: width, height: height)
  }

  /// Constructs a test reflow state populated with three 400 pt rows at a specified initial scroll offset.
  private func reading(offset: CGFloat) -> TranscriptReflowState {
    var state = TranscriptReflowState()
    state.update(rowID: a, frame: frame(0, 400))
    state.update(rowID: b, frame: frame(400, 400))
    state.update(rowID: c, frame: frame(800, 400))
    _ = state.update(metrics: metrics(offset: offset), isFollowingTail: false)
    state.capturePlace()
    return state
  }

  @Test func placeIsTheFirstRowInView() {
    let rows = [a: frame(0, 400), b: frame(400, 400), c: frame(800, 400)]
    #expect(TranscriptPlace.first(in: rows, visibleTop: 500) == TranscriptPlace(rowID: b, offsetIntoRow: 100, rowHeight: 400))
    #expect(TranscriptPlace.first(in: rows, visibleTop: 0)?.rowID == a)
    #expect(TranscriptPlace.first(in: rows, visibleTop: 399.8)?.rowID == b)
    #expect(TranscriptPlace.first(in: rows, visibleTop: 2000) == nil)
  }

  @Test func placeBelowTheTopKeepsItsGap() {
    let place = TranscriptPlace.first(in: [b: frame(400, 400)], visibleTop: 390)
    #expect(place == TranscriptPlace(rowID: b, offsetIntoRow: -10, rowHeight: 400))
    #expect(place?.visibleTop(rowFrame: frame(900, 200)) == 890)
  }

  @Test func placeKeepsItsShareOfARowThatChangesHeight() {
    let place = TranscriptPlace(rowID: b, offsetIntoRow: 100, rowHeight: 400)
    #expect(place.visibleTop(rowFrame: frame(1000, 800)) == 1200)
  }

  @Test func shrinkingAtTheBottomStaysAtTheBottom() {
    var state = TranscriptReflowState()
    _ = state.update(metrics: metrics(offset: 800, distance: 0), isFollowingTail: true)
    // Viewport height reduction places trailing boundary outside the visible bounds.
    let atBottom = state.update(metrics: metrics(offset: 800, distance: 120, container: 480), isFollowingTail: true)
    #expect(atBottom == nil)
    #expect(state.episodeFollowsTail == true)
    #expect(state.correction == .infinity)
    #expect(state.endEpisode() == true)
  }

  @Test func followStateIsTheOneFromBeforeTheChange() {
    var state = TranscriptReflowState()
    _ = state.update(metrics: metrics(offset: 800, distance: 0), isFollowingTail: true)
    state.beginEpisode(isFollowingTail: true)
    // Subsequent reports during an active episode do not alter the established trailing anchoring mode.
    state.beginEpisode(isFollowingTail: false)
    #expect(state.episodeFollowsTail == true)
  }

  @Test func middleKeepsTheFirstRowThroughAResize() {
    var state = reading(offset: 450)
    #expect(state.place == TranscriptPlace(rowID: b, offsetIntoRow: 100, rowHeight: 400))
    _ = state.update(metrics: metrics(offset: 450, container: 800), isFollowingTail: false)
    #expect(state.isInEpisode)
    // Row dimensions expand, shifting preceding layout frames.
    state.update(rowID: a, frame: frame(0, 600))
    state.update(rowID: b, frame: frame(600, 600))
    // Preserved anchor offset maintains proportional position (25%) within the resized row frame.
    #expect(state.correction == 750)
    _ = state.update(metrics: metrics(offset: 700, container: 800), isFollowingTail: false)
    #expect(state.correction == nil)
    #expect(state.endEpisode() == false)
    #expect(!state.placeIsOutOfReach)
  }

  @Test func correctionIsNotAskedForOutsideAnEpisode() {
    var state = reading(offset: 450)
    state.update(rowID: a, frame: frame(0, 600))
    #expect(state.correction == nil)
  }

  @Test func geometryIsBelievedAgainAfterTheEpisode() {
    var state = reading(offset: 450)
    state.beginEpisode(isFollowingTail: false)
    #expect(state.update(metrics: metrics(offset: 450, distance: 10), isFollowingTail: false) == nil)
    _ = state.endEpisode()
    #expect(state.update(metrics: metrics(offset: 470, distance: 10), isFollowingTail: false) == true)
    #expect(state.update(metrics: metrics(offset: 300, distance: 200), isFollowingTail: false) == false)
  }

  @Test func aReaderAShrinkLeavesNearTheBottomKeepsThePlace() {
    var state = reading(offset: 450)
    // Viewport contraction around an anchored row brings the trailing edge within bottom threshold.
    state.beginEpisode(isFollowingTail: false)
    _ = state.update(metrics: metrics(offset: 450, distance: 40, container: 480), isFollowingTail: false)
    #expect(state.endEpisode() == false)
    // Stationary scroll position updates preserve the existing row anchor policy.
    #expect(state.update(metrics: metrics(offset: 450, distance: 39, container: 480), isFollowingTail: false) == false)
    // Subsequent resize episode maintains preserved row anchor despite trailing-follow flag.
    state.beginEpisode(isFollowingTail: true)
    #expect(state.episodeFollowsTail == false)
    _ = state.update(metrics: metrics(offset: 450, distance: 300, container: 700), isFollowingTail: true)
    #expect(state.endEpisode() == false)
    // Explicit user navigation to the trailing boundary re-engages trailing edge tracking.
    #expect(state.update(metrics: metrics(offset: 700, distance: 0, container: 700), isFollowingTail: false) == true)
    state.beginEpisode(isFollowingTail: true)
    #expect(state.episodeFollowsTail == true)
  }

  @Test func aScrollThatMovesNothingStillReleasesAPlaceNearTheBottom() {
    var state = reading(offset: 450)
    state.beginEpisode(isFollowingTail: false)
    _ = state.update(metrics: metrics(offset: 450, distance: 0, container: 480), isFollowingTail: false)
    #expect(state.endEpisode() == false)
    // When stationary boundary scrolls elide layout reports, direct position movement commits trailing alignment.
    #expect(state.positionWasMoved() == true)
    #expect(state.positionWasMoved() == nil)
  }

  @Test func aReaderAtTheBottomGoesOnFollowingAfterAResize() {
    var state = TranscriptReflowState()
    _ = state.update(metrics: metrics(offset: 800, distance: 0), isFollowingTail: true)
    state.beginEpisode(isFollowingTail: true)
    #expect(state.endEpisode() == true)
    #expect(state.update(metrics: metrics(offset: 800, distance: 0), isFollowingTail: true) == true)
    state.beginEpisode(isFollowingTail: true)
    #expect(state.episodeFollowsTail == true)
  }

  @Test func placeIsNotCapturedDuringAnEpisode() {
    var state = reading(offset: 450)
    state.beginEpisode(isFollowingTail: false)
    _ = state.update(metrics: metrics(offset: 900), isFollowingTail: false)
    state.capturePlace()
    #expect(state.place?.rowID == b)
  }

  @Test func placeOutOfReachIsKeptSoGrowingAndShrinkingBackReturnsToIt() {
    var state = reading(offset: 450)
    // Container expansion limits scroll extent before the target row anchor reaches the top edge.
    state.beginEpisode(isFollowingTail: false)
    _ = state.update(metrics: metrics(offset: 200, distance: 0, container: 1000), isFollowingTail: false)
    #expect(state.correction != nil)
    // Edge clamping does not overwrite the preserved anchor reference.
    #expect(state.endEpisode() == false)
    #expect(state.placeIsOutOfReach)
    state.capturePlace()
    #expect(state.place?.rowID == b)
    // Viewport contraction restores preserved anchor offset rather than trailing edge.
    state.beginEpisode(isFollowingTail: true)
    #expect(state.episodeFollowsTail == false)
    _ = state.update(metrics: metrics(offset: 200, container: 600), isFollowingTail: false)
    #expect(state.correction == 500)
  }

  @Test func movingThePositionReleasesAPlaceOutOfReach() {
    var state = reading(offset: 450)
    state.beginEpisode(isFollowingTail: false)
    _ = state.update(metrics: metrics(offset: 200, distance: 0, container: 1000), isFollowingTail: false)
    _ = state.endEpisode()
    #expect(state.placeIsOutOfReach)
    _ = state.update(metrics: metrics(offset: 100, distance: 100, container: 1000), isFollowingTail: false)
    state.capturePlace()
    #expect(!state.placeIsOutOfReach)
    #expect(state.place?.rowID == a)
  }

  @Test func aNewReplyReleasesAPlaceOutOfReachWithoutMovingAnything() {
    var state = reading(offset: 450)
    state.beginEpisode(isFollowingTail: false)
    _ = state.update(metrics: metrics(offset: 200, distance: -100, container: 1000), isFollowingTail: false)
    _ = state.endEpisode()
    #expect(state.placeIsOutOfReach)
    // Appended content fitting within the container maintains trailing edge tracking.
    #expect(state.positionWasMoved() == true)
    #expect(!state.placeIsOutOfReach)
    _ = state.update(metrics: metrics(offset: 200, distance: -50, container: 1000), isFollowingTail: false)
    state.beginEpisode(isFollowingTail: true)
    #expect(state.episodeFollowsTail == true)
  }

  @Test func restoringAPlaceAsksForItOnceItsRowHasAFrame() {
    var state = TranscriptReflowState()
    _ = state.update(metrics: metrics(offset: 900, distance: 0), isFollowingTail: true)
    state.restore(TranscriptPlace(rowID: b, offsetIntoRow: 100, rowHeight: 400))
    #expect(state.episodeFollowsTail == false)
    #expect(state.correction == nil)
    state.update(rowID: b, frame: frame(400, 400))
    #expect(state.correction == 500)
  }

  @Test func userScrollEndsTheEpisode() {
    var state = reading(offset: 450)
    state.beginEpisode(isFollowingTail: false)
    state.update(rowID: b, frame: frame(700, 400))
    #expect(state.correction != nil)
    #expect(state.cancelEpisode() == false)
    #expect(!state.isInEpisode)
    #expect(state.correction == nil)
    #expect(state.place?.rowID == a || state.place?.rowID == b)
  }

  @Test func aQuietRowAboveEveryChangeIsStillShown() {
    // Vertical viewport resizing affects trailing element heights without altering preceding row geometry.
    var state = reading(offset: 450)
    state.beginEpisode(isFollowingTail: false)
    state.update(rowID: c, frame: frame(800, 300))
    _ = state.update(metrics: metrics(offset: 450, container: 500), isFollowingTail: false)
    _ = state.endEpisode()
    state.capturePlace()
    #expect(state.place == TranscriptPlace(rowID: b, offsetIntoRow: 100, rowHeight: 400))
  }

  @Test func theReadersShareSurvivesAWidthChangeAfterAHeightOnlyResize() {
    var state = reading(offset: 450)
    state.beginEpisode(isFollowingTail: false)
    state.update(rowID: c, frame: frame(800, 300))
    _ = state.update(metrics: metrics(offset: 450, container: 500), isFollowingTail: false)
    _ = state.endEpisode()
    state.capturePlace()
    // Container width expansion doubles row height, preserving proportional vertical anchor ratio.
    state.beginEpisode(isFollowingTail: false)
    state.update(rowID: a, frame: frame(0, 400, width: 900))
    state.update(rowID: b, frame: frame(400, 800, width: 900))
    state.update(rowID: c, frame: frame(1200, 300, width: 900))
    #expect(state.correction == 600)
  }

  @Test func aRowAboveGrowingDuringARetryLeavesTheViewStill() {
    var state = reading(offset: 450)
    state.beginEpisode(isFollowingTail: false)
    state.update(rowID: a, frame: frame(0, 410))
    state.update(rowID: b, frame: frame(410, 400))
    #expect(state.correction == 510)
  }

  @Test func aRetriedRowWithItsTopAboveTheViewGrowsDownward() {
    // Regeneration placeholder replacement expands row height from initial state.
    var state = TranscriptReflowState()
    state.update(rowID: a, frame: frame(0, 400))
    state.update(rowID: b, frame: frame(400, 70))
    state.update(rowID: c, frame: frame(470, 400))
    _ = state.update(metrics: metrics(offset: 390), isFollowingTail: false)
    state.capturePlace()
    #expect(state.place == TranscriptPlace(rowID: b, offsetIntoRow: 40, rowHeight: 70))
    state.holdPlaceForRetry()
    state.update(rowID: b, frame: frame(400, 778))
    state.update(rowID: c, frame: frame(1178, 400))
    // Top-aligned anchor preservation keeps preceding content stationary during downward row growth.
    #expect(state.correction == nil)
    // Post-quiescence anchor converts back to proportional height ratio.
    _ = state.endEpisode()
    state.capturePlace()
    #expect(state.place == TranscriptPlace(rowID: b, offsetIntoRow: 40, rowHeight: 778))
    state.beginEpisode(isFollowingTail: false)
    state.update(rowID: b, frame: frame(400, 1556))
    #expect(state.correction == 480)
  }

  @Test func aRetriedRowThatShrinksKeepsTheRowsAboveItStill() {
    var state = reading(offset: 650)
    #expect(state.place == TranscriptPlace(rowID: b, offsetIntoRow: 300, rowHeight: 400))
    state.holdPlaceForRetry()
    state.update(rowID: b, frame: frame(400, 70))
    state.update(rowID: c, frame: frame(470, 400))
    #expect(state.correction == nil)
  }

  @Test func aRetryAboveTheViewFollowsThePlaceDown() {
    var state = reading(offset: 450)
    state.holdPlaceForRetry()
    state.update(rowID: a, frame: frame(0, 1100))
    state.update(rowID: b, frame: frame(1100, 400))
    #expect(state.correction == 1200)
  }

  @Test func aSizeCycleComesBackToThePlace() {
    // Eager layout reporting propagates row dimensions; anchor resolves relative to row geometry.
    var state = reading(offset: 450)
    let place = state.place
    for (scale, width) in [(0.6, 480.0), (1.7, 1180.0), (2.3, 1600.0), (1.0, 700.0)] {
      state.beginEpisode(isFollowingTail: false)
      state.update(rowID: a, frame: frame(0, 400 * scale, width: width))
      state.update(rowID: b, frame: frame(400 * scale, 400 * scale, width: width))
      state.update(rowID: c, frame: frame(800 * scale, 400 * scale, width: width))
      let wanted = state.correction ?? state.metrics?.visibleTop ?? 0
      #expect(abs(wanted - 500 * scale) < 0.001)
      _ = state.update(metrics: metrics(offset: wanted - 50), isFollowingTail: false)
      _ = state.endEpisode()
      state.capturePlace()
      #expect(state.place?.rowID == place?.rowID)
      #expect(abs((state.place?.offsetIntoRow ?? 0) / 400 / scale - (place?.offsetIntoRow ?? 1) / 400) < 0.001)
    }
  }

  @Test func aRowThatHasLeftTheTranscriptCantBeThePlace() {
    var state = reading(offset: 450)
    state.keepRows([a, c])
    #expect(state.rows[b] == nil)
    state.capturePlace()
    #expect(state.place?.rowID == c)
  }

  @Test func rowsNearTheVisibleAreaHoldTheirImages() {
    var state = TranscriptReflowState()
    _ = state.update(metrics: metrics(offset: 2000), isFollowingTail: false)
    let margin = TranscriptReflowState.presenceMargin
    // Target viewport spans y=2050 through y=2650 (height 600).
    #expect(state.isNear(frame(2100, 100)))
    #expect(state.isNear(frame(2050 - margin - 100, 200)))
    #expect(!state.isNear(frame(2050 - margin - 200, 100)))
    #expect(state.isNear(frame(2650 + margin - 100, 200)))
    #expect(!state.isNear(frame(2650 + margin + 100, 100)))
  }

  @Test func rowsAreNotNearBeforeThereAreMetrics() {
    #expect(!TranscriptReflowState().isNear(frame(0, 100)))
  }
}

/// Verifies `TranscriptReflow` synchronization directly against underlying scroll view geometry.
@Suite(.tags(.pure))
@MainActor
struct TranscriptReflowLiveTests {
  private let row = UUID()

  private func metrics(offset: CGFloat, distance: CGFloat) -> TranscriptScrollMetrics {
    TranscriptScrollMetrics(offset: offset, topInset: 0, distanceFromBottom: distance, containerSize: CGSize(width: 800, height: 600))
  }

  /// Flushes asynchronous tasks scheduled on the main run loop.
  private func settle() async {
    for _ in 0..<5 { await Task.yield() }
  }

  @Test func aMoveNoReportSaysStillUpdatesWhichRowsHoldImages() async {
    let reflow = TranscriptReflow()
    var position: (offset: CGFloat, distanceFromBottom: CGFloat) = (0, 9000)
    reflow.scrollTo = { _, _ in }
    reflow.position = { position }
    reflow.update(rowID: row, frame: CGRect(x: 0, y: 8000, width: 700, height: 400))
    _ = reflow.update(metrics: metrics(offset: 0, distance: 9000), isFollowingTail: false)
    await settle()
    #expect(!reflow.presence(of: row).isNear)
    position = (7800, 1200)
    reflow.scrollViewDidChange()
    await settle()
    #expect(reflow.presence(of: row).isNear)
  }

  @Test func aMoveIsCapturedEvenIfARefreshGotToItBeforeItsReport() async {
    let reflow = TranscriptReflow()
    let other = UUID()
    var position: (offset: CGFloat, distanceFromBottom: CGFloat) = (0, 9000)
    reflow.scrollTo = { _, _ in }
    reflow.position = { position }
    reflow.update(rowID: row, frame: CGRect(x: 0, y: 0, width: 700, height: 400))
    reflow.update(rowID: other, frame: CGRect(x: 0, y: 400, width: 700, height: 400))
    _ = reflow.update(metrics: metrics(offset: 0, distance: 9000), isFollowingTail: false)
    await settle()
    #expect(reflow.state.place?.rowID == row)
    // Direct scroll view bounds mutations precede SwiftUI layout reports.
    position = (500, 8500)
    reflow.scrollViewDidChange()
    await settle()
    _ = reflow.update(metrics: metrics(offset: 500, distance: 8500), isFollowingTail: false)
    await settle()
    #expect(reflow.state.place?.rowID == other)
    #expect(reflow.state.place?.offsetIntoRow == 100)
  }

  @Test func theDistanceFromTheBottomIsTheLastReportedWhereThereIsNoScrollView() {
    let reflow = TranscriptReflow()
    #expect(reflow.distanceFromBottom == 0)
    #expect(reflow.update(metrics: metrics(offset: 100, distance: 300), isFollowingTail: false) == false)
    #expect(reflow.distanceFromBottom == 300)
    #expect(reflow.update(metrics: metrics(offset: 400, distance: 0), isFollowingTail: false) == true)
    #expect(reflow.distanceFromBottom == 0)
    #expect(!reflow.state.isInEpisode)
  }

  @Test func theDistanceFromTheBottomGoesByTheScrollViewWhereThereIsOne() {
    let reflow = TranscriptReflow()
    reflow.scrollTo = { _, _ in }
    reflow.position = { (800, 447) }
    _ = reflow.update(metrics: metrics(offset: 800, distance: 0), isFollowingTail: true)
    #expect(reflow.distanceFromBottom == 447)
  }

  @Test func aViewThatShrinksAfterTheLastReportStillFollowsTheTail() {
    let reflow = TranscriptReflow()
    var position: (offset: CGFloat, distanceFromBottom: CGFloat) = (800, 0)
    var scrolledTo: [CGFloat] = []
    reflow.scrollTo = { visibleTop, _ in scrolledTo.append(visibleTop) }
    reflow.position = { position }
    _ = reflow.update(metrics: metrics(offset: 800, distance: 0), isFollowingTail: true)
    reflow.viewportWillChange(isFollowingTail: true)
    #expect(scrolledTo.isEmpty)
    // Clip view updates height following layout notification propagation.
    position = (800, 447)
    reflow.scrollViewDidChange()
    #expect(scrolledTo == [.infinity])
  }

  @Test func aChangeOutsideAnEpisodeDoesNotMoveAnything() {
    let reflow = TranscriptReflow()
    var scrolledTo: [CGFloat] = []
    reflow.scrollTo = { visibleTop, _ in scrolledTo.append(visibleTop) }
    reflow.position = { (800, 447) }
    _ = reflow.update(metrics: metrics(offset: 800, distance: 447), isFollowingTail: false)
    reflow.scrollViewDidChange()
    #expect(scrolledTo.isEmpty)
  }
}

@Suite(.tags(.pure))
struct ShimmerAnimationTests {
  /// Calculates linear interpolation position across real card geometry for reference comparison against
  /// `LinearGradient` endpoints from `(phase - 0.3, 0)` to `(phase + 0.3, 1)`.
  private func realPosition(_ x: CGFloat, _ y: CGFloat, phase: CGFloat, aspect: CGFloat) -> CGFloat {
    let line = CGVector(dx: 0.6 * aspect, dy: 1)
    let point = CGVector(dx: (x - phase + 0.3) * aspect, dy: y)
    return (point.dx * line.dx + point.dy * line.dy) / (line.dx * line.dx + line.dy * line.dy)
  }

  /// Computes normalized layer coordinate gradient position across unit square bounds.
  private func layerPosition(_ x: CGFloat, _ y: CGFloat, phase: CGFloat, aspect: CGFloat, yOfTop: CGFloat) -> CGFloat {
    let ends = ShimmerAnimation.endpoints(phase: phase, yOfTop: yOfTop, aspect: aspect)
    let line = CGVector(dx: ends.end.x - ends.start.x, dy: ends.end.y - ends.start.y)
    let layerY = yOfTop == 0 ? y : 1 - y
    let point = CGVector(dx: x - ends.start.x, dy: layerY - ends.start.y)
    return (point.dx * line.dx + point.dy * line.dy) / (line.dx * line.dx + line.dy * line.dy)
  }

  private static let aspects: [CGFloat] = [16.0 / 9, 1, 9.0 / 16, 21.0 / 9, 3.0 / 4]

  @Test(arguments: aspects)
  func eachPointOfTheCardHasTheColourItHasInRealGeometry(aspect: CGFloat) {
    for phase in [-0.3, 0.2, 0.5, 1.3] as [CGFloat] {
      for yOfTop in [0, 1] as [CGFloat] {
        for (x, y) in [(0, 0), (1, 0), (0, 1), (1, 1), (0.5, 0.5), (0.2, 0.7)] as [(CGFloat, CGFloat)] {
          let real = realPosition(x, y, phase: phase, aspect: aspect)
          #expect(abs(layerPosition(x, y, phase: phase, aspect: aspect, yOfTop: yOfTop) - real) < 0.000_001)
        }
      }
    }
  }

  @Test func theBandLeansTheSameOnACardOfAnyShape() {
    // Normal vector across 16:9 card geometry evaluates to ~46.8 degrees.
    let aspect: CGFloat = 16.0 / 9
    let ends = ShimmerAnimation.endpoints(phase: 0.5, yOfTop: 0, aspect: aspect)
    // Perpendicular gradient edge vector scaled by card aspect ratio.
    let edge = CGVector(dx: (ends.end.y - ends.start.y) * aspect, dy: ends.end.x - ends.start.x)
    let degrees = atan2(edge.dy, edge.dx) * 180 / .pi
    #expect(abs(degrees - 46.8) < 0.1)
    // Square aspect ratio maps to direct corner-to-corner linear interpolation.
    let square = ShimmerAnimation.endpoints(phase: 0.5, yOfTop: 0, aspect: 1)
    #expect(abs(square.start.x - 0.2) < 0.001 && abs(square.end.x - 0.8) < 0.001)
    #expect(abs(square.start.y) < 0.001 && abs(square.end.y - 1) < 0.001)
  }

  @Test func theBandsMiddleCrossesTheCardsMiddleAtThePhase() {
    for aspect in [16.0 / 9, 1, 9.0 / 16] as [CGFloat] {
      for phase in [-0.3, 0.5, 1.3] as [CGFloat] {
        #expect(abs(layerPosition(phase, 0.5, phase: phase, aspect: aspect, yOfTop: 1) - 0.5) < 0.000_001)
      }
    }
  }

  @Test func theBandRunsFromTopToBottomOnEitherPlatform() {
    #expect(ShimmerAnimation.endpoints(phase: 0.5, yOfTop: 0, aspect: 1).start.y == 0)
    #expect(abs(ShimmerAnimation.endpoints(phase: 0.5, yOfTop: 0, aspect: 1).end.y - 1) < 0.001)
    #expect(ShimmerAnimation.endpoints(phase: 0.5, yOfTop: 1, aspect: 1).start.y == 1)
    #expect(abs(ShimmerAnimation.endpoints(phase: 0.5, yOfTop: 1, aspect: 1).end.y) < 0.001)
  }

  @Test func everyCardIsAtTheSamePointOfACrossingAtAnyMoment() {
    #expect(ShimmerAnimation.timeOffset(at: 100.5) == 0.5)
    #expect(ShimmerAnimation.timeOffset(at: 102.5) == 0.5)
    #expect(ShimmerAnimation.timeOffset(at: 1) == 1)
  }
}
