import SwiftUI

/// Toolbar menu providing developer diagnostics and activity log inspection across debug and release builds,
/// including contextual filtering for recent actions, diagnostic errors, and full timeline inspection.
struct DeveloperMenu: View {
  @Environment(DeveloperMenuModel.self) private var model
  /// Active log presentation modal kind, or nil when no viewer sheet is presented.
  @State private var showing: LogViewerModel.Kind?
  @State private var confirmClear = false

  var body: some View {
    Menu {
      Button("Last Action", systemImage: "clock.arrow.circlepath") { showing = .lastAction }
      // Evaluates error presence reactively from model state kept current via activity stream monitoring.
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
      // Capture target action snapshot identifier at sheet presentation time to lock viewing scope.
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

/// Conformance enabling modal sheet binding presentation via unique presentation category titles.
extension LogViewerModel.Kind: Identifiable {
  var id: String { title }
}
