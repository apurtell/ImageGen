import Foundation

/// Attachment tray readiness state snapshot evaluated during draft validation.
struct TrayCounts: Sendable, Equatable {
  var ready: Int
  var pending: Int
  var failed: Int
}

/// Resolves candidate reference images for generation requests based on attachment precedence,
/// explicit pins, and conversation history. Stateless utility namespace invoked during UI state
/// composition and request preparation.
enum InputSelector {
  static func select(_ input: SelectionInput) -> Selection {
    // Pinned references are single-use and cleared on subsequent dispatch regardless of selection outcome.
    let clearPin = input.pinnedImageID != nil

    // 1. Explicit user attachments take highest precedence.
    if !input.attachments.isEmpty {
      return Selection(imageIDs: input.attachments, reason: .attachments, clearPin: clearPin)
    }
    // 2. User-pinned reference image if the asset remains available.
    if let pin = input.pinnedImageID, input.pinnedImageExists {
      return Selection(imageIDs: [pin], reason: .pinned, clearPin: true)
    }
    // 3. Most recent valid image in the conversation sequence.
    if let latest = implicitBase(history: input.history) {
      return Selection(imageIDs: [latest], reason: .latest, clearPin: clearPin)
    }
    // 4. Pure text-to-image generation.
    return Selection(imageIDs: [], reason: .noImage, clearPin: clearPin)
  }

  /// Identifies the implicit base image by traversing message history in reverse chronological order,
  /// selecting the highest ordinal image from the first successfully generated or user-provided message.
  static func implicitBase(history: [SelectorMessage]) -> UUID? {
    for message in history.sorted(by: { $0.sequence > $1.sequence }) {
      if message.role == .model && message.replyState != .succeeded { continue }
      if let last = message.images.max(by: { $0.ordinal < $1.ordinal }) { return last.id }
    }
    return nil
  }

  /// Validates whether draft criteria permit dispatch: all attachments prepared, no concurrent requests active, and non-empty content.
  static func canSend(trimmedText: String, tray: TrayCounts, chatHasLiveRequest: Bool) -> Bool {
    guard tray.pending == 0, tray.failed == 0, !chatHasLiveRequest else { return false }
    return !trimmedText.isEmpty || tray.ready > 0
  }
}
