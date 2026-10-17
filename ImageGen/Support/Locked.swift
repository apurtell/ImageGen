import Synchronization

/// A `Mutex` in a class, so closures can capture it (a `Mutex` itself can't be copied).
///
/// A class instance is shared by reference, so every closure that captures one `Locked` uses the
/// same lock. The class is `Sendable` with no `@unchecked`, because `Mutex` is `Sendable` and guards
/// every access (see the primer, *Locks*). Use it for small, fast state that synchronous code
/// changes, such as network callbacks and `ActivityLog.flush(timeout:)`. `Mutex` is not reentrant:
/// don't call `withLock` on the same `Locked` inside the closure.
final class Locked<Value: Sendable>: Sendable {
  private let mutex: Mutex<Value>

  init(_ value: Value) {
    mutex = Mutex(value)
  }

  /// Runs `body` under the lock. `inout` lets it change the value in place; `rethrows` means this
  /// throws only when `body` throws.
  func withLock<T>(_ body: (inout Value) throws -> T) rethrows -> T {
    try mutex.withLock { try body(&$0) }
  }

  /// A copy, read under the lock. It can be out of date as soon as this returns, so a
  /// read-then-write must use one `withLock` call instead.
  var value: Value { mutex.withLock { $0 } }
}
