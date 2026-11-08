import QuartzCore

/// Core Animation parameters and geometry calculations for hardware-accelerated render-server shimmer effects on placeholder cards.
enum ShimmerAnimation {
  /// Cycle duration in seconds. Synchronized to absolute reference time across all visible instances.
  static let period: CFTimeInterval = 2
  static let cornerRadius: CGFloat = 12
  static let halfWidth: CGFloat = 0.3
  /// Normalized translation sweep bounds ensuring the gradient enters and exits the visible bounds completely.
  private static let phases: ClosedRange<CGFloat> = -0.3...1.3

  /// Calculates unit-coordinate gradient start and end vectors for a specified animation phase and target aspect ratio.
  /// Corrects for non-square layer coordinate stretching to maintain consistent diagonal sweep angles across varying aspect ratios.
  static func endpoints(phase: CGFloat, yOfTop: CGFloat, aspect: CGFloat) -> (start: CGPoint, end: CGPoint) {
    let start = CGPoint(x: phase - halfWidth, y: yOfTop)
    // Compute normalized direction vector and perpendicular gradient rate across the aspect-scaled coordinate space.
    let line = CGVector(dx: 2 * halfWidth * aspect, dy: 1)
    let lengthSquared = line.dx * line.dx + line.dy * line.dy
    let rate = CGVector(dx: aspect * line.dx / lengthSquared, dy: line.dy / lengthSquared)
    let rateSquared = rate.dx * rate.dx + rate.dy * rate.dy
    return (start, CGPoint(x: start.x + rate.dx / rateSquared, y: yOfTop + (1 - 2 * yOfTop) * rate.dy / rateSquared))
  }

  /// Calculates animation time offset from reference time to maintain synchronous phase.
  static func timeOffset(at time: TimeInterval) -> CFTimeInterval {
    time.truncatingRemainder(dividingBy: period)
  }

  /// Configures gradient stops and attaches infinite linear translations to the gradient layer.
  /// Adapts coordinate polarity to account for platform-specific vertical coordinate systems (y=0 top on iOS, y=1 top on macOS).
  static func start(
    on layer: CAGradientLayer, yOfTop: CGFloat, aspect: CGFloat, now: TimeInterval = Date().timeIntervalSinceReferenceDate
  ) {
    let clear = CGColor(gray: 1, alpha: 0)
    layer.colors = [clear, CGColor(gray: 1, alpha: 0.25), clear]
    layer.cornerRadius = cornerRadius
    layer.cornerCurve = .continuous
    layer.masksToBounds = true
    let from = endpoints(phase: phases.lowerBound, yOfTop: yOfTop, aspect: aspect)
    let to = endpoints(phase: phases.upperBound, yOfTop: yOfTop, aspect: aspect)
    layer.startPoint = from.start
    layer.endPoint = from.end
    for (key, fromValue, toValue) in [("startPoint", from.start, to.start), ("endPoint", from.end, to.end)] {
      let animation = CABasicAnimation(keyPath: key)
      animation.fromValue = fromValue
      animation.toValue = toValue
      animation.duration = period
      animation.repeatCount = .infinity
      animation.timeOffset = timeOffset(at: now)
      animation.isRemovedOnCompletion = false
      animation.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
      layer.add(animation, forKey: key)
    }
  }
}
