import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// An image from the pasteboard (D§4.8 step 1). Plain `Data` is avoided: its representation is
/// generic data, which may not match image pasteboard items.
struct PastedImage: Transferable, Sendable {
  let data: Data

  static var transferRepresentation: some TransferRepresentation {
    DataRepresentation(importedContentType: .png) { PastedImage(data: $0) }
    DataRepresentation(importedContentType: .jpeg) { PastedImage(data: $0) }
    DataRepresentation(importedContentType: .heic) { PastedImage(data: $0) }
    DataRepresentation(importedContentType: .image) { PastedImage(data: $0) }
  }

  /// The type the bytes declare (`CGImageSourceGetType`), or nil when they aren't an image.
  var detectedType: UTType? {
    guard let source = CGImageSourceCreateWithData(data as CFData, ImageInspector.noCache),
      let type = CGImageSourceGetType(source)
    else { return nil }
    return UTType(type as String)
  }
}

/// The composer's PasteButton (D§3.5), shown by `ComposerInputRow` only while the pasteboard has
/// images and the tray has room.
struct ComposerPasteButton: View {
  let model: ChatScreenModel

  var body: some View {
    PasteButton(payloadType: PastedImage.self) { images in
      let candidates = images.map { AttachmentCandidate.data($0.data) }
      Task { @MainActor in await model.attach(candidates, from: .paste) }
    }
    .labelStyle(.iconOnly)
    .buttonBorderShape(.circle)
    .accessibilityLabel("Paste image")
  }
}

/// Keeps `hasImages` current. `UIPasteboard.hasImages` doesn't prompt; it's re-checked when the
/// app becomes active and when the pasteboard changes.
struct PasteboardImageWatcher: ViewModifier {
  @Binding var hasImages: Bool
  @Environment(\.scenePhase) private var scenePhase

  func body(content: Self.Content) -> some View {
    content
      .onAppear { hasImages = UIPasteboard.general.hasImages }
      .onChange(of: scenePhase) { _, phase in
        if phase == .active { hasImages = UIPasteboard.general.hasImages }
      }
      .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in
        hasImages = UIPasteboard.general.hasImages
      }
  }
}
