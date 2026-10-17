import Synchronization

/// Reference typed wrapper around `Synchronization.Mutex`, providing shared memory synchronization
/// for closures and asynchronous callbacks without requiring `@unchecked Sendable`.
///
/// Encapsulates thread-safe access to mutable value state across concurrent boundaries where reference
/// semantics are required.
final class Locked<Value: Sendable>: Sendable {
  private let mutex: Mutex<Value>

  init(_ value: Value) {
    mutex = Mutex(value)
  }

  /// Executes a closure synchronously within the mutex critical section, providing mutable in-place access to protected state.
  func withLock<T>(_ body: (inout Value) throws -> T) rethrows -> T {
    try mutex.withLock { try body(&$0) }
  }

  /// Retrieves a snapshot copy of the protected value under the lock.
  var value: Value { mutex.withLock { $0 } }
}
