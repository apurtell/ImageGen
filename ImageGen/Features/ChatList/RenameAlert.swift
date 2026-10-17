import SwiftUI

/// Modal alert presentation modifier providing dialog based conversation title renaming,
/// allowing reverting to automated title generation via empty submission.
struct RenameAlert: ViewModifier {
  @Binding var isPresented: Bool
  let currentTitle: String
  let onRename: (String) -> Void
  /// Ephemeral draft string bound to the alert's text input field.
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
      // Reinitialize input draft with current conversation title upon alert presentation.
      .onChange(of: isPresented) { _, shown in if shown { text = currentTitle } }
  }
}

extension View {
  /// Attaches a standardized conversation renaming alert modal to the view hierarchy.
  func renameAlert(isPresented: Binding<Bool>, currentTitle: String, onRename: @escaping (String) -> Void) -> some View {
    modifier(RenameAlert(isPresented: isPresented, currentTitle: currentTitle, onRename: onRename))
  }
}
