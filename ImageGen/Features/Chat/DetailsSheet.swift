import SwiftUI
import UIKit

/// The redacted JSON or error body, monospaced and selectable, with Copy (D§3.4).
/// The text is already redacted when it is stored; this sheet shows it as is.
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
