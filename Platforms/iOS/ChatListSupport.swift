import SwiftUI

/// Scrollable conversation list container adapting between plain vertical styling in stack layouts and selectable sidebar styling in split layouts.
struct ChatListContainer<Content: View>: View {
  @Environment(\.navigationLayout) private var layout
  @Environment(Navigator.self) private var navigator
  /// Indicates whether an in-place title editing field is currently active.
  let isEditingRow: Bool
  /// Deletion callback triggered for the selected conversation; unused on iOS where swipe actions govern row deletion.
  let onDelete: (UUID) -> Void
  @ViewBuilder let content: Content

  var body: some View {
    switch layout {
    case .stack:
      List { content }
        .listStyle(.plain)
    case .split:
      List(selection: selection) { content }
        .listStyle(.sidebar)
    }
  }

  /// Selection binding projecting active navigator path while preserving selection during list reconstructions.
  private var selection: Binding<UUID?> {
    Binding(
      get: { navigator.path.last },
      set: { if let id = $0 { navigator.path = [id] } })
  }
}

/// Adaptive navigation link projecting hierarchical push transitions in stack layouts and sidebar
/// selection tags in split layouts.
struct ChatListLink<Label: View>: View {
  @Environment(\.navigationLayout) private var layout
  let id: UUID
  @ViewBuilder let label: Label

  var body: some View {
    switch layout {
    case .stack: NavigationLink(value: id) { label }
    case .split: label.tag(id)
    }
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
  /// Attaches contextual menu and gesture handlers for conversation renaming and deletion across
  /// iPhone and iPad form factors.
  @ViewBuilder
  func chatRowGestures(rename: @escaping () -> Void, delete: @escaping () -> Void) -> some View {
    if Platform.isPad {
      contextMenu {
        Button("Rename", systemImage: "pencil") { rename() }
        Divider()
        Button("Delete…", systemImage: "trash", role: .destructive) { delete() }
      }
      .accessibilityAction(named: "Rename") { rename() }
    } else {
      simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in rename() })
        .accessibilityAction(named: "Rename") { rename() }
    }
  }

  /// A rename ends with its own controls on iPhone. On iPad choosing another chat ends it too, as a sidebar row stays on screen.
  @ViewBuilder
  func endsRowEditing(whenSelectionChanges navigator: Navigator, action: @escaping () -> Void) -> some View {
    if Platform.isPad { onChange(of: navigator.path) { _, _ in action() } } else { self }
  }

  /// Settings on the left, the Developer menu and New Chat on the right. In a sidebar the Developer menu is beside the chat.
  func chatListToolbar(newChat: @escaping () -> Void) -> some View {
    modifier(ChatListToolbar(newChat: newChat))
  }
}

private struct ChatListToolbar: ViewModifier {
  @Environment(AppEnvironment.self) private var env
  @Environment(\.navigationLayout) private var layout
  let newChat: () -> Void

  func body(content: Self.Content) -> some View {
    content.toolbar {
      ToolbarItem(placement: .leadingBar) {
        Button("Settings", systemImage: "gearshape") { env.navigator.showSettings = true }
          .accessibilityLabel("Settings")
      }
      // Retain New Chat as the trailing navigation bar item for primary visual prominence.
      ToolbarItemGroup(placement: .trailingBar) {
        if layout == .stack { DeveloperMenu() }
        Button("New Chat", systemImage: "square.and.pencil", action: newChat)
          .accessibilityLabel("New Chat")
      }
    }
  }
}
