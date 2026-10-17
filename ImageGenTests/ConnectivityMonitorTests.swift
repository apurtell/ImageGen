import Foundation
import Testing

@testable import ImageGen

/// Mock implementation of `ConnectivityMonitoring` allowing test suites to simulate network availability transitions.
final class FakeConnectivityMonitor: ConnectivityMonitoring {
  private let subscribers = Locked<[AsyncStream<Bool>.Continuation]>([])
  private let current = Locked(true)

  var isSatisfied: AsyncStream<Bool> {
    let (stream, c) = AsyncStream<Bool>.makeStream(bufferingPolicy: .unbounded)
    c.yield(current.value)
    subscribers.withLock { $0.append(c) }
    return stream
  }

  func set(_ value: Bool) {
    current.withLock { $0 = value }
    for s in subscribers.value { s.yield(value) }
  }

  func finish() { for s in subscribers.value { s.finish() } }
}

@Suite(.tags(.pure))
struct ConnectivityMonitorTests {
  @Test func valuesReachSubscribersInOrder() async {
    let monitor = FakeConnectivityMonitor()
    let stream = monitor.isSatisfied
    monitor.set(false)
    monitor.set(true)
    monitor.set(false)
    monitor.finish()
    var seen: [Bool] = []
    for await v in stream { seen.append(v) }
    #expect(seen == [true, false, true, false])
  }

  @Test func realMonitorPublishesCurrentValue() async {
    let monitor = NWPathConnectivityMonitor()
    var it = monitor.isSatisfied.makeAsyncIterator()
    #expect(await it.next() != nil)
  }
}
