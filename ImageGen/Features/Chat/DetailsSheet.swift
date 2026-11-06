import SwiftUI

/// Presents sanitized diagnostic payloads or structured error representations in a selectable monospace view.
struct DetailsSheet: View {
  let text: String

  var body: some View {
    SheetScaffold(title: "Details") {
      ScrollView {
        Text(text.isEmpty ? "No details" : text)
          .font(.system(.caption, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding()
      }
    } action: {
      Button("Copy", systemImage: "doc.on.doc") { SystemPasteboard.general.string = text }
        .tooltip("Copy")
        .accessibilityLabel("Copy")
    }
  }
}
