import SwiftUI

/// Pager view displaying the active image within a message set without retaining inactive views.
struct ViewerPager<Page: View>: View {
  let images: [ViewerImage]
  @Binding var selection: UUID
  @ViewBuilder let page: (ViewerImage) -> Page

  var body: some View {
    if let image = images.first(where: { $0.id == selection }) ?? images.first {
      page(image).id(image.id)
    }
  }
}
