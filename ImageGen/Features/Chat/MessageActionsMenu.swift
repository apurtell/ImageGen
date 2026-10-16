import SwiftUI

/// A message's long-press menu (D§3.6).
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
      Button("Edit & Resend", systemImage: "pencil", action: onEditAndResend)
      Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
    } else {
      if !message.text.isEmpty {
        Button("Copy Text", systemImage: "doc.on.doc") { onCopy(message.text, .replyText) }
      }
      if request != nil {
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
