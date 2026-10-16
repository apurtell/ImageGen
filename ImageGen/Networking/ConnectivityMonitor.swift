import Foundation
import Network

/// Drives only the foreground "Waiting for network" label (D§3.4); it never affects tasks.
protocol ConnectivityMonitoring: Sendable {
  /// The current value first, then every change.
  var isSatisfied: AsyncStream<Bool> { get }
}

final class NWPathConnectivityMonitor: ConnectivityMonitoring {
  private let monitor = NWPathMonitor()
  private let queue = DispatchQueue(label: "connectivity")
  private let state = Locked<(current: Bool, subscribers: [UUID: AsyncStream<Bool>.Continuation])>((true, [:]))

  init() {
    monitor.pathUpdateHandler = { [state] path in
      let satisfied = path.status == .satisfied
      // Yielding under the lock keeps every subscriber's values in the order they were set
      // (`yield` never blocks).
      state.withLock { s in
        s.current = satisfied
        for c in s.subscribers.values { c.yield(satisfied) }
      }
    }
    monitor.start(queue: queue)
  }

  deinit { monitor.cancel() }

  var isSatisfied: AsyncStream<Bool> {
    let (stream, continuation) = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let id = UUID()
    continuation.onTermination = { [state] _ in _ = state.withLock { $0.subscribers.removeValue(forKey: id) } }
    // The current value and the registration together, so no change can slip in between.
    state.withLock { s in
      s.subscribers[id] = continuation
      continuation.yield(s.current)
    }
    return stream
  }
}
