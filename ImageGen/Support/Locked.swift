import Synchronization

/// A `Mutex` in a class, so closures can capture it (a `Mutex` itself can't be copied).
final class Locked<Value: Sendable>: Sendable {
  private let mutex: Mutex<Value>

  init(_ value: Value) {
    mutex = Mutex(value)
  }

  func withLock<T>(_ body: (inout Value) throws -> T) rethrows -> T {
    try mutex.withLock { try body(&$0) }
  }

  var value: Value { mutex.withLock { $0 } }
}
