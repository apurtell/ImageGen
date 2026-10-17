import Foundation
import Synchronization

/// Thread safe registry tracking dynamic sensitive tokens for diagnostic log redaction.
/// Secrets registered during application execution persist for the process lifetime to prevent
/// inadvertent credential leakage in rotating diagnostic logs, even after credential deletion.
final class SecretRegistry: Sendable {
  private let secrets = Mutex<Set<String>>([])

  init() {}

  /// Minimum token length enforced to prevent over-eager replacement of common substrings.
  static let minimumLength = 8

  func register(_ secret: String) {
    guard secret.count >= Self.minimumLength else { return }
    _ = secrets.withLock { $0.insert(secret) }
  }

  /// Thread safe snapshot of all registered secret tokens.
  var all: [String] { secrets.withLock { Array($0) } }
}
