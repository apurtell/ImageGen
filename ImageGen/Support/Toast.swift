import SwiftUI

/// Transient notification pill rendered with a glassmorphic material treatment for unobtrusive status feedback.
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
  /// Overlays a transient toast banner positioned at the specified alignment with animated entry and exit transitions.
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
