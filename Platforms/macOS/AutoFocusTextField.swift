import SwiftUI

/// Single-line title field that takes focus with its text selected when it appears, submits on
/// Return and reports losing focus without a submission.
struct AutoFocusTextField: View {
  @Binding var text: String
  let onReturn: () -> Void
  /// Called when focus leaves the field without pressing Return.
  let onEndEditing: () -> Void

  @FocusState private var focused: Bool
  @State private var returned = false

  var body: some View {
    TextField("Automatic title", text: $text)
      .textFieldStyle(.plain)
      .font(.headline)
      .focused($focused)
      .onSubmit {
        returned = true
        onReturn()
      }
      .onAppear {
        focused = true
        DispatchQueue.main.async { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) }
      }
      .onChange(of: focused) { _, now in
        if !now && !returned { onEndEditing() }
      }
  }
}
