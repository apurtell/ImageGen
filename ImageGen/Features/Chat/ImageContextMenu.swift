import SwiftUI

/// An image's long-press menu (D§3.6): Edit from here, the exports (original bytes, D§4.9), View.
struct ImageContextMenu: View {
  let onEditFromHere: () -> Void
  let onExport: (ImageExportAction) -> Void
  let onView: () -> Void

  var body: some View {
    Button("Edit from here", systemImage: "pin", action: onEditFromHere)
    // MARK: M7 items
    Button("Save to Photos", systemImage: "square.and.arrow.down") { onExport(.photos) }
    Button("Save to Files…", systemImage: "folder") { onExport(.files) }
    Button("Share…", systemImage: "square.and.arrow.up") { onExport(.share) }
    Button("Copy", systemImage: "doc.on.doc") { onExport(.copy) }
    Button("View", systemImage: "arrow.up.left.and.arrow.down.right", action: onView)
  }
}
