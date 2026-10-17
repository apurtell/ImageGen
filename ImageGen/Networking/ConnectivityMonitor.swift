import Foundation
import Network

/// Drives only the foreground "Waiting for network" label (D§3.4); it never affects tasks.
///
/// The background `URLSession` waits for the network by itself, so the transport does not use this
/// monitor. Chat screen models subscribe to `isSatisfied` and show the label while it reads `false`.
/// The protocol lets tests supply a fake monitor.
protocol ConnectivityMonitoring: Sendable {
  /// The current value first, then every change.
  ///
  /// Each read of this property returns a new `AsyncStream` for one subscriber. The subscriber reads it
  /// with `for await`; the subscription ends when that loop's task ends. See the primer, *AsyncStream*.
  var isSatisfied: AsyncStream<Bool> { get }
}

/// The production monitor, a wrapper around the Network framework's `NWPathMonitor`.
///
/// Concurrency: `NWPathMonitor` calls `pathUpdateHandler` on the private `queue`, while subscribers
/// register from any thread. A `Locked` value (a `Mutex` in a class; see the primer, *Locks*) protects
/// the current value and the subscriber list, so the class is `Sendable` without an actor.
final class NWPathConnectivityMonitor: ConnectivityMonitoring {
  private let monitor = NWPathMonitor()
  private let queue = DispatchQueue(label: "connectivity")
  /// `current` starts as `true` (connected) until the first path update arrives, so the label does not
  /// flash at launch.
  private let state = Locked<(current: Bool, subscribers: [UUID: AsyncStream<Bool>.Continuation])>((true, [:]))

  init() {
    // `[state]` captures the lock object itself, not `self`, so the handler does not keep the monitor
    // alive and `deinit` can still run.
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
    // `.bufferingNewest(1)`: a slow subscriber sees only the latest value, which is all a label needs.
    let (stream, continuation) = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let id = UUID()
    // When the subscriber stops reading (its task ends or is cancelled), it is removed from the list.
    continuation.onTermination = { [state] _ in _ = state.withLock { $0.subscribers.removeValue(forKey: id) } }
    // The current value and the registration together, so no change can slip in between.
    state.withLock { s in
      s.subscribers[id] = continuation
      continuation.yield(s.current)
    }
    return stream
  }
}
