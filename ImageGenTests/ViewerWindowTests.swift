import CoreGraphics
import Foundation
import Testing

@testable import ImageGen

@Suite(.tags(.pure))
struct ViewerWindowTests {
  private let screen = CGSize(width: 1440, height: 900)

  @Test func largeImageShrinksToNinetyPercentOfScreen() {
    let size = ViewerWindowSizing.contentSize(image: CGSize(width: 4096, height: 4096), available: screen, pixelScale: 2)
    #expect(size == CGSize(width: 810, height: 810))
  }

  @Test func smallImageOpensAtItsPointSize() {
    let size = ViewerWindowSizing.contentSize(image: CGSize(width: 1200, height: 900), available: screen, pixelScale: 2)
    #expect(size == CGSize(width: 600, height: 450))
  }

  @Test func tinyImageGetsTheMinimum() {
    let size = ViewerWindowSizing.contentSize(image: CGSize(width: 100, height: 100), available: screen, pixelScale: 2)
    #expect(size == ViewerWindowSizing.minContent)
  }

  @Test func wideImageKeepsItsAspectWithinTheScreen() {
    let size = ViewerWindowSizing.contentSize(image: CGSize(width: 6000, height: 1500), available: screen, pixelScale: 2)
    #expect(size.width == 1296)
    #expect(size.height == ViewerWindowSizing.minContent.height)
  }

  @Test func unknownSizeUsesTheFallbackWithinTheScreen() {
    #expect(ViewerWindowSizing.contentSize(image: .zero, available: screen, pixelScale: 2) == ViewerWindowSizing.fallback)
    let small = ViewerWindowSizing.contentSize(image: .zero, available: CGSize(width: 800, height: 600), pixelScale: 2)
    #expect(small == CGSize(width: 720, height: 540))
  }

  @Test func clampingMovesAFrameUpAndLeftOntoTheScreen() {
    let visible = CGRect(x: 0, y: 40, width: 1440, height: 800)
    // Frames extending past trailing or bottom edges are translated without resizing.
    let moved = ViewerWindowSizing.clamped(CGRect(x: 1000, y: -100, width: 600, height: 500), to: visible)
    #expect(moved == CGRect(x: 840, y: 40, width: 600, height: 500))
    // Frames exceeding screen dimensions are resized while preserving top origin when feasible.
    let tall = ViewerWindowSizing.clamped(CGRect(x: 10, y: 0, width: 300, height: 1000), to: visible)
    #expect(tall == CGRect(x: 10, y: 40, width: 300, height: 800))
    // Frames within visible bounds remain unchanged.
    let inside = CGRect(x: 100, y: 100, width: 300, height: 300)
    #expect(ViewerWindowSizing.clamped(inside, to: visible) == inside)
  }

  @Test func centeringUsesTheGivenDisplay() {
    let external = CGRect(x: 2000, y: 100, width: 1000, height: 800)
    let frame = ViewerWindowSizing.centered(CGSize(width: 400, height: 200), in: external)
    #expect(frame == CGRect(x: 2300, y: 400, width: 400, height: 200))
  }

  @Test func orientationsMapCornersToTheDisplayedImage() {
    let size = CGSize(width: 4, height: 2)
    // Source image top-left coordinates mapped in bottom-left origin coordinate space.
    let topLeft = CGPoint(x: 0, y: 2)
    func mapped(_ o: Int) -> CGPoint { topLeft.applying(ExifOrientation.transform(orientation: o, size: size)) }
    #expect(mapped(1) == CGPoint(x: 0, y: 2))
    #expect(mapped(2) == CGPoint(x: 4, y: 2))
    #expect(mapped(3) == CGPoint(x: 4, y: 0))
    #expect(mapped(4) == CGPoint(x: 0, y: 0))
    // Transposed orientations swap width and height dimensions.
    #expect(mapped(5) == CGPoint(x: 0, y: 4))
    #expect(mapped(6) == CGPoint(x: 2, y: 4))
    #expect(mapped(7) == CGPoint(x: 2, y: 0))
    #expect(mapped(8) == CGPoint(x: 0, y: 0))
    #expect(ExifOrientation.displaySize(size, orientation: 6) == CGSize(width: 2, height: 4))
    #expect(ExifOrientation.displaySize(size, orientation: 3) == size)
  }

  @Test func pagingStopsAtBothEnds() {
    let ids = (0..<3).map { _ in UUID() }
    #expect(ViewerPaging.step(from: ids[0], in: ids, by: -1) == ids[0])
    #expect(ViewerPaging.step(from: ids[0], in: ids, by: 1) == ids[1])
    #expect(ViewerPaging.step(from: ids[2], in: ids, by: 1) == ids[2])
    let stranger = UUID()
    #expect(ViewerPaging.step(from: stranger, in: ids, by: 1) == stranger)
  }

  @Test func pagingIsOnlyAvailableWhereThereIsAnotherImage() {
    let ids = (0..<3).map { _ in UUID() }
    #expect(!ViewerPaging.canStep(from: ids[0], in: ids, by: -1))
    #expect(ViewerPaging.canStep(from: ids[0], in: ids, by: 1))
    #expect(ViewerPaging.canStep(from: ids[1], in: ids, by: -1))
    #expect(ViewerPaging.canStep(from: ids[1], in: ids, by: 1))
    #expect(ViewerPaging.canStep(from: ids[2], in: ids, by: -1))
    #expect(!ViewerPaging.canStep(from: ids[2], in: ids, by: 1))
    let one = [UUID()]
    #expect(!ViewerPaging.canStep(from: one[0], in: one, by: -1))
    #expect(!ViewerPaging.canStep(from: one[0], in: one, by: 1))
    #expect(!ViewerPaging.canStep(from: UUID(), in: ids, by: 1))
  }

  @Test func theWindowOpensAtLeastAsLargeAsItsMinimum() {
    #expect(ViewerWindowSizing.minContent.width >= ViewerWindowSizing.minimumContent.width)
    #expect(ViewerWindowSizing.minContent.height >= ViewerWindowSizing.minimumContent.height)
  }

  @Test func doubleClickGoesToActualSizeThenBackToFit() {
    let fit: CGFloat = 0.2
    #expect(ZoomMath.toggleTarget(current: fit, fit: fit, actual: 0.5, maxScale: 1) == 0.5)
    #expect(ZoomMath.toggleTarget(current: 0.5, fit: fit, actual: 0.5, maxScale: 1) == fit)
  }

  @Test func doubleClickOnASmallImageUsesTheDoubleTapFactor() {
    #expect(ZoomMath.toggleTarget(current: 1, fit: 1, actual: 0.5, maxScale: 4) == ZoomMath.doubleTapFactor)
    #expect(ZoomMath.toggleTarget(current: 1, fit: 1, actual: 0.5, maxScale: 2) == 2)
  }

  @Test func keyboardZoomStaysWithinLimits() {
    #expect(ZoomMath.stepped(0.2, zoomingIn: false, fit: 0.2, maxScale: 1) == 0.2)
    #expect(ZoomMath.stepped(0.9, zoomingIn: true, fit: 0.2, maxScale: 1) == 1)
    #expect(ZoomMath.stepped(0.4, zoomingIn: true, fit: 0.2, maxScale: 1) == 0.5)
  }
}
