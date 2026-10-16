import SwiftUI

/// The Developer menu (D§3.10), in both toolbars, in Release too.
struct DeveloperMenu: View {
  @Environment(DeveloperMenuModel.self) private var model
  @State private var showing: LogViewerModel.Kind?
  @State private var confirmClear = false

  var body: some View {
    Menu {
      Button("Last Action", systemImage: "clock.arrow.circlepath") { showing = .lastAction }
      Button("Last Error", systemImage: "exclamationmark.triangle") { showing = .lastError }
        .disabled(!model.hasError)
      Button("Full Log", systemImage: "doc.plaintext") { showing = .fullLog }
      Divider()
      Button("Clear Log…", systemImage: "trash", role: .destructive) { confirmClear = true }
    } label: {
      Image(systemName: "hammer")
    }
    .accessibilityLabel("Developer")
    .sheet(item: $showing) { kind in
      LogViewerSheet(
        model: LogViewerModel(
          kind: kind, log: model.log,
          startingAt: kind == .lastAction ? model.lastActionID : kind == .lastError ? model.lastErrorID : nil))
    }
    .confirmationDialog("Clear the activity log?", isPresented: $confirmClear, titleVisibility: .visible) {
      Button("Clear Log", role: .destructive) { Task { await model.clearLog() } }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Every entry is deleted. This can't be undone.")
    }
  }
}

extension LogViewerModel.Kind: Identifiable {
  var id: String { title }
}
