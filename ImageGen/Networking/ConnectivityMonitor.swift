import Foundation
import Network

/// Observes network path viability to drive UI connectivity indicators.
///
/// Because background `URLSession` transfers manage their own network reconnection and waiting behavior,
/// this abstraction exists primarily to inform user-facing status indicators. Feature view models observe
/// `isSatisfied` to display network reachability banners without directly coupling to background transport states.
protocol ConnectivityMonitoring: Sendable {
  /// Asynchronous stream yielding the initial connectivity state followed by subsequent transitions.
  var isSatisfied: AsyncStream<Bool> { get }
}

/// Network framework implementation wrapping `NWPathMonitor` with thread-safe broadcast semantics.
///
/// Employs internal lock synchronization to mediate concurrent access between `NWPathMonitor` callbacks
/// on a dedicated dispatch queue and dynamic `AsyncStream` subscriber subscriptions across arbitrary threads.
final class NWPathConnectivityMonitor: ConnectivityMonitoring {
  private let monitor = NWPathMonitor()
  private let queue = DispatchQueue(label: "connectivity")
  /// Tracks path viability, defaulting optimistically to true to prevent transient startup flash.
  private let state = Locked<(current: Bool, subscribers: [UUID: AsyncStream<Bool>.Continuation])>((true, [:]))

  init() {
    // Retain only the synchronization lock within the callback closure to break reference cycles during lifecycle teardown.
    monitor.pathUpdateHandler = { [state] path in
      let satisfied = path.status == .satisfied
      state.withLock { s in
        s.current = satisfied
        for c in s.subscribers.values { c.yield(satisfied) }
      }
    }
    monitor.start(queue: queue)
  }

  deinit { monitor.cancel() }

  var isSatisfied: AsyncStream<Bool> {
    // Buffer only the most recent transition since transient intermediate states are irrelevant to display telemetry.
    let (stream, continuation) = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let id = UUID()
    continuation.onTermination = { [state] _ in _ = state.withLock { $0.subscribers.removeValue(forKey: id) } }
    state.withLock { s in
      s.subscribers[id] = continuation
      continuation.yield(s.current)
    }
    return stream
  }
}
