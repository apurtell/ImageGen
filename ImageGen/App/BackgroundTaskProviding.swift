import Foundation

/// Identifies an active background task.
struct BackgroundTaskToken: Sendable, Hashable {
  let id: Int
}

/// Prevents the system from suspending the app while preparing a generation request.
///
/// Generation requests downscale input images and serialize request payloads before handing
/// off to the background URLSession. Implementations handle platform-specific background
/// tasks (such as UIKit background tasks or macOS process activities), and test doubles can
/// simulate expiration timeouts.
protocol BackgroundTaskProviding: Sendable {
  /// Begins a background task. Calls `onExpire` if the system expires the task before it finishes.
  func begin(name: String, onExpire: @escaping @Sendable () -> Void) async -> BackgroundTaskToken
  /// Ends the background task corresponding to the token.
  func end(_ token: BackgroundTaskToken) async
}
