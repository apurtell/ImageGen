import Foundation
import Synchronization
import Testing

@testable import ImageGen

@Suite(.tags(.pure))
struct DecodeTimerTests {
  final class Recorder: Sendable {
    let reports = Mutex<[String]>([])
  }

  /// Deterministic clock advancing by 20ms intervals per sample to simulate threshold exceeding latency.
  final class SteppingClock: Sendable {
    let base = ContinuousClock.now
    let n = Mutex(0)
    func now() -> ContinuousClock.Instant {
      base + .milliseconds(20 * n.withLock { v in
        v += 1
        return v
      })
    }
  }

  static func timer(_ recorder: Recorder) -> DecodeTimer {
    let clock = SteppingClock()
    return DecodeTimer(now: { clock.now() }, report: { label, _ in recorder.reports.withLock { $0.append(label) } })
  }

  @MainActor @Test func slowMainThreadDecodeReported() {
    let recorder = Recorder()
    let value = Self.timer(recorder).measure("thumbnail 1200") { 42 }
    #expect(value == 42)
    #expect(recorder.reports.withLock { $0 } == ["thumbnail 1200"])
  }

  @Test func offMainThreadNotReported() async {
    let recorder = Recorder()
    let timer = Self.timer(recorder)
    await Task.detached { _ = timer.measure("background") { 1 } }.value
    #expect(recorder.reports.withLock { $0 }.isEmpty)
  }

  @MainActor @Test func fastMainThreadDecodeNotReported() {
    let recorder = Recorder()
    let timer = DecodeTimer(now: { ContinuousClock.now }, report: { label, _ in recorder.reports.withLock { $0.append(label) } })
    _ = timer.measure("fast") { 1 }
    #expect(recorder.reports.withLock { $0 }.isEmpty)
  }
}
