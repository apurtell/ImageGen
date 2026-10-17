import SwiftUI

/// One chat in the list (D§3.3): thumbnail, title, last prompt, time, and status.
///
/// A plain view over one `Conversation` record from the list's `@Query`. Everything it shows is
/// computed from the record's relationships each time SwiftUI calls `body`, so the row updates when
/// SwiftData merges a save from `DataStore`. It runs on the main actor and does no asynchronous work
/// itself (`SquareThumbnail` loads the image).
struct ChatRow: View {
  /// The title edited in place, replacing the title and time while it's set.
  /// `ChatListView` owns the draft text; the row gets a two-way `Binding` to it and two callbacks.
  struct TitleEditing {
    var text: Binding<String>
    var onSave: () -> Void
    var onCancel: () -> Void
  }

  let conversation: Conversation
  /// nil for a normal row. Set only for the one row that edits its title.
  var titleEditing: TitleEditing?
  @Environment(\.dynamicTypeSize) private var typeSize

  /// The relationship has no order of its own, so the row sorts by `sequence`.
  private var messages: [Message] { conversation.messages.sorted { $0.sequence < $1.sequence } }

  /// The newest image in the chat, from any message (a reply or an upload).
  private var latestImage: ImageAsset? {
    for m in messages.reversed() {
      if let last = m.orderedImages.last { return last }
    }
    return nil
  }

  /// The last prompt the user typed. Messages with images only are skipped.
  private var snippet: String {
    messages.last { $0.messageRole == .user && !$0.text.isEmpty }?.text ?? ""
  }

  /// From the newest request only: a spinner while it runs, a red dot when it failed or was refused
  /// (`ChatRowStatus.make` holds the rule).
  private var status: ChatRowStatus {
    let latest = conversation.requests.max { $0.createdAt < $1.createdAt }
    return ChatRowStatus.make(latestState: latest?.requestState, errorStatus: latest?.errorStatus)
  }

  var body: some View {
    HStack(spacing: 12) {
      SquareThumbnail(asset: latestImage, size: 44)
      VStack(alignment: .leading, spacing: 2) {
        HStack {
          if let editing = titleEditing {
            InlineTitleField(text: editing.text, onSave: editing.onSave, onCancel: editing.onCancel)
          } else if typeSize.isAccessibilitySize {
            // Title first and whole; the time goes under it rather than squeezing it.
            VStack(alignment: .leading, spacing: 2) {
              Text(conversation.title).font(.headline).lineLimit(2)
              Text(conversation.updatedAt, format: .relative(presentation: .named))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
          } else {
            Text(conversation.title).font(.headline).lineLimit(1)
            Spacer(minLength: 4)
            Text(conversation.updatedAt, format: .relative(presentation: .named))
              .font(.caption).foregroundStyle(.secondary)
          }
        }
        HStack {
          // A space, not "", so the row keeps the height of two lines when there is no prompt yet.
          Text(snippet.isEmpty ? " " : snippet)
            .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
          Spacer(minLength: 4)
          switch status {
          case .inFlight:
            ProgressView().controlSize(.mini).accessibilityLabel("Generating")
          case .needsAttention:
            Circle().fill(.red).frame(width: 9, height: 9).accessibilityLabel("Needs attention")
          case .none:
            EmptyView()
          }
        }
      }
    }
    .padding(.vertical, 2)
  }
}
