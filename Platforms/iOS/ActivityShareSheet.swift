import LinkPresentation
import SwiftUI
import UIKit

/// Presents a UIActivityViewController to share an exported image file.
///
/// Uses UIKit directly so completion handlers can report the chosen activity type,
/// success status, and errors back to the export activity log.
struct ActivityShareSheet: UIViewControllerRepresentable {
  let file: ImageFile
  /// Called with the chosen activity type, completion status, and any error.
  let onComplete: (String?, Bool, (any Error)?) -> Void

  func makeUIViewController(context: Context) -> UIActivityViewController {
    let configuration = UIActivityItemsConfiguration(itemProviders: [file.itemProvider])
    // Provide preview metadata so the share sheet shows the file title and an image thumbnail.
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
    controller.completionWithItemsHandler = { type, completed, _, error in onComplete(type?.rawValue, completed, error) }
    return controller
  }

  func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
