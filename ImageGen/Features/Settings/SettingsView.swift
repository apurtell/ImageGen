import SwiftUI

/// Settings (the M5 stub: the API Key section; M8 adds the rest).
struct SettingsView: View {
  @State var model: APIKeySectionModel
  @Environment(\.dismiss) private var dismiss
  @Environment(Navigator.self) private var navigator
  @State private var confirmRemove = false

  var body: some View {
    NavigationStack {
      Form {
        Section("API Key") {
          LabeledContent("Status", value: model.lastFour.map { "Saved · ••••\($0)" } ?? "No key")
          if model.hasKey {
            Button("Remove Key", role: .destructive) { confirmRemove = true }
          }
        }
      }
      .navigationTitle("Settings")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
      .confirmationDialog("Remove the API key?", isPresented: $confirmRemove, titleVisibility: .visible) {
        Button("Remove Key", role: .destructive) {
          if model.removeKey() {
            dismiss()
            navigator.needsOnboarding = true
          }
        }
      }
    }
  }
}
