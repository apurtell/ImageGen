import SwiftUI

/// The viewer's bottom glass toolbar (D§3.7): Share, Save to Photos, Save to Files, Copy, Edit
/// from here and Info.
/// A stateless view: each button calls a closure from `ImageViewer`, which acts on the current image.
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

  /// One icon button, 46 × 44 points so the touch target meets the 44-point minimum.
  /// `@escaping`: the button keeps the closure and calls it later, after this function returns.
  private func item(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol).font(.title3).frame(width: 46, height: 44)
    }
    .buttonStyle(.plain)
    .contentShape(Rectangle())
    .accessibilityLabel(label)
  }
}
