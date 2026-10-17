import SwiftUI

/// A message's long-press menu (D§3.6). A user message offers Copy Prompt, Edit and Resend and
/// Delete; a reply offers Copy Text, Regenerate, Info and Delete. Regenerate, Info and Delete are
/// here for every reply with a request record, whatever its card shows. The menu only reports the
/// choice.
struct MessageActionsMenu: View {
  let message: Message
  let request: GenerationRequest?
  let regenerateUnavailableReason: String?
  let onCopy: (String, ChatScreenModel.CopyKind) -> Void
  let onRegenerate: () -> Void
  let onInfo: () -> Void
  let onEditAndResend: () -> Void
  let onDelete: () -> Void

  var body: some View {
    if message.messageRole == .user {
      if !message.text.isEmpty {
        Button("Copy Prompt", systemImage: "doc.on.doc") { onCopy(message.text, .prompt) }
      }
      // MARK: M6 items
      Button("Edit and Resend", systemImage: "pencil", action: onEditAndResend)
      Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
    } else {
      if !message.text.isEmpty {
        Button("Copy Text", systemImage: "doc.on.doc") { onCopy(message.text, .replyText) }
      }
      if request != nil {
        // A second `Text` in a menu button's label shows as its subtitle: the reason it is disabled.
        Button(action: onRegenerate) {
          Label("Regenerate", systemImage: "arrow.clockwise")
          if let reason = regenerateUnavailableReason { Text(reason) }
        }
        .disabled(regenerateUnavailableReason != nil)
        Button("Info", systemImage: "info.circle", action: onInfo)
      }
      Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
    }
  }
}
