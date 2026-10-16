import SwiftUI
import UIKit

/// A read-only `UITextView` (TextKit 2) for the log (D§3.10): any range can be selected and copied,
/// only the visible part is laid out, new lines are appended rather than replacing the text, and
/// the bottom stays pinned while the user is at the bottom.
struct LogTextView: UIViewRepresentable {
  let text: String
  var scrollToBottomOnOpen = false

  final class Coordinator {
    var shownText = ""
    var didInitialScroll = false
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeUIView(context: Context) -> UITextView {
    let view = UITextView(usingTextLayoutManager: true)
    view.isEditable = false
    view.isSelectable = true
    view.alwaysBounceVertical = true
    view.adjustsFontForContentSizeCategory = true
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
    let atBottom = view.contentOffset.y + view.bounds.height >= view.contentSize.height - 24
    if !c.shownText.isEmpty && text.hasPrefix(c.shownText) {
      let added = String(text.dropFirst(c.shownText.count))
      let attributes: [NSAttributedString.Key: Any] = [.font: view.font as Any, .foregroundColor: UIColor.label]
      view.textStorage.append(NSAttributedString(string: added, attributes: attributes))
    } else {
      view.text = text
    }
    c.shownText = text
    if (scrollToBottomOnOpen && !c.didInitialScroll) || (c.didInitialScroll && atBottom) {
      DispatchQueue.main.async {
        view.layoutIfNeeded()
        let bottom = max(0, view.contentSize.height - view.bounds.height + view.adjustedContentInset.bottom)
        view.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
      }
    }
    c.didInitialScroll = true
  }
}
