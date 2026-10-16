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
      let subscribers = state.withLock { s in
        s.current = satisfied
        return Array(s.subscribers.values)
      }
      for s in subscribers { s.yield(satisfied) }
    }
    monitor.start(queue: queue)
  }

  deinit { monitor.cancel() }

  var isSatisfied: AsyncStream<Bool> {
    let (stream, continuation) = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let id = UUID()
    let current = state.withLock { s in
      s.subscribers[id] = continuation
      return s.current
    }
    continuation.yield(current)
    continuation.onTermination = { [state] _ in _ = state.withLock { $0.subscribers.removeValue(forKey: id) } }
    return stream
  }
}
