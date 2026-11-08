import AppKit
import SwiftUI

/// Sidebar conversation list container bound to active navigator selection.
struct ChatListContainer<Content: View>: View {
  @Environment(Navigator.self) private var navigator
  /// Indicates whether a list row is currently undergoing in-place title editing.
  let isEditingRow: Bool
  /// Deletion handler invoked when the active selection is deleted via keyboard shortcut.
  let onDelete: (UUID) -> Void
  @ViewBuilder let content: Content

  var body: some View {
    List(selection: selection) { content }
      .listStyle(.sidebar)
      .onDeleteCommand {
        if let id = navigator.path.last { onDelete(id) }
      }
      // Transfer keyboard focus to conversation prompt when Return is pressed on list view selection.
      .onKeyPress(.return) {
        // Suppress navigation if an active text field currently owns first responder.
        guard navigator.path.last != nil, NSApp.keyWindow?.firstResponder is NSTableView else { return .ignored }
        navigator.requestComposerFocus()
        return .handled
      }
      .background(EventMonitor(mask: .keyDown, handler: forwardTyping))
  }

  /// Forwards printable key events from the sidebar to the composer text view prior to dispatch,
  /// ensuring characters and multi-keystroke input method sequences are processed naturally through NSTextInputContext.
  private func forwardTyping(_ event: NSEvent) -> Bool {
    guard let window = event.window else { return false }
    let press = SidebarKeyRouting.Press(
      characters: event.characters ?? "", charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
      command: event.modifierFlags.contains(.command), control: event.modifierFlags.contains(.control),
      function: event.modifierFlags.contains(.function))
    let situation = SidebarKeyRouting.Situation(
      listHasKeyboard: window.firstResponder is NSTableView, chatIsOpen: navigator.path.last != nil,
      isEditingRow: isEditingRow, isSheetUp: window.attachedSheet != nil)
    if SidebarKeyRouting.forwardsToComposer(press, in: situation) { ComposerFieldAnchorView.takeKeyboard(in: window) }
    return false
  }

  /// Value binding projecting active conversation selection while ignoring transient deselection events.
  private var selection: Binding<UUID?> {
    Binding(
      get: { navigator.path.last },
      set: { if let id = $0 { navigator.path = [id] } })
  }
}

/// Tagged conversation row element supporting sidebar list selection.
struct ChatListLink<Label: View>: View {
  let id: UUID
  @ViewBuilder let label: Label

  var body: some View {
    label.tag(id)
  }
}

/// Periodically refreshed relative timestamp formatted for compact sidebar display.
struct ChatRowTimestamp: View {
  let date: Date

  var body: some View {
    TimelineView(.periodic(from: .now, by: 30)) { context in
      Text(context.date.timeIntervalSince(date) < 60 ? "now" : date.formatted(.relative(presentation: .numeric, unitsStyle: .narrow)))
        .font(Platform.chatRowDateFont).foregroundStyle(.secondary).lineLimit(1)
    }
    .fixedSize()
  }
}

extension View {
  /// Attaches contextual menu commands for renaming and deletion to sidebar conversation rows.
  func chatRowGestures(rename: @escaping () -> Void, delete: @escaping () -> Void) -> some View {
    contextMenu {
      Button("Rename", systemImage: "pencil") { rename() }
      Divider()
      Button("Delete…", systemImage: "trash", role: .destructive) { delete() }
    }
  }

  /// Cancels active row title editing when navigation selection changes.
  func endsRowEditing(whenSelectionChanges navigator: Navigator, action: @escaping () -> Void) -> some View {
    onChange(of: navigator.path) { _, _ in action() }
  }

  /// Configures primary sidebar toolbar items on macOS.
  func chatListToolbar(newChat: @escaping () -> Void) -> some View {
    toolbar {
      ToolbarItem(placement: .trailingBar) {
        Button("New Chat", systemImage: "square.and.pencil", action: newChat)
          .help("Start a new chat")
      }
    }
  }
}
