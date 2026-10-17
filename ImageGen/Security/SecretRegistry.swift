import Foundation
import Synchronization

/// Secrets the activity-log sanitizer removes (D§4.13). Registered for the life of the process:
/// nothing unregisters, so a removed key is still scrubbed.
///
/// `AppEnvironment` makes one registry first, before the log, and gives it to the log's sanitizer and
/// to every key store. The key stores and onboarding register each key they see; the sanitizer reads
/// `all` for every log line, on whatever thread writes the line. A `Mutex` protects the set, so the
/// class is `Sendable` and needs no actor (see the primer, *Locks*).
final class SecretRegistry: Sendable {
  private let secrets = Mutex<Set<String>>([])

  init() {}

  /// Shorter strings aren't keys (a Gemini key is 39 characters), and removing them from every
  /// log line would mangle ordinary words.
  static let minimumLength = 8

  func register(_ secret: String) {
    guard secret.count >= Self.minimumLength else { return }
    _ = secrets.withLock { $0.insert(secret) }
  }

  /// A copy of the set, made under the lock, so the caller can use it after the lock is released.
  var all: [String] { secrets.withLock { Array($0) } }
}
