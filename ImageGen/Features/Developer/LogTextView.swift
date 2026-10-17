import SwiftUI
import UIKit

/// Read-only TextKit 2 text view representable optimized for high performance log inspection,
/// featuring arbitrary text selection, virtualized viewport layout, incremental tail appending,
/// and viewport auto-pinning during tail additions.
struct LogTextView: UIViewRepresentable {
  let text: String
  /// Configures whether the initial presentation scrolls automatically to the latest trailing log entries.
  var scrollToBottomOnOpen = false

  /// Coordinator maintaining persistent text snapshot references and viewport initialization flags.
  final class Coordinator {
    /// Cached representation of currently rendered text, facilitating incremental tail appending.
    var shownText = ""
    var didInitialScroll = false
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeUIView(context: Context) -> UITextView {
    // TextKit 2 layout manager virtualizes rendering across large log buffers.
    let view = UITextView(usingTextLayoutManager: true)
    view.isEditable = false
    view.isSelectable = true
    view.alwaysBounceVertical = true
    view.adjustsFontForContentSizeCategory = true
    // Scale system monospaced caption typography in accordance with Dynamic Type metrics.
    view.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(
      for: .monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .regular))
    view.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
    view.backgroundColor = .systemBackground
    view.accessibilityIdentifier = "log-text"
    return view
  }

  func updateUIView(_ view: UITextView, context: Context) {
    let c = context.coordinator
    guard text != c.shownText else { return }
    // Evaluate viewport scroll offset prior to text mutation to determine bottom pinning status.
    let atBottom = view.contentOffset.y + view.bounds.height >= view.contentSize.height - 24
    if !c.shownText.isEmpty && text.hasPrefix(c.shownText) {
      // Append incremental lines to existing text storage to preserve active text selection and scroll state.
      let added = String(text.dropFirst(c.shownText.count))
      let attributes: [NSAttributedString.Key: Any] = [.font: view.font as Any, .foregroundColor: UIColor.label]
      view.textStorage.append(NSAttributedString(string: added, attributes: attributes))
    } else {
      // Full content replacement when non-contiguous changes or re-renderings occur.
      view.text = text
    }
    c.shownText = text
    if (scrollToBottomOnOpen && !c.didInitialScroll) || (c.didInitialScroll && atBottom) {
      // Defer viewport realignment until text layout metrics update in the subsequent runloop turn.
      DispatchQueue.main.async {
        view.layoutIfNeeded()
        let bottom = max(0, view.contentSize.height - view.bounds.height + view.adjustedContentInset.bottom)
        view.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
      }
    }
    c.didInitialScroll = true
  }
}
