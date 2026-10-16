import SwiftUI

/// An image's long-press menu (D§3.6). M7 adds the export items in its marked section.
struct ImageContextMenu: View {
  let onEditFromHere: () -> Void
  let onView: () -> Void

  var body: some View {
    Button("Edit from here", systemImage: "pin", action: onEditFromHere)
    // MARK: M7 items
    Button("View", systemImage: "arrow.up.left.and.arrow.down.right", action: onView)
  }
}
