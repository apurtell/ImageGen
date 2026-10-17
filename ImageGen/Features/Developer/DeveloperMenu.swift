import SwiftUI

/// The Developer menu (D§3.10), in both toolbars, in Release too.
///
/// The menu is a thin view. It reads the shared `DeveloperMenuModel` (from the environment) to know
/// which action Last Action and Last Error show, and whether Last Error is enabled. Each item opens a
/// `LogViewerSheet` with a new `LogViewerModel`, which fixes the action to show at the moment the
/// sheet opens. Clear Log… asks for confirmation, then calls the model. Everything here runs on the
/// main actor; the only asynchronous work is the clear, in its own `Task`.
struct DeveloperMenu: View {
  @Environment(DeveloperMenuModel.self) private var model
  /// The sheet that is open, or nil. `.sheet(item:)` shows a sheet while this is non-nil.
  @State private var showing: LogViewerModel.Kind?
  @State private var confirmClear = false

  var body: some View {
    Menu {
      Button("Last Action", systemImage: "clock.arrow.circlepath") { showing = .lastAction }
      // Disabled from the model's status, which `ActivityLog.changes()` keeps current, so the state
      // is right without opening a sheet first (D§3.10).
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
      // The action ID is read once, here, when the sheet opens. A newer action does not replace it
      // while the sheet stays open (D§3.10). Full Log takes nil: it shows every entry.
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

/// `.sheet(item:)` needs an `Identifiable` value. The three kinds have distinct titles, so the title
/// serves as the ID.
extension LogViewerModel.Kind: Identifiable {
  var id: String { title }
}
