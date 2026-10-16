import Foundation
import Synchronization

/// Secrets the activity-log sanitizer removes (D§4.13). Registered for the life of the process:
/// nothing unregisters, so a removed key is still scrubbed.
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

  var all: [String] { secrets.withLock { Array($0) } }
}
