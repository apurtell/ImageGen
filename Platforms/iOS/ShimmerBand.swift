import SwiftUI
import UIKit

/// UIViewRepresentable bridging Core Animation shimmer gradient rendering to SwiftUI.
struct ShimmerBand: UIViewRepresentable {
  /// Aspect ratio (width / height) governing gradient sweep angle calculation.
  let aspect: CGFloat

  func makeUIView(context: Context) -> ShimmerBandView { ShimmerBandView() }

  func updateUIView(_ view: ShimmerBandView, context: Context) { view.aspect = aspect }
}

final class ShimmerBandView: UIView {
  var aspect: CGFloat = 1 {
    didSet { if aspect != oldValue { startBand() } }
  }

  override class var layerClass: AnyClass { CAGradientLayer.self }

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    startBand()
  }

  private func startBand() {
    guard window != nil, let gradient = layer as? CAGradientLayer else { return }
    ShimmerAnimation.start(on: gradient, yOfTop: 0, aspect: aspect)
  }
}
