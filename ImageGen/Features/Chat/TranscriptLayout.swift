import CoreGraphics
import Foundation
import SwiftUI

/// Geometry calculations governing responsive column constraints and message image dimensions.
///
/// Layout calculations derive strictly from external viewport bounds rather than dynamic content extents
/// or volatile scrollbar visibility, guaranteeing stable column dimensions and preventing cyclic layout reflows.
/// Completed image replies and transient progress placeholders share identical sizing rules to eliminate layout shifts upon completion.
enum TranscriptLayout {
  /// Horizontal margin between transcript content and container boundaries.
  static let sideMargin: CGFloat = 16
  /// Maximum width constraint enforced across transcript columns regardless of window expansion.
  static let maxContentWidth: CGFloat = 1600
  /// Optimal line-length constraint applied to prose blocks and composer fields.
  static let readableWidth: CGFloat = 820
  /// Maximum viewport height fraction allocated to message reply images, ensuring context and prompt visibility.
  static let imageHeightFraction: CGFloat = 0.8
  /// Viewport height reserved for composer input and interface chrome during vertical budget allocation.
  static let composerReserve: CGFloat = 150
  /// Absolute minimum height threshold applied to image reply containers.
  static let minimumImageHeight: CGFloat = 240
  /// Minimum width constraint enforced during aspect-ratio scaling for portrait-oriented images.
  static let minimumImageWidth: CGFloat = 200
  /// Baseline fallback dimension utilized prior to initial viewport dimension measurement.
  private static let unmeasuredImageEdge: CGFloat = 640

  /// Computes the constrained transcript column width centered within viewport bounds with reserved lateral gutters.
  static func columnWidth(viewportWidth: CGFloat, gutter: CGFloat = 0) -> CGFloat {
    min(maxContentWidth + 2 * sideMargin, max(viewportWidth - 2 * gutter, 0))
  }

  /// Computes the horizontal origin for the transcript column, maintaining viewport centering independent of scrollbar metrics.
  static func columnOrigin(viewportWidth: CGFloat, gutter: CGFloat = 0) -> CGFloat {
    (viewportWidth - columnWidth(viewportWidth: viewportWidth, gutter: gutter)) / 2
  }

  /// Computes the maximum allowable height for an image reply given available viewport vertical dimensions.
  static func maxImageHeight(transcriptHeight height: CGFloat) -> CGFloat {
    max(minimumImageHeight, min((height * imageHeightFraction).rounded(), height - composerReserve))
  }

  /// Computes the maximum display width for an image of specified aspect ratio within the measured viewport.
  static func imageWidth(aspect: CGFloat, viewport: CGSize?, gutter: CGFloat = 0) -> CGFloat {
    let aspect = max(aspect, 0.1)
    guard let viewport else { return min(unmeasuredImageEdge, unmeasuredImageEdge * aspect) }
    let content = max(columnWidth(viewportWidth: viewport.width, gutter: gutter) - 2 * sideMargin, 0)
    let fitted = maxImageHeight(transcriptHeight: viewport.height) * aspect
    return min(content, max(fitted, minimumImageWidth))
  }
}

extension EnvironmentValues {
  /// Outer viewport dimensions of the parent transcript container.
  @Entry var transcriptViewport: CGSize?
  /// Spatial proximity classification indicating vertical distance relative to the visible scroll viewport.
  @Entry var transcriptRowPresence: TranscriptRowPresence?
}

/// Coordinate space identifier for relative transcript content offset reporting.
enum TranscriptContent {
  /// Coordinate space anchored to the transcript scroll document origin.
  static let coordinateSpace = "transcriptContent"
}

/// View modifier constraining message images and placeholder cards to responsive transcript layout bounds.
struct ReplyImageFrame: ViewModifier {
  let aspect: CGFloat
  @Environment(\.transcriptViewport) private var viewport

  func body(content: Self.Content) -> some View {
    content.frame(maxWidth: TranscriptLayout.imageWidth(aspect: aspect, viewport: viewport), alignment: .leading)
  }
}

/// Reserves layout geometry in placeholder reply cards corresponding to expected message footer dimensions,
/// preventing vertical shifts when generation completes and metadata renders.
struct ReplyFooterHeight: ViewModifier {
  let expectsText: Bool

  func body(content: Self.Content) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      if expectsText { Text(verbatim: " ") }
      Text(verbatim: " ").font(.caption)
    }
    .hidden()
    .overlay(alignment: .topLeading) { content.fixedSize() }
  }
}

/// Geometry reporter propagating row frames to `TranscriptReflow` for viewport anchor tracking.
struct TranscriptRowReport: ViewModifier {
  let id: UUID
  let reflow: TranscriptReflow

  func body(content: Self.Content) -> some View {
    content
      .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(TranscriptContent.coordinateSpace)) } action: { frame in
        reflow.update(rowID: id, frame: frame)
      }
      .environment(\.transcriptRowPresence, reflow.presence(of: id))
      .modifier(FarRowHitTesting(presence: reflow.presence(of: id)))
  }
}

/// Optimizes scrolling performance by disabling hit testing on rows positioned outside visible proximity thresholds.
private struct FarRowHitTesting: ViewModifier {
  let presence: TranscriptRowPresence

  func body(content: Self.Content) -> some View {
    content.allowsHitTesting(presence.isNear)
  }
}

/// Unobserved mutable accumulator capturing user scroll gestures to coordinate programmatic scroll stabilization without triggering view updates.
@MainActor
final class TranscriptUserScrolling {
  var isScrolling = false
  /// Timestamp of the most recent discrete user scroll wheel or trackpad interaction.
  var lastWheel = Date.distantPast
  /// Monotonically increasing counter tracking user-initiated scroll gestures.
  var count = 0
}

/// Timing heuristics and threshold predicates governing programmatic scroll stabilization.
enum TranscriptSettling {
  /// Sequential delay intervals applied during post-render scroll alignment passes.
  static let delays = [0.05, 0.35, 0.9]
  /// Inertial threshold interval following trackpad or scroll wheel interaction before programmatic alignment resumes.
  static let wheelQuietPeriod: TimeInterval = 0.6

  /// Evaluates whether interactive user scrolling has superseded programmatic settling.
  static func shouldStop(userScrolled: Bool, isUserScrolling: Bool, sinceLastWheel: TimeInterval) -> Bool {
    userScrolled || isUserScrolling || sinceLastWheel <= wheelQuietPeriod
  }

  /// Determines whether the distance from the viewport trailing edge exceeds minimum repositioning thresholds.
  static func needsScroll(distanceFromBottom: CGFloat) -> Bool { distanceFromBottom > 1 }
}
