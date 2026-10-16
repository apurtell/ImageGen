import SwiftUI
import UIKit

/// In-place title editing (chat list rows and the chat screen's navigation title). Return or ✓
/// saves, ✕ or losing focus cancels; the text starts fully selected.
enum TitleEdit {
  /// The name to rename to, or nil when the edit changes nothing. An empty name is returned as
  /// "", which reverts to the automatic title (D§3.3).
  static func change(draft: String, current: String) -> String? {
    let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed == current ? nil : trimmed
  }
}

struct InlineTitleField: View {
  @Binding var text: String
  var font: UIFont = .preferredFont(forTextStyle: .headline)
  let onSave: () -> Void
  let onCancel: () -> Void

  var body: some View {
    HStack(spacing: 6) {
      AutoFocusTextField(text: $text, font: font, onReturn: onSave, onEndEditing: onCancel)
        .accessibilityLabel("Chat title")
      Button(action: onCancel) {
        Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Cancel rename")
      Button(action: onSave) {
        Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(.tint)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Save title")
    }
  }
}

/// A `UITextField` that becomes first responder and selects all when it enters a window.
/// SwiftUI's `@FocusState` doesn't reach a field hosted in the navigation bar on iOS 26.
struct AutoFocusTextField: UIViewRepresentable {
  @Binding var text: String
  var font: UIFont
  let onReturn: () -> Void
  /// Editing ended without Return (focus moved away, or the field was removed).
  let onEndEditing: () -> Void

  func makeUIView(context: Context) -> FocusingTextField {
    let field = FocusingTextField()
    field.text = text
    field.font = font
    field.adjustsFontForContentSizeCategory = true
    field.returnKeyType = .done
    field.autocapitalizationType = .sentences
    field.placeholder = "Automatic title"
    field.delegate = context.coordinator
    field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
    field.setContentHuggingPriority(.defaultLow, for: .horizontal)
    field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return field
  }

  func updateUIView(_ field: FocusingTextField, context: Context) {
    context.coordinator.parent = self
    if field.text != text { field.text = text }
  }

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  final class Coordinator: NSObject, UITextFieldDelegate {
    var parent: AutoFocusTextField
    private var returned = false

    init(_ parent: AutoFocusTextField) { self.parent = parent }

    @objc func changed(_ field: UITextField) { parent.text = field.text ?? "" }

    func textFieldShouldReturn(_ field: UITextField) -> Bool {
      returned = true
      parent.onReturn()
      return false
    }

    func textFieldDidEndEditing(_ field: UITextField) {
      if !returned { parent.onEndEditing() }
    }
  }
}

final class FocusingTextField: UITextField {
  private var didFocus = false

  override func didMoveToWindow() {
    super.didMoveToWindow()
    guard window != nil, !didFocus else { return }
    didFocus = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.becomeFirstResponder()
      self.selectAll(nil)
    }
  }
}
