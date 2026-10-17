import SwiftUI

/// List cell presenting conversational session summaries, including latest generated thumbnail,
/// editable title, relative timestamp, recent prompt snippet, and active request status indicators.
struct ChatRow: View {
  /// Configuration encapsulation for active inline title editing bindings and completion handlers.
  struct TitleEditing {
    var text: Binding<String>
    var onSave: () -> Void
    var onCancel: () -> Void
  }

  let conversation: Conversation
  /// Optional inline editing state populated when the row is actively undergoing title modifications.
  var titleEditing: TitleEditing?
  @Environment(\.dynamicTypeSize) private var typeSize

  /// Conversation messages ordered deterministically by chronological sequence index.
  private var messages: [Message] { conversation.messages.sorted { $0.sequence < $1.sequence } }

  /// Most recent visual asset across prompt attachments and generated replies.
  private var latestImage: ImageAsset? {
    for m in messages.reversed() {
      if let last = m.orderedImages.last { return last }
    }
    return nil
  }

  /// Textual preview of the most recent user prompt in the conversation.
  private var snippet: String {
    messages.last { $0.messageRole == .user && !$0.text.isEmpty }?.text ?? ""
  }

  /// Lifecycle status derived from the conversation's most recent generation request.
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
            // Stack timestamp beneath title during accessibility Dynamic Type sizes to avoid truncation.
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
          // Non-empty whitespace preserves vertical line height metrics when prompt snippets are absent.
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
