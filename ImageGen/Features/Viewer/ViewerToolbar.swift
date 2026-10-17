import SwiftUI

/// Floating glassmorphic toolbar positioned at the base of the image viewer, hosting quick-action controls
/// for system export, photo library persistence, document sharing, clipboard operations, iterative editing,
/// and metadata inspection.
struct ViewerToolbar: View {
  let onExport: (ImageExportAction) -> Void
  let onEditFromHere: () -> Void
  let onInfo: () -> Void

  var body: some View {
    GlassEffectContainer(spacing: 4) {
      HStack(spacing: 4) {
        item("square.and.arrow.up", "Share") { onExport(.share) }
        item("square.and.arrow.down", "Save to Photos") { onExport(.photos) }
        item("folder", "Save to Files") { onExport(.files) }
        item("doc.on.doc", "Copy") { onExport(.copy) }
        item("pin", "Edit from here", action: onEditFromHere)
        item("info.circle", "Info", action: onInfo)
      }
      .padding(6)
      .glassEffect(in: .capsule)
    }
  }

  /// Constructs a standard icon button conforming to minimum touch target requirements.
  private func item(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol).font(.title3).frame(width: 46, height: 44)
    }
    .buttonStyle(.plain)
    .contentShape(Rectangle())
    .accessibilityLabel(label)
  }
}
