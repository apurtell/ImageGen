import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Transferable container encapsulating raw image data imported via system pasteboard operations,
/// providing typed matching across PNG, JPEG, HEIC, and generic uniform image identifiers.
struct PastedImage: Transferable, Sendable {
  let data: Data

  /// Prioritized transfer representations mapping system image types to internal byte payloads.
  static var transferRepresentation: some TransferRepresentation {
    DataRepresentation(importedContentType: .png) { PastedImage(data: $0) }
    DataRepresentation(importedContentType: .jpeg) { PastedImage(data: $0) }
    DataRepresentation(importedContentType: .heic) { PastedImage(data: $0) }
    DataRepresentation(importedContentType: .image) { PastedImage(data: $0) }
  }

  /// Uniform type identifier determined from embedded image stream headers via Core Graphics.
  var detectedType: UTType? {
    guard let source = CGImageSourceCreateWithData(data as CFData, ImageInspector.noCache),
      let type = CGImageSourceGetType(source)
    else { return nil }
    return UTType(type as String)
  }
}

/// Dedicated paste button invoking system pasteboard extraction workflows without prompting for
/// explicit permissions until user-initiated interaction occurs.
struct ComposerPasteButton: View {
  let model: ChatScreenModel

  var body: some View {
    // System PasteButton defers pasteboard access to direct user interaction, bypassing permission prompts.
    PasteButton(payloadType: PastedImage.self) { images in
      let candidates = images.map { AttachmentCandidate.data($0.data) }
      Task { @MainActor in await model.attach(candidates, from: .paste) }
    }
    .labelStyle(.iconOnly)
    .buttonBorderShape(.circle)
    .accessibilityLabel("Paste image")
  }
}

/// View modifier maintaining real-time awareness of pasteboard image presence, synchronizing across
/// system pasteboard notification events and application foreground reactivation cycles.
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
