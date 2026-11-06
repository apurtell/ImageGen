import CoreGraphics
import SwiftUI

/// Paging calculation utilities for sequential asset navigation across multi-image replies.
enum ViewerPaging {
  /// Resolves the neighboring asset identifier offset by `delta` within bounds, defaulting to `current`.
  static func step(from current: UUID, in ids: [UUID], by delta: Int) -> UUID {
    guard let index = ids.firstIndex(of: current) else { return current }
    return ids[min(max(index + delta, 0), ids.count - 1)]
  }

  /// Evaluates whether an offset transition in either direction targets a distinct valid identifier.
  static func canStep(from current: UUID, in ids: [UUID], by delta: Int) -> Bool {
    step(from: current, in: ids, by: delta) != current
  }
}

/// Discrete magnification commands dispatched via keyboard shortcuts or application menus.
enum ZoomCommand: Sendable {
  case zoomIn, zoomOut, fit, actualSize
}

/// Bidirectional delegation interface coordinating window lifecycle, keyboard events, and viewer state.
///
/// Decouples AppKit window controllers and menu commands from SwiftUI viewer presentations.
@MainActor
final class ViewerKeyRouter {
  /// Dismisses or closes the hosting window.
  var close: () -> Void = {}
  /// Offsets current image selection by a relative page delta.
  var move: (Int) -> Void = { _ in }
  /// Dispatches a discrete zoom command to the active image viewport.
  var zoom: (ZoomCommand) -> Void = { _ in }
  /// Updates displayed window title with current asset filename.
  var setTitle: (String) -> Void = { _ in }
  /// Updates positional index indicators for multi-image presentations.
  var setPosition: (String) -> Void = { _ in }
  /// Updates forward and backward paging availability flags for menu validation.
  var setPaging: (_ canMoveBack: Bool, _ canMoveForward: Bool) -> Void = { _, _ in }
  /// Triggers export workflows for the active image asset.
  var export: (ImageExportAction) -> Void = { _ in }
  /// Stages the active asset into composer context and dismisses the viewer.
  var editFromHere: () -> Void = {}
  /// Presents detailed metadata inspection for the active asset.
  var showInfo: () -> Void = {}
}

extension EnvironmentValues {
  @Entry var viewerKeyRouter: ViewerKeyRouter?
}
