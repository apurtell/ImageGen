import SwiftUI

/// The Rename alert, shared by the chat list and the chat screen (D§3.3). An empty name reverts
/// to the automatic title.
struct RenameAlert: ViewModifier {
  @Binding var isPresented: Bool
  let currentTitle: String
  let onRename: (String) -> Void
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
      .onChange(of: isPresented) { _, shown in if shown { text = currentTitle } }
  }
}

extension View {
  func renameAlert(isPresented: Binding<Bool>, currentTitle: String, onRename: @escaping (String) -> Void) -> some View {
    modifier(RenameAlert(isPresented: isPresented, currentTitle: currentTitle, onRename: onRename))
  }
}
