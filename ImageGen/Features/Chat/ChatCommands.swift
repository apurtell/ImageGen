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

/// Command menu items and keybindings bound to the active conversation context.
struct ChatItems: View {
  let chat: ChatCommandHandle?

  private var isBlocked: Bool { chat == nil || chat?.isPresenting == true }

  var body: some View {
    Button("Send") { chat?.send() }
      .keyboardShortcut(.return, modifiers: .command)
      .disabled(chat?.canSend != true || isBlocked)
    Button("Stop Generating") { chat?.stop() }
      .keyboardShortcut(".")
      .disabled(chat?.canStop != true)
    Divider()
    Button(Platform.choosePhotosCommandTitle) { chat?.choosePhotos() }
      .disabled(chat?.canAddImages != true || isBlocked)
    Button(Platform.chooseFilesCommandTitle) { chat?.chooseFiles() }
      .keyboardShortcut("o")
      .disabled(chat?.canAddImages != true || isBlocked)
    Divider()
    Button("Regenerate Last Reply") { chat?.regenerateLastReply?() }
      .disabled(chat?.regenerateLastReply == nil || isBlocked)
    Button("Edit and Resend Last Prompt") { chat?.editLastPrompt?() }
      .disabled(chat?.editLastPrompt == nil || isBlocked)
    Button("Last Reply Info") { chat?.lastReplyInfo?() }
      .disabled(chat?.lastReplyInfo == nil || isBlocked)
    Button("Delete Last Message…") { chat?.deleteLastMessage?() }
      .disabled(chat?.deleteLastMessage == nil || isBlocked)
    Divider()
    Button("Rename") { chat?.rename() }
      .keyboardShortcut("r", modifiers: [.command, .shift])
      .disabled(isBlocked)
    Button("Chat Settings…") { chat?.showSettings() }
      .keyboardShortcut(",", modifiers: [.command, .option])
      .disabled(isBlocked)
  }
}
