import SwiftUI
import UIKit

// In-place title editing, shared by the chat list rows (`ChatListView`) and the chat screen's
// navigation title (`ChatView`, `ChatScreenModel`). This file has four small parts:
// - `TitleEdit`: the pure rule that decides whether an edit renames the chat.
// - `InlineTitleField`: the SwiftUI row of text field, ✕ and ✓.
// - `AutoFocusTextField`: a `UIViewRepresentable` that hosts a UIKit `UITextField` inside SwiftUI.
// - `FocusingTextField`: the `UITextField` subclass that takes focus when it appears.
// A UIKit field is used because SwiftUI's `@FocusState` cannot focus a field in the navigation bar on
// iOS 26, and the chat screen's title field is there. Everything here runs on the main thread, like
// all UIKit and SwiftUI view code; there is no other concurrency.

/// In-place title editing (chat list rows and the chat screen's navigation title). Return or ✓
/// saves, ✕ or losing focus cancels; the text starts fully selected.
enum TitleEdit {
  /// The name to rename to, or nil when the edit changes nothing. An empty name is returned as
  /// "", which reverts to the automatic title (D§3.3).
  /// `current` is the title when the edit began, not the live title, so an automatic title that
  /// arrives during the edit is not overwritten by an untouched draft.
  static func change(draft: String, current: String) -> String? {
    let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed == current ? nil : trimmed
  }
}

/// The editing controls: the text field, then ✕ (cancel) and ✓ (save). The caller owns the text
/// and decides what save and cancel do.
struct InlineTitleField: View {
  /// `@Binding` is a two-way reference to text that the caller owns; typing here changes it there.
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
///
/// `UIViewRepresentable` is the bridge from SwiftUI to a UIKit view. SwiftUI calls `makeUIView` once
/// for the view's life, then `updateUIView` each time the SwiftUI struct changes. The `Coordinator`
/// is a long-lived object that receives the UIKit callbacks (delegate and target-action) and forwards
/// them to the latest SwiftUI values.
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
    // Low hugging and compression priorities let the field take the free width beside ✕ and ✓, and
    // shrink first when the row is narrow.
    field.setContentHuggingPriority(.defaultLow, for: .horizontal)
    field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return field
  }

  func updateUIView(_ field: FocusingTextField, context: Context) {
    // The struct is new on each update, so the coordinator gets the latest closures and binding.
    context.coordinator.parent = self
    // Set only when different: setting the same text again would move the cursor and the selection.
    if field.text != text { field.text = text }
  }

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  /// The field's delegate. It inherits from `NSObject` because UIKit delegates and `#selector`
  /// targets are Objective-C APIs.
  final class Coordinator: NSObject, UITextFieldDelegate {
    var parent: AutoFocusTextField
    /// Set by Return. Editing then ends because the caller removes the field, and that end must not
    /// also count as a cancel.
    private var returned = false

    init(_ parent: AutoFocusTextField) { self.parent = parent }

    /// Copies each keystroke into the SwiftUI binding.
    @objc func changed(_ field: UITextField) { parent.text = field.text ?? "" }

    func textFieldShouldReturn(_ field: UITextField) -> Bool {
      returned = true
      parent.onReturn()
      // false: the field does not insert a line break or run its own default action.
      return false
    }

    /// Runs when the field loses focus for any reason: another control took focus, the keyboard was
    /// dismissed, or the field left the window. Each of these is a cancel unless Return came first.
    func textFieldDidEndEditing(_ field: UITextField) {
      if !returned { parent.onEndEditing() }
    }
  }
}

/// A `UITextField` that focuses itself and selects all of its text the first time it enters a
/// window.
final class FocusingTextField: UITextField {
  /// Focus is taken once only, so the field does not take focus back after the user moves it away.
  private var didFocus = false

  override func didMoveToWindow() {
    super.didMoveToWindow()
    guard window != nil, !didFocus else { return }
    didFocus = true
    // Deferred to the next turn of the main queue, after the current layout pass: focus taken in
    // the middle of `didMoveToWindow` is not reliable, for example while the navigation bar lays out.
    // `[weak self]` lets the field go away in the meantime; then the block does nothing.
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.becomeFirstResponder()
      self.selectAll(nil)
    }
  }
}
