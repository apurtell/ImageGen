import Foundation
import Synchronization

/// Secrets the activity-log sanitizer removes (D§4.13). Registered for the life of the process:
/// nothing unregisters, so a removed key is still scrubbed.
final class SecretRegistry: Sendable {
  private let secrets = Mutex<Set<String>>([])

  init() {}

  func register(_ secret: String) {
    guard !secret.isEmpty else { return }
    _ = secrets.withLock { $0.insert(secret) }
  }

  var all: [String] { secrets.withLock { Array($0) } }
}
