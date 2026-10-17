import Foundation

/// Performance diagnostic instrumentation detecting main thread rendering hitches during image rasterization.
///
/// Measures execution latency across image decoding operations, raising telemetry warnings whenever
/// main-thread execution exceeds standard display refresh frame budgets (default 16 ms).
/// Configured with injectable clock, thread validation, and reporting delegates for testing.
struct DecodeTimer: Sendable {
  var threshold: Duration = .milliseconds(16)
  var now: @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
  var isMainThread: @Sendable () -> Bool = { Thread.isMainThread }
  var report: @Sendable (_ label: String, _ duration: Duration) -> Void = DecodeTimer.logReport

  init() {}

  init(
    threshold: Duration = .milliseconds(16), now: @escaping @Sendable () -> ContinuousClock.Instant,
    isMainThread: @escaping @Sendable () -> Bool = { Thread.isMainThread },
    report: @escaping @Sendable (String, Duration) -> Void
  ) {
    self.threshold = threshold
    self.now = now
    self.isMainThread = isMainThread
    self.report = report
  }

  /// Executes an operation synchronously on the calling thread, emitting telemetry if main thread thresholds are breached.
  func measure<T>(_ label: String, _ body: () throws -> T) rethrows -> T {
    let start = now()
    let value = try body()
    let elapsed = now() - start
    if elapsed > threshold && isMainThread() { report(label, elapsed) }
    return value
  }

  static let logReport: @Sendable (String, Duration) -> Void = { label, duration in
    #if DEBUG
      Log.imaging.warning("main-thread decode \(label, privacy: .public) took \(duration.formatted(), privacy: .public)")
    #endif
  }
}
