import SwiftUI

/// Command dispatcher publishing contextual conversation actions and state to system menus and keybindings.
struct ChatCommandHandle {
  /// Operations targeting the most recently rendered image within the active conversation.
  struct LatestImage {
    var view: () -> Void
    var export: (ImageExportAction) -> Void
    var editFromHere: () -> Void
  }

  var canStop: Bool
  var canJumpToLatest: Bool
  var canSend: Bool
  var canAddImages: Bool
  /// Indicates whether a modal presentation or sheet is currently active over the conversation.
  var isPresenting: Bool
  var stop: () -> Void
  var rename: () -> Void
  var showSettings: () -> Void
  var delete: () -> Void
  var jumpToLatest: () -> Void
  var send: () -> Void
  var choosePhotos: () -> Void
  var chooseFiles: () -> Void
  var pasteImage: () -> Void
  /// Context-dependent actions targeting terminal or trailing messages; nil when inapplicable.
  var regenerateLastReply: (() -> Void)?
  var editLastPrompt: (() -> Void)?
  var lastReplyInfo: (() -> Void)?
  var deleteLastMessage: (() -> Void)?
  var latestImage: LatestImage?
}

extension FocusedValues {
  /// Focused conversation command handle bound to the active window key context.
  @Entry var chatCommands: ChatCommandHandle?
}
