import SwiftUI

/// Contextual action menu presenting operations for a selected image entity, including pinning, exporting, and viewing.
struct ImageContextMenu: View {
  let onEditFromHere: () -> Void
  let onExport: (ImageExportAction) -> Void
  /// Presentation callback invoking the dedicated image viewer; nil if already presented.
  let onView: (() -> Void)?

  var body: some View {
    if Platform.leadsImageMenuWithView, let onView { viewButton(onView) }
    Button(Platform.editFromHereTitle, systemImage: "pin", action: onEditFromHere)
    Button("Save to Photos", systemImage: "square.and.arrow.down") { onExport(.photos) }
    Button("\(Platform.saveToFilesTitle)…", systemImage: "folder") { onExport(.files) }
    Button("Share…", systemImage: "square.and.arrow.up") { onExport(.share) }
    Button(Platform.copyImageTitle, systemImage: "doc.on.doc") { onExport(.copy) }
    if !Platform.leadsImageMenuWithView, let onView { viewButton(onView) }
  }

  private func viewButton(_ action: @escaping () -> Void) -> some View {
    Button("View", systemImage: "arrow.up.left.and.arrow.down.right", action: action)
  }
}
