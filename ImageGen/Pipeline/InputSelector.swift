import Foundation

/// Tray item counts at the moment Send is evaluated. `pending` = importing or preparing.
struct TrayCounts: Sendable, Equatable {
  var ready: Int
  var pending: Int
  var failed: Int
}

/// Chooses the input images for a send (D§2.2). Pure.
///
/// An `enum` with no cases can't be created; it serves as a namespace for static functions. Pure
/// functions have no state, so any thread can call them. Callers: `ChatScreenModel` on the main actor
/// (the "Editing latest image" chip and the Send button) and `GenerationService.send`, which records
/// the selection.
enum InputSelector {
  static func select(_ input: SelectionInput) -> Selection {
    // Any pin is one-shot: cleared by every send, used or not, and when its asset is gone.
    let clearPin = input.pinnedImageID != nil

    // 1. Attachments, all of them, in tray order.
    if !input.attachments.isEmpty {
      return Selection(imageIDs: input.attachments, reason: .attachments, clearPin: clearPin)
    }
    // 2. The pin, if its asset still exists.
    if let pin = input.pinnedImageID, input.pinnedImageExists {
      return Selection(imageIDs: [pin], reason: .pinned, clearPin: true)
    }
    // 3. The most recent image.
    if let latest = implicitBase(history: input.history) {
      return Selection(imageIDs: [latest], reason: .latest, clearPin: clearPin)
    }
    // 4. None: text-to-image.
    return Selection(imageIDs: [], reason: .noImage, clearPin: clearPin)
  }

  /// Rule 3: walking by descending sequence, skipping model replies that didn't succeed, the
  /// highest-ordinal image of the first message that has one. Drives the "Editing latest image" chip.
  static func implicitBase(history: [SelectorMessage]) -> UUID? {
    for message in history.sorted(by: { $0.sequence > $1.sequence }) {
      if message.role == .model && message.replyState != .succeeded { continue }
      if let last = message.images.max(by: { $0.ordinal < $1.ordinal }) { return last.id }
    }
    return nil
  }

  /// Send is enabled only when every tray item is ready and the chat has no live request, and there
  /// is text or at least one image.
  static func canSend(trimmedText: String, tray: TrayCounts, chatHasLiveRequest: Bool) -> Bool {
    guard tray.pending == 0, tray.failed == 0, !chatHasLiveRequest else { return false }
    return !trimmedText.isEmpty || tray.ready > 0
  }
}
