import SwiftUI

/// Conversation list container view rendering plain vertical list styling on iOS.
struct ChatListContainer<Content: View>: View {
  /// Deletion callback.
  /// Unused on iOS in favor of native trailing swipe actions.
  let onDelete: (UUID) -> Void
  @ViewBuilder let content: Content

  var body: some View {
    List { content }
      .listStyle(.plain)
  }
}

/// Navigation link wrapper binding conversation identifiers to navigation routes.
struct ChatListLink<Label: View>: View {
  let id: UUID
  @ViewBuilder let label: Label

  var body: some View {
    NavigationLink(value: id) { label }
  }
}

/// Displays relative modification timestamp for a conversation row.
struct ChatRowTimestamp: View {
  let date: Date

  var body: some View {
    Text(date, format: .relative(presentation: .named))
      .font(.caption).foregroundStyle(.secondary)
  }
}

extension View {
  /// Attaches gesture recognizers and accessibility actions for conversation renaming.
  func chatRowGestures(rename: @escaping () -> Void, delete: @escaping () -> Void) -> some View {
    simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in rename() })
      .accessibilityAction(named: "Rename") { rename() }
  }

  /// No-op modifier on iOS. Inline editing dismissal is handled by dedicated row controls.
  func endsRowEditing(whenSelectionChanges navigator: Navigator, action: @escaping () -> Void) -> some View { self }

  /// Configures navigation bar items for settings, developer tools, and conversation creation.
  func chatListToolbar(newChat: @escaping () -> Void) -> some View {
    modifier(ChatListToolbar(newChat: newChat))
  }
}

private struct ChatListToolbar: ViewModifier {
  @Environment(AppEnvironment.self) private var env
  let newChat: () -> Void

  func body(content: Self.Content) -> some View {
    content.toolbar {
      ToolbarItem(placement: .leadingBar) {
        Button("Settings", systemImage: "gearshape") { env.navigator.showSettings = true }
          .accessibilityLabel("Settings")
      }
      // Retain New Chat as the trailing navigation bar item for primary visual prominence.
      ToolbarItemGroup(placement: .trailingBar) {
        DeveloperMenu()
        Button("New Chat", systemImage: "square.and.pencil", action: newChat)
          .accessibilityLabel("New Chat")
      }
    }
  }
}
