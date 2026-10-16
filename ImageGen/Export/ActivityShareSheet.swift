import LinkPresentation
import SwiftUI
import UIKit

/// The share sheet (D§4.9): `UIActivityViewController` over one item provider holding the
/// `ImageFile`, so the shared type and bytes are the original's. Unlike `ShareLink`, it reports
/// the outcome through `onComplete`.
struct ActivityShareSheet: UIViewControllerRepresentable {
  let file: ImageFile
  let onComplete: (UIActivity.ActivityType?, Bool, (any Error)?) -> Void

  static func itemProvider(for file: ImageFile) -> NSItemProvider {
    let provider = NSItemProvider()
    provider.register(file)
    provider.suggestedName = file.suggestedName
    return provider
  }

  func makeUIViewController(context: Context) -> UIActivityViewController {
    let configuration = UIActivityItemsConfiguration(itemProviders: [Self.itemProvider(for: file)])
    // The header's preview and title; the shared item itself stays the original file.
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
