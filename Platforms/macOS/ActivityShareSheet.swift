import SwiftUI

/// Presents a ShareLink to export or share an image file on macOS.
struct ActivityShareSheet: View {
  let file: ImageFile
  /// Called when sharing completes with the service name, success flag, and any error.
  let onComplete: (String?, Bool, (any Error)?) -> Void

  var body: some View {
    VStack(spacing: 16) {
      ShareLink(item: file.url) { Label("Share \(file.suggestedName)", systemImage: "square.and.arrow.up") }
      Button("Done") { onComplete(nil, false, nil) }
        .keyboardShortcut(.cancelAction)
    }
    .padding(24)
    .frame(minWidth: 280)
  }
}
