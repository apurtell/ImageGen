import AppKit
import SwiftUI

/// AppKit-backed single-line text input field acquiring immediate first responder status and full text selection upon presentation.
///
/// Directly manages window first responder state to prevent competing focus assertions during menu dismissals or parent transitions.
struct AutoFocusTextField: NSViewRepresentable {
  @Binding var text: String
  let onReturn: () -> Void
  /// Invoked upon cancellation via escape or focus abandonment without explicit submission.
  let onEndEditing: () -> Void

  @Environment(Navigator.self) private var navigator

  func makeNSView(context: Context) -> FocusingTextField {
    let field = FocusingTextField(string: text)
    field.placeholderString = "Automatic title"
    field.font = .preferredFont(forTextStyle: .headline)
    field.isBordered = false
    field.isBezeled = false
    field.drawsBackground = false
    field.focusRingType = .none
    field.lineBreakMode = .byTruncatingTail
    field.usesSingleLineMode = true
    field.setContentHuggingPriority(.defaultLow, for: .horizontal)
    field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    field.delegate = context.coordinator
    return field
  }

  func updateNSView(_ field: FocusingTextField, context: Context) {
    context.coordinator.parent = self
    if field.stringValue != text { field.stringValue = text }
  }

  /// Invalidates delegate callbacks when the view is dismantled to prevent stale updates across recycled rows.
  static func dismantleNSView(_ field: FocusingTextField, coordinator: Coordinator) {
    coordinator.finished = true
    field.delegate = nil
  }

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  /// Bridges AppKit control text notifications and key command selectors to SwiftUI state bindings.
  @MainActor
  final class Coordinator: NSObject, NSTextFieldDelegate {
    var parent: AutoFocusTextField
    /// Guard flag ensuring terminal editing actions execute at most once.
    var finished = false

    init(_ parent: AutoFocusTextField) { self.parent = parent }

    func controlTextDidChange(_ note: Notification) {
      if let field = note.object as? NSTextField { parent.text = field.stringValue }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
      switch selector {
      case #selector(NSResponder.insertNewline(_:)):
        end(parent.onReturn)
      case #selector(NSResponder.cancelOperation(_:)):
        end(parent.onEndEditing)
      default:
        return false
      }
      return true
    }

    private func end(_ action: () -> Void) {
      guard !finished else { return }
      finished = true
      action()
      // Restore keyboard focus to conversation prompt input upon completing inline editing.
      parent.navigator.requestComposerFocus()
    }

    func controlTextDidEndEditing(_ note: Notification) {
      // Suppress premature cancellation notifications during initial focus assertion retries.
      guard !finished, (note.object as? FocusingTextField)?.isClaimingFocus != true else { return }
      finished = true
      parent.onEndEditing()
    }
  }
}

/// NSTextField subclass asserting first responder status across window attachment and view configuration cycles.
final class FocusingTextField: NSTextField {
  /// Retry intervals applied when acquiring window first responder status.
  private static let claimDelays: [Duration] = [.milliseconds(60), .milliseconds(120), .milliseconds(220)]
  private(set) var isClaimingFocus = false

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard window != nil, !isClaimingFocus else { return }
    isClaimingFocus = true
    Task { @MainActor [weak self] in
      await Task.yield()
      self?.claimFocus()
      for delay in Self.claimDelays {
        try? await Task.sleep(for: delay)
        self?.claimFocus()
      }
      self?.isClaimingFocus = false
    }
  }

  private func claimFocus() {
    guard let window, currentEditor() == nil || window.firstResponder !== currentEditor() else { return }
    selectText(nil)
  }
}
