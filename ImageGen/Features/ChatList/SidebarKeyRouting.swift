import Foundation

/// Evaluates keyboard input directed at the sidebar to determine whether printable input should route to the prompt composer.
enum SidebarKeyRouting {
  /// Normalized keyboard event representation capturing characters and relevant modifier flags.
  struct Press: Equatable {
    /// Resulting text representation produced by the keystroke, or empty for unresolved dead keys.
    var characters: String
    var charactersIgnoringModifiers: String
    var command = false
    var control = false
    /// Indicates navigation keys, function keys, and editing movement controls.
    var function = false
  }

  /// Contextual focus and modal hierarchy state governing key event routing policy.
  struct Situation: Equatable {
    /// Indicates whether the sidebar list container holds active first-responder keyboard focus.
    var listHasKeyboard: Bool
    var chatIsOpen: Bool
    var isEditingRow: Bool
    var isSheetUp: Bool
  }

  /// Evaluates whether a keyboard event should be forwarded to the conversation input field.
  /// Preserves native navigation keys, shortcuts, and list editing commands while forwarding printable characters
  /// and composition sequences to the active composer.
  static func forwardsToComposer(_ press: Press, in situation: Situation) -> Bool {
    guard situation.listHasKeyboard, situation.chatIsOpen, !situation.isEditingRow, !situation.isSheetUp else { return false }
    guard !press.command, !press.control, !press.function else { return false }
    let text = press.characters.isEmpty ? press.charactersIgnoringModifiers : press.characters
    return text.unicodeScalars.allSatisfy(isTyped)
  }

  /// Filters control characters and platform private-use ranges reserved for function keys.
  private static func isTyped(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0..<0x20, 0x7F, 0xF700...0xF8FF: false
    default: true
    }
  }
}
