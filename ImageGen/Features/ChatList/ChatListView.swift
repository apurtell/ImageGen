import SwiftData
import SwiftUI

/// The chat list (D§3.3).
struct ChatListView: View {
  @Environment(AppEnvironment.self) private var env
  @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]
  /// The chat whose title is being edited in place, and the text so far.
  @State private var editingID: UUID?
  @State private var titleDraft = ""
  @State private var deleting: Conversation?

  var body: some View {
    Group {
      if conversations.isEmpty {
        ContentUnavailableView {
          Label("No chats yet", systemImage: "photo.on.rectangle.angled")
        } description: {
          Text("Describe an image to generate, or attach one to edit.")
        } actions: {
          Button("New Chat") { Task { await newChat() } }
            .buttonStyle(.borderedProminent)
        }
      } else {
        List {
          ForEach(conversations) { conversation in
            Group {
              if editingID == conversation.id {
                // No link while editing, so taps on the field and its buttons don't open the chat.
                ChatRow(
                  conversation: conversation,
                  titleEditing: ChatRow.TitleEditing(
                    text: $titleDraft, onSave: { saveTitle(conversation) }, onCancel: cancelTitle))
              } else {
                NavigationLink(value: conversation.id) {
                  ChatRow(conversation: conversation)
                }
                // Long-press edits the title in place. Simultaneous, so a tap still opens the chat
                // (an exclusive long-press on the label swallowed the link's tap).
                .simultaneousGesture(
                  LongPressGesture(minimumDuration: 0.5).onEnded { _ in beginTitle(conversation) })
                .accessibilityAction(named: "Rename") { beginTitle(conversation) }
              }
            }
            .swipeActions(edge: .trailing) {
              Button("Delete", role: .destructive) { deleting = conversation }
            }
            .swipeActions(edge: .leading) {
              Button("Rename") { beginTitle(conversation) }.tint(.indigo)
            }
            // On the row, so the popover points at the chat being deleted.
            .confirmationDialog(
              Self.deleteTitle(conversation),
              isPresented: Binding(
                get: { deleting?.id == conversation.id }, set: { if !$0 { deleting = nil } }),
              titleVisibility: .visible
            ) {
              Button("Delete", role: .destructive) {
                let id = conversation.id
                Task { await env.chatActions.deleteChat(id) }
              }
            }
          }
        }
        .listStyle(.plain)
      }
    }
    .sensoryFeedback(.selection, trigger: editingID) { _, id in id != nil }
    .navigationTitle("Chats")
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        Button("Settings", systemImage: "gearshape") { env.navigator.showSettings = true }
          .accessibilityLabel("Settings")
      }
      ToolbarItemGroup(placement: .topBarTrailing) {
        DeveloperMenu()
        Button("New Chat", systemImage: "square.and.pencil") { Task { await newChat() } }
          .accessibilityLabel("New Chat")
      }
    }
  }

  // MARK: In-place rename

  private func beginTitle(_ conversation: Conversation) {
    titleDraft = conversation.title
    editingID = conversation.id
  }

  private func saveTitle(_ conversation: Conversation) {
    guard editingID == conversation.id else { return }
    editingID = nil
    guard let name = TitleEdit.change(draft: titleDraft, current: conversation.title) else { return }
    let id = conversation.id
    Task { await env.chatActions.rename(id, to: name) }
  }

  private func cancelTitle() {
    editingID = nil
  }

  static func deleteTitle(_ conversation: Conversation) -> String {
    let count = conversation.messages.reduce(0) { $0 + $1.images.count }
    return count == 0 ? "Delete this chat?" : "Delete chat and its \(count) image\(count == 1 ? "" : "s")?"
  }

  private func newChat() async {
    if let id = await env.chatActions.newChat() { env.navigator.open(id) }
  }
}
