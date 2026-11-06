import SwiftUI

/// Pure validation and transformation logic governing conversation title rename workflows.
enum TitleEdit {
  /// Evaluates draft text against baseline session title, returning trimmed non-redundant names or nil
  /// when no mutation occurred. An empty draft string yields an empty result to trigger automated title reset.
  static func change(draft: String, current: String) -> String? {
    let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed == current ? nil : trimmed
  }
}

/// Composite editing control embedding auto focusing text input alongside explicit commit and cancel actions.
struct InlineTitleField: View {
  @Binding var text: String
  let onSave: () -> Void
  let onCancel: () -> Void

  var body: some View {
    HStack(spacing: 6) {
      AutoFocusTextField(text: $text, onReturn: onSave, onEndEditing: onCancel)
        .accessibilityLabel("Chat title")
      Button(action: onCancel) {
        Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
      .tooltip("Cancel rename")
      .accessibilityLabel("Cancel rename")
      Button(action: onSave) {
        Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(.tint)
      }
      .buttonStyle(.plain)
      .tooltip("Save title")
      .accessibilityLabel("Save title")
    }
  }
}
