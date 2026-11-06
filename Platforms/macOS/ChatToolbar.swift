import SwiftUI

/// Window toolbar modifier binding conversation title and contextual management actions on macOS.
struct ChatToolbar: ViewModifier {
  let model: ChatScreenModel
  @Binding var renaming: Bool
  @Binding var showChatSettings: Bool
  @Binding var confirmDeleteChat: Bool

  func body(content: Self.Content) -> some View {
    content
      // Substitute title display with inline editing field when active.
      .navigationTitle(model.isEditingTitle ? "" : model.title)
      .onChange(of: model.title, initial: true) { _, title in model.services.navigator.chatTitle = title }
      .toolbar {
        if model.isEditingTitle {
          ToolbarItem(placement: .principal) {
            InlineTitleField(
              text: Binding(get: { model.titleDraft ?? "" }, set: { model.titleDraft = $0 }),
              onSave: { Task { await model.commitTitleEdit() } }, onCancel: { model.cancelTitleEdit() }
            )
            .frame(width: 260)
          }
        }
        ToolbarItemGroup(placement: .trailingBar) {
          Button("Rename", systemImage: "pencil") { model.beginTitleEdit() }
            .help("Rename this chat")
          Button("Chat Settings", systemImage: "slider.horizontal.3") { showChatSettings = true }
            .help("Change the model, aspect ratio and resolution for this chat")
          Button("Delete Chat", systemImage: "trash") { confirmDeleteChat = true }
            .help("Delete this chat and its images")
        }
      }
  }
}
