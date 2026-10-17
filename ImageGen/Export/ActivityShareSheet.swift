import LinkPresentation
import SwiftUI
import UIKit

/// Bridge presenting a UIKit activity controller configured with an item provider representation of an `ImageFile`.
///
/// Unlike standard declarative sharing components, this representation exposes completion callbacks
/// with activity type discrimination, completion disposition, and error propagation, enabling comprehensive
/// export telemetry and user notification.
struct ActivityShareSheet: UIViewControllerRepresentable {
  let file: ImageFile
  /// Completion callback delivering selected activity type, success disposition, and optional execution failure.
  let onComplete: (UIActivity.ActivityType?, Bool, (any Error)?) -> Void

  /// Constructs an `NSItemProvider` exposing the underlying file representation and designated filename.
  static func itemProvider(for file: ImageFile) -> NSItemProvider {
    let provider = NSItemProvider()
    provider.register(file)
    provider.suggestedName = file.suggestedName
    return provider
  }

  func makeUIViewController(context: Context) -> UIActivityViewController {
    let configuration = UIActivityItemsConfiguration(itemProviders: [Self.itemProvider(for: file)])
    // Configure rich preview presentation metadata for system sharing sheets.
    let metadata = LPLinkMetadata()
    metadata.title = file.suggestedName
    metadata.imageProvider = NSItemProvider(contentsOf: file.url)
    configuration.metadataProvider = { key in
      switch key {
      case .linkPresentationMetadata: metadata
      case .title: file.suggestedName
      default: nil
      }
    }
    let controller = UIActivityViewController(activityItemsConfiguration: configuration)
    controller.completionWithItemsHandler = { type, completed, _, error in onComplete(type, completed, error) }
    return controller
  }

  func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
