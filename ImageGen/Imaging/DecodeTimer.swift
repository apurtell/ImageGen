import Foundation

/// Times an image decode and reports one that ran on the main thread for longer than 16 ms (D§8).
/// The default reporter logs under `imaging` in DEBUG and does nothing in Release.
///
/// `ThumbnailService` and the full-screen viewer wrap their decodes in `measure`. A report means a
/// decode slowed the main thread, which draws the user interface; there should be none. It is a
/// `Sendable` value with no shared state, so any thread can use its own copy. The clock, the
/// main-thread test and the reporter are closures, so tests can supply fakes.
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

  /// Runs `body` on the caller's thread and returns its value. `rethrows` means it throws only if
  /// `body` throws.
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
