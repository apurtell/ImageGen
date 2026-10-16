import SwiftUI

/// One chat in the list (D§3.3): thumbnail, title, last prompt, time, and status.
struct ChatRow: View {
  /// The title edited in place, replacing the title and time while it's set.
  struct TitleEditing {
    var text: Binding<String>
    var onSave: () -> Void
    var onCancel: () -> Void
  }

  let conversation: Conversation
  var titleEditing: TitleEditing?

  private var messages: [Message] { conversation.messages.sorted { $0.sequence < $1.sequence } }

  private var latestImage: ImageAsset? {
    for m in messages.reversed() {
      if let last = m.orderedImages.last { return last }
    }
    return nil
  }

  private var snippet: String {
    messages.last { $0.messageRole == .user && !$0.text.isEmpty }?.text ?? ""
  }

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
          } else {
            Text(conversation.title).font(.headline).lineLimit(1)
            Spacer(minLength: 4)
            Text(conversation.updatedAt, format: .relative(presentation: .named))
              .font(.caption).foregroundStyle(.secondary)
          }
        }
        HStack {
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
