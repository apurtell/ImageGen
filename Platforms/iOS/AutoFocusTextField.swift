import SwiftUI
import UIKit

/// Single-line title field that takes focus and selects all text when presented.
///
/// Uses UITextField directly because SwiftUI's focus bindings cannot reliably focus and select
/// text inside iOS navigation bars.
struct AutoFocusTextField: UIViewRepresentable {
  @Binding var text: String
  let onReturn: () -> Void
  /// Called when editing ends without pressing Return (such as tapping outside).
  let onEndEditing: () -> Void

  func makeUIView(context: Context) -> FocusingTextField {
    let field = FocusingTextField()
    field.text = text
    field.font = .preferredFont(forTextStyle: .headline)
    field.adjustsFontForContentSizeCategory = true
    field.returnKeyType = .done
    field.autocapitalizationType = .sentences
    field.placeholder = "Automatic title"
    field.delegate = context.coordinator
    field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
    // Allow the field to shrink or expand beside the inline save and cancel buttons.
    field.setContentHuggingPriority(.defaultLow, for: .horizontal)
    field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return field
  }

  func updateUIView(_ field: FocusingTextField, context: Context) {
    // Update the text only when changed to avoid resetting the cursor position.
    context.coordinator.parent = self
    if field.text != text { field.text = text }
  }

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  /// Handles text editing and Return key delegate callbacks.
  final class Coordinator: NSObject, UITextFieldDelegate {
    var parent: AutoFocusTextField
    /// Tracks whether the field was committed with Return rather than losing focus.
    private var returned = false

    init(_ parent: AutoFocusTextField) { self.parent = parent }

    /// Updates the bound string as the user types.
    @objc func changed(_ field: UITextField) { parent.text = field.text ?? "" }

    func textFieldShouldReturn(_ field: UITextField) -> Bool {
      returned = true
      parent.onReturn()
      // Single-line field; do not insert newlines.
      return false
    }

    /// Notifies the parent if focus was lost without pressing Return.
    func textFieldDidEndEditing(_ field: UITextField) {
      if !returned { parent.onEndEditing() }
    }
  }
}

/// A text field that automatically becomes first responder and selects all text when added to a window.
final class FocusingTextField: UITextField {
  /// Ensures auto-focus happens only once when first attached to the window.
  private var didFocus = false

  override func didMoveToWindow() {
    super.didMoveToWindow()
    guard window != nil, !didFocus else { return }
    didFocus = true
    // Wait for the navigation bar layout to settle before requesting focus.
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.becomeFirstResponder()
      self.selectAll(nil)
    }
  }
}
