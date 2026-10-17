import SwiftData
import SwiftUI

/// The chat list (D§3.3): the app's root screen, inside the navigator's `NavigationStack`.
///
/// The list reads records straight from SwiftData with `@Query`, and it sends every change (new chat,
/// rename, delete) to `ChatActions`, which writes through `DataStore`. The view never saves records
/// itself. When `DataStore` saves on its own context, SwiftData merges the change into the main context
/// and `@Query` refreshes the list (D§4.2).
///
/// Concurrency: a SwiftUI view runs on the main actor. The only asynchronous work here is the calls to
/// `ChatActions`, each in its own unstructured `Task`. The view does not wait for them; the list
/// updates when the saved change reaches `@Query`.
struct ChatListView: View {
  @Environment(AppEnvironment.self) private var env
  /// `@Query` is a property wrapper that fetches records from the main `ModelContext` and fetches again
  /// when they change, so `body` always sees the current list, newest first. The `Conversation`
  /// objects belong to the main context; they stay on the main actor (see the primer, *SwiftData*).
  @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]
  /// The chat whose title is being edited in place, and the text so far. At most one row edits at a
  /// time. `@State` keeps these values while SwiftUI calls `body` again.
  @State private var editingID: UUID?
  @State private var titleDraft = ""
  /// The title when editing began (an untouched draft changes nothing, even after an auto-title).
  /// The comparison is with this value, not with the live title: an automatic title can arrive while
  /// the field is open, and an untouched draft must not overwrite it.
  @State private var titleAtEditStart = ""
  /// The chat that the Delete alert asks about. The alert shows while this is non-nil.
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
                // The link carries only the chat's ID. The destination in `RootView` builds the chat
                // screen from the ID, so no record object travels through the navigation path.
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
          }
        }
        .listStyle(.plain)
        // An alert, not a row-anchored confirmation dialog: a dialog attached to a row never
        // presented after the row's swipe action (iOS 26.5). So the alert is attached to the whole
        // list, once, and `deleting` says which chat it is about. (D§3.3 still says "anchored to the
        // row"; this alert replaces that dialog.)
        .alert(
          deleting.map(Self.deleteTitle) ?? "",
          // A hand-made binding: the alert shows while `deleting` is set, and closing it clears it.
          isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
        ) {
          Button("Delete", role: .destructive) {
            // Only the ID goes into the task. The record object stays on the main actor, and the
            // delete is done by `DataStore` on its own context.
            if let id = deleting?.id { Task { await env.chatActions.deleteChat(id) } }
          }
          Button("Cancel", role: .cancel) {}
        } message: {
          Text("This can't be undone.")
        }
      }
    }
    // A selection haptic when an in-place edit starts (the ID becomes non-nil), not when it ends.
    .sensoryFeedback(.selection, trigger: editingID) { _, id in id != nil }
    .navigationTitle("Chats")
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        Button("Settings", systemImage: "gearshape") { env.navigator.showSettings = true }
          .accessibilityLabel("Settings")
      }
      // The Developer menu comes before New Chat, so New Chat stays the trailing-most item (D§3.3).
      ToolbarItemGroup(placement: .topBarTrailing) {
        DeveloperMenu()
        Button("New Chat", systemImage: "square.and.pencil") { Task { await newChat() } }
          .accessibilityLabel("New Chat")
      }
    }
  }

  // MARK: In-place rename

  /// Starts an in-place edit of one row (long-press, the leading swipe, or the VoiceOver action).
  /// The draft starts as the current title.
  private func beginTitle(_ conversation: Conversation) {
    titleDraft = conversation.title
    titleAtEditStart = conversation.title
    editingID = conversation.id
  }

  /// Return or ✓. The edit closes at once; the rename itself runs later in `ChatActions`.
  private func saveTitle(_ conversation: Conversation) {
    // A late callback, from a row that no longer edits, must not save a draft that belongs to
    // another row or to an edit that already closed.
    guard editingID == conversation.id else { return }
    editingID = nil
    guard let name = TitleEdit.change(draft: titleDraft, current: titleAtEditStart) else { return }
    // Captured before the task, so the task holds a plain `UUID`, not the record object.
    let id = conversation.id
    Task { await env.chatActions.rename(id, to: name) }
  }

  /// ✕, or the field lost focus without Return.
  private func cancelTitle() {
    editingID = nil
  }

  /// "Delete chat and its N images?", or "Delete this chat?" when it has none (D§3.3).
  static func deleteTitle(_ conversation: Conversation) -> String {
    let count = conversation.messages.reduce(0) { $0 + $1.images.count }
    return count == 0 ? "Delete this chat?" : "Delete chat and its \(count) image\(count == 1 ? "" : "s")?"
  }

  /// Creates an empty chat and pushes it. `newChat()` returns nil when the store could not create the
  /// chat (it logs the failure); then the list stays as it is.
  private func newChat() async {
    if let id = await env.chatActions.newChat() { env.navigator.open(id) }
  }
}
