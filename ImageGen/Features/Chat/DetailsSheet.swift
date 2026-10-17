import SwiftUI
import UIKit

/// Presents sanitized diagnostic payloads or structured error representations in a selectable monospace view.
struct DetailsSheet: View {
  let text: String
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      ScrollView {
        Text(text.isEmpty ? "No details" : text)
          .font(.system(.caption, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding()
      }
      .navigationTitle("Details")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        ToolbarItem(placement: .topBarLeading) {
          Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = text }
            .accessibilityLabel("Copy")
        }
      }
    }
  }
}
