import SwiftUI

/// The Rename alert, shared by the chat list and the chat screen (D§3.3). An empty name reverts
/// to the automatic title.
///
/// A `ViewModifier` packages a reusable set of modifiers; `renameAlert(...)` below applies it. The
/// alert only collects the text. The caller's `onRename` does the rename (through `ChatActions` or
/// the chat screen's model). It runs on the main actor and has no asynchronous work of its own.
/// The chat screen uses it; the chat list now renames in place (`InlineTitleField`).
struct RenameAlert: ViewModifier {
  @Binding var isPresented: Bool
  let currentTitle: String
  let onRename: (String) -> Void
  /// The alert's text field. `@State` keeps it while the alert is open.
  @State private var text = ""

  func body(content: Self.Content) -> some View {
    content
      .alert("Rename Chat", isPresented: $isPresented) {
        TextField("Title", text: $text)
        Button("Cancel", role: .cancel) {}
        Button("Rename") { onRename(text) }
      } message: {
        Text("Leave it empty to use the automatic title.")
      }
      // Each time the alert opens, the field starts with the title at that moment, not the text
      // left over from the last time.
      .onChange(of: isPresented) { _, shown in if shown { text = currentTitle } }
  }
}

extension View {
  /// Adds the Rename alert. `onRename` gets the typed text as is, untrimmed; `DataStore.rename`
  /// trims it.
  func renameAlert(isPresented: Binding<Bool>, currentTitle: String, onRename: @escaping (String) -> Void) -> some View {
    modifier(RenameAlert(isPresented: isPresented, currentTitle: currentTitle, onRename: onRename))
  }
}
