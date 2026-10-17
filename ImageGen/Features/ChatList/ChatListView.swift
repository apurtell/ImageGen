import SwiftData
import SwiftUI

/// Root conversation navigation interface displaying persistent chat sessions ordered chronologically,
/// supporting in-place title editing, destructive deletion workflows, and conversation initialization.
///
/// Query results synchronize reactively with background persistence updates through SwiftData
/// model context change propagation, isolating the presentation layer from transaction coordination.
struct ChatListView: View {
  @Environment(AppEnvironment.self) private var env
  /// Automatically refreshed query tracking all persisted conversations, sorted by update timestamp descending.
  @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]
  /// Tracks the identifier and ephemeral draft string of the conversation currently undergoing in-place title editing.
  @State private var editingID: UUID?
  @State private var titleDraft = ""
  /// Captures title state at the onset of inline editing to prevent overwriting asynchronous background auto-titling updates.
  @State private var titleAtEditStart = ""
  /// Target conversation referenced by active deletion confirmation alerts.
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
          // Leading standalone action row duplicating the primary creation trigger from the navigation bar.
          NewChatRow { Task { await newChat() } }
          ForEach(conversations) { conversation in
            Group {
              if editingID == conversation.id {
                // Suppress navigation destination link while active in-place editing is occurring.
                ChatRow(
                  conversation: conversation,
                  titleEditing: ChatRow.TitleEditing(
                    text: $titleDraft, onSave: { saveTitle(conversation) }, onCancel: cancelTitle))
              } else {
                // Pass conversation identifier to destination builder to preserve value semantic navigation routes.
                NavigationLink(value: conversation.id) {
                  ChatRow(conversation: conversation)
                }
                // Enable in-place editing on long press while allowing standard tap gestures to proceed to navigation.
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
          }
        }
        .listStyle(.plain)
        // List-anchored confirmation alert presenting deletion warnings for the selected conversation.
        .alert(
          deleting.map(Self.deleteTitle) ?? "",
          // Bidirectional binding deriving alert visibility from conversation selection state.
          isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
        ) {
          Button("Delete", role: .destructive) {
            // Dispatch deletion asynchronously by identifier across persistence worker contexts.
            if let id = deleting?.id { Task { await env.chatActions.deleteChat(id) } }
          }
          Button("Cancel", role: .cancel) {}
        } message: {
          Text("This can't be undone.")
        }
      }
    }
    // Emit selection haptic feedback upon initiating in-place title editing.
    .sensoryFeedback(.selection, trigger: editingID) { _, id in id != nil }
    .navigationTitle("Chats")
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        Button("Settings", systemImage: "gearshape") { env.navigator.showSettings = true }
          .accessibilityLabel("Settings")
      }
      // Retain New Chat as the trailing navigation bar item for primary visual prominence.
      ToolbarItemGroup(placement: .topBarTrailing) {
        DeveloperMenu()
        Button("New Chat", systemImage: "square.and.pencil") { Task { await newChat() } }
          .accessibilityLabel("New Chat")
      }
    }
  }

  /// Initiates inline title editing for the specified conversation across gesture or accessibility triggers.
  private func beginTitle(_ conversation: Conversation) {
    titleDraft = conversation.title
    titleAtEditStart = conversation.title
    editingID = conversation.id
  }

  /// Commits edited title drafts, validating text modifications before asynchronously dispatching update actions.
  private func saveTitle(_ conversation: Conversation) {
    // Guard against stale invocation callbacks if active editing state has already transitioned.
    guard editingID == conversation.id else { return }
    editingID = nil
    guard let name = TitleEdit.change(draft: titleDraft, current: titleAtEditStart) else { return }
    // Capture identifier value semantics to decouple asynchronous persistence tasks from model instances.
    let id = conversation.id
    Task { await env.chatActions.rename(id, to: name) }
  }

  /// Dismisses inline editing mode without persisting pending draft changes.
  private func cancelTitle() {
    editingID = nil
  }

  /// Formulates localized confirmation prompts detailing associated image counts slated for cascade deletion.
  static func deleteTitle(_ conversation: Conversation) -> String {
    let count = conversation.messages.reduce(0) { $0 + $1.images.count }
    return count == 0 ? "Delete this chat?" : "Delete chat and its \(count) image\(count == 1 ? "" : "s")?"
  }

  /// Initializes a new conversational session and navigates immediately to its transcript upon creation.
  private func newChat() async {
    if let id = await env.chatActions.newChat() { env.navigator.open(id) }
  }
}

/// Dedicated creation button formatted as a list row, visually aligning with conversation cells.
private struct NewChatRow: View {
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 12) {
        RoundedRectangle(cornerRadius: 8)
          .fill(.tint.opacity(0.15))
          .frame(width: 44, height: 44)
          .overlay(Image(systemName: "square.and.pencil").font(.title3).foregroundStyle(.tint))
          // Visual glyph decorative; accessible text label provides complete context.
          .accessibilityHidden(true)
        Text("New Chat").font(.headline).foregroundStyle(.tint)
        Spacer(minLength: 0)
      }
      // Expand hit test boundary across the entire row surface.
      .contentShape(Rectangle())
    }
  }
}
