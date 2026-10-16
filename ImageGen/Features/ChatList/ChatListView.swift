import SwiftData
import SwiftUI

/// The chat list (D§3.3).
struct ChatListView: View {
  @Environment(AppEnvironment.self) private var env
  @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]
  @State private var renaming: Conversation?
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
            NavigationLink(value: conversation.id) {
              ChatRow(conversation: conversation)
            }
            .swipeActions(edge: .trailing) {
              Button("Delete", role: .destructive) { deleting = conversation }
            }
            .swipeActions(edge: .leading) {
              Button("Rename") { renaming = conversation }.tint(.indigo)
            }
            .contextMenu {
              Button("Rename", systemImage: "pencil") { renaming = conversation }
              Button("Delete", systemImage: "trash", role: .destructive) { deleting = conversation }
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
    .renameAlert(
      isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }),
      currentTitle: renaming?.title ?? ""
    ) { name in
      if let id = renaming?.id { Task { await env.chatActions.rename(id, to: name) } }
    }
  }

  static func deleteTitle(_ conversation: Conversation) -> String {
    let count = conversation.messages.reduce(0) { $0 + $1.images.count }
    return count == 0 ? "Delete this chat?" : "Delete chat and its \(count) image\(count == 1 ? "" : "s")?"
  }

  private func newChat() async {
    if let id = await env.chatActions.newChat() { env.navigator.open(id) }
  }
}
