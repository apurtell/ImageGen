import SwiftUI

/// Configures window toolbar items and contextual menu actions for the macOS image viewer.
struct ViewerChrome: ViewModifier {
  let image: ViewerImage?
  let imageCount: Int
  let isVisible: Bool
  let onExport: (ImageExportAction) -> Void
  let onEditFromHere: () -> Void
  let onInfo: () -> Void
  let onMove: (Int) -> Void

  func body(content: Self.Content) -> some View {
    content
      .toolbar {
        if imageCount > 1 {
          ToolbarItemGroup(placement: .navigation) {
            Button("Previous Image", systemImage: "chevron.left") { onMove(-1) }
              .help("Previous image")
            Button("Next Image", systemImage: "chevron.right") { onMove(1) }
              .help("Next image")
          }
        }
        ToolbarItemGroup(placement: .primaryAction) {
          Button("Share…", systemImage: "square.and.arrow.up") { onExport(.share) }
            .help("Share this image")
          Button("Save to Photos", systemImage: "photo.badge.plus") { onExport(.photos) }
            .help("Save to Photos")
          Button("\(Platform.saveToFilesTitle)…", systemImage: "square.and.arrow.down") { onExport(.files) }
            .help("Save a copy of this image")
          Button(Platform.copyImageTitle, systemImage: "doc.on.doc") { onExport(.copy) }
            .help("Copy this image")
          Button(Platform.editFromHereTitle, systemImage: "pin", action: onEditFromHere)
            .help("Edit from this image in its chat")
          Button(Platform.infoTitle, systemImage: "info.circle", action: onInfo)
            .help("Show information about this image")
        }
      }
      .contextMenu {
        ImageContextMenu(onEditFromHere: onEditFromHere, onExport: onExport, onView: nil)
        Button(Platform.infoTitle, systemImage: "info.circle", action: onInfo)
      }
  }
}
