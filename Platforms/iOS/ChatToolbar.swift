import SwiftUI

/// Navigation toolbar layout presenting conversation title controls and action menus on iOS.
struct ChatToolbar: ViewModifier {
  let model: ChatScreenModel
  @Binding var renaming: Bool
  @Binding var showChatSettings: Bool
  @Binding var confirmDeleteChat: Bool

  func body(content: Self.Content) -> some View {
    content
      .inlineNavigationTitle()
      .toolbar {
        ToolbarItem(placement: .principal) {
          // The in-place title edit replaces the title while `model.titleDraft` is non-nil.
          if model.isEditingTitle {
            InlineTitleField(
              text: Binding(get: { model.titleDraft ?? "" }, set: { model.titleDraft = $0 }),
              onSave: { Task { await model.commitTitleEdit() } }, onCancel: { model.cancelTitleEdit() }
            )
            .frame(width: 210)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .glassEffect(.regular.interactive(), in: .capsule)
          } else {
            Text(model.title).font(.headline).lineLimit(1)
              .contentShape(Rectangle())
              .onLongPressGesture(minimumDuration: 0.4) { model.beginTitleEdit() }
              .onTapGesture { renaming = true }
              .accessibilityAddTraits(.isButton)
              .accessibilityLabel("Rename \(model.title)")
              .accessibilityAction(named: "Edit title in place") { model.beginTitleEdit() }
          }
        }
        ToolbarItemGroup(placement: .trailingBar) {
          DeveloperMenu()
          Menu {
            Button("Rename", systemImage: "pencil") { renaming = true }
            Button("Chat settings…", systemImage: "slider.horizontal.3") { showChatSettings = true }
            Button("Delete chat", systemImage: "trash", role: .destructive) { confirmDeleteChat = true }
          } label: {
            Image(systemName: "ellipsis.circle")
          }
          .accessibilityLabel("Chat menu")
        }
      }
  }
}
