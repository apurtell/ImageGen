import SwiftUI

/// System menu commands and hardware keyboard shortcuts supported on iPad.
struct PadCommands: Commands {
  let env: AppEnvironment
  @FocusedValue(\.chatCommands) private var chat

  var body: some Commands {
    CommandGroup(replacing: .appSettings) {
      PadSettingsItem(env: env, chat: chat)
    }
    CommandGroup(replacing: .newItem) {
      PadNewChatItems(env: env, chat: chat)
    }
    CommandGroup(after: .toolbar) {
      PadJumpItem(navigator: env.navigator, chat: chat)
    }
    CommandMenu("Chat") { PadChatItems(navigator: env.navigator, chat: chat) }
  }
}

// Embedded as views within command groups to observe dynamic Navigator state updates.

/// Application settings menu item presentation and keyboard shortcuts.
private struct PadSettingsItem: View {
  let env: AppEnvironment
  let chat: ChatCommandHandle?

  var body: some View {
    Button("Settings…") { env.navigator.openSettings() }
      .keyboardShortcut(",")
      .disabled(env.navigator.needsOnboarding || env.navigator.isChatCovered || chat?.isPresenting == true)
  }
}

/// File management commands for conversation creation and deletion.
private struct PadNewChatItems: View {
  let env: AppEnvironment
  let chat: ChatCommandHandle?

  private var isBlocked: Bool { env.navigator.isChatCovered || chat?.isPresenting == true }

  var body: some View {
    Button("New Chat") {
      Task {
        guard let id = await env.chatActions.newChat() else { return }
        env.navigator.open(id)
        env.navigator.requestComposerFocus(for: id)
      }
    }
    .keyboardShortcut("n")
    .disabled(env.navigator.needsOnboarding || isBlocked)
    Divider()
    Button("Delete Chat…") { chat?.delete() }
      .keyboardShortcut(.delete, modifiers: [.command, .option])
      .disabled(chat == nil || isBlocked)
  }
}

/// View > Jump to Latest.
private struct PadJumpItem: View {
  let navigator: Navigator
  let chat: ChatCommandHandle?

  var body: some View {
    Button("Jump to Latest") { chat?.jumpToLatest() }
      .keyboardShortcut(.downArrow, modifiers: [.command, .option])
      .disabled(chat?.canJumpToLatest != true || navigator.isChatCovered)
  }
}

/// The Chat menu, with no chat to act on while another presentation covers it.
private struct PadChatItems: View {
  let navigator: Navigator
  let chat: ChatCommandHandle?

  var body: some View { ChatItems(chat: navigator.isChatCovered ? nil : chat) }
}
