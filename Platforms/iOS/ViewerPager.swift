import SwiftUI

/// Horizontal paging container hosting sequential image pages within the viewer.
struct ViewerPager<Page: View>: View {
  let images: [ViewerImage]
  @Binding var selection: UUID
  @ViewBuilder let page: (ViewerImage) -> Page

  var body: some View {
    TabView(selection: $selection) {
      ForEach(images) { image in
        page(image).tag(image.id)
      }
    }
    .tabViewStyle(.page(indexDisplayMode: .never))
  }
}
