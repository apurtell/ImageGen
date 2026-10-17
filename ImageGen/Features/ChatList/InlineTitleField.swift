import SwiftUI
import UIKit

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

/// UIKit text field representable providing immediate first responder acquisition and full text selection upon attachment,
/// bridging platform focus behaviors where SwiftUI focus wrappers cannot address navigation bar hierarchies.
struct AutoFocusTextField: UIViewRepresentable {
  @Binding var text: String
  var font: UIFont
  let onReturn: () -> Void
  /// Callback invoked when text input finishes without explicit Return key submission.
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
    // Permit horizontal compression and expansion to fill available space beside inline action buttons.
    field.setContentHuggingPriority(.defaultLow, for: .horizontal)
    field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return field
  }

  func updateUIView(_ field: FocusingTextField, context: Context) {
    // Synchronize parent view references and apply text mutations only when values differ to preserve cursor offset.
    context.coordinator.parent = self
    if field.text != text { field.text = text }
  }

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  /// Delegate coordinator bridging UIKit text field event targets and selection lifecycles to SwiftUI bindings.
  final class Coordinator: NSObject, UITextFieldDelegate {
    var parent: AutoFocusTextField
    /// Distinguishes explicit Return key submissions from focus abandonment dismissals.
    private var returned = false

    init(_ parent: AutoFocusTextField) { self.parent = parent }

    /// Propagates text input modifications into the bound string state.
    @objc func changed(_ field: UITextField) { parent.text = field.text ?? "" }

    func textFieldShouldReturn(_ field: UITextField) -> Bool {
      returned = true
      parent.onReturn()
      // Prevent insertion of newline characters into single-line title fields.
      return false
    }

    /// Dispatches cancellation when the text field forfeits first responder status without explicit Return submission.
    func textFieldDidEndEditing(_ field: UITextField) {
      if !returned { parent.onEndEditing() }
    }
  }
}

/// Specialization of `UITextField` that acquires first responder status and highlights initial contents upon presentation.
final class FocusingTextField: UITextField {
  /// Guards first responder acquisition to occur strictly upon initial window attachment.
  private var didFocus = false

  override func didMoveToWindow() {
    super.didMoveToWindow()
    guard window != nil, !didFocus else { return }
    didFocus = true
    // Defer first responder activation to the subsequent runloop cycle to allow navigation bar layout stabilization.
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.becomeFirstResponder()
      self.selectAll(nil)
    }
  }
}
