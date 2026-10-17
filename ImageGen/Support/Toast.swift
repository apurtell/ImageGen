import SwiftUI

/// A transient glass message, such as "Saved to Photos" or "Up to 14 images per message".
/// A screen model owns the text and decides when to clear it; this file only draws it.
/// `.glassEffect()` is the iOS 26 Liquid Glass material.
struct ToastView: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.footnote)
      .padding(.horizontal, 14).padding(.vertical, 8)
      .glassEffect()
      .accessibilityAddTraits(.isStaticText)
  }
}

extension View {
  /// Shows `text` over the view at `alignment` while it isn't nil.
  /// An extension on `View` makes this a modifier for every view. The toast fades in and out
  /// (`.transition(.opacity)`); `.animation(_:value:)` animates each change of `text`.
  func toast(_ text: String?, alignment: Alignment = .top, offset: CGFloat = 0) -> some View {
    overlay(alignment: alignment) {
      if let text {
        ToastView(text: text)
          .offset(y: offset)
          .transition(.opacity)
      }
    }
    .animation(.default, value: text)
  }
}
