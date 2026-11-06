import CoreGraphics
import Foundation
import SwiftUI

/// Geometry constraints governing rendered transcript image dimensions and corresponding placeholder bounds.
///
/// Standardizes dimensions across placeholder states and loaded assets to prevent vertical layout shifts during generation.
enum ReplyImageCap {
  /// Maximum absolute edge length permitted for rendered inline images.
  static let maxEdge: CGFloat = 640
  /// Maximum fractional height an inline image may occupy relative to total transcript viewport height.
  static let heightFraction: CGFloat = 0.6

  /// Calculates maximum allowable width for a specified aspect ratio against available transcript height.
  ///
  /// Anchors against outer viewport height to maintain stable image dimensions independently of dynamic composer expansion.
  static func maxWidth(aspect: CGFloat, transcriptHeight height: CGFloat?) -> CGFloat {
    let aspect = max(aspect, 0.1)
    let tallest = height.map { min(maxEdge, ($0 * heightFraction).rounded()) } ?? maxEdge
    return min(maxEdge, tallest * aspect)
  }
}

extension EnvironmentValues {
  /// Outer transcript viewport height utilized for proportional image layout constraints.
  @Entry var transcriptHeight: CGFloat?
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
