import AppKit
import SwiftUI

/// NSViewRepresentable bridging Core Animation shimmer gradient rendering to SwiftUI.
struct ShimmerBand: NSViewRepresentable {
  /// Aspect ratio (width / height) governing gradient sweep angle calculation.
  let aspect: CGFloat

  func makeNSView(context: Context) -> ShimmerBandView { ShimmerBandView() }

  func updateNSView(_ view: ShimmerBandView, context: Context) { view.aspect = aspect }
}

final class ShimmerBandView: NSView {
  var aspect: CGFloat = 1 {
    didSet { if aspect != oldValue { startBand() } }
  }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  override func makeBackingLayer() -> CALayer { CAGradientLayer() }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    startBand()
  }

  private func startBand() {
    guard window != nil, let gradient = layer as? CAGradientLayer else { return }
    ShimmerAnimation.start(on: gradient, yOfTop: 1, aspect: aspect)
  }
}
