import SwiftUI
import UIKit

/// A read-only `UITextView` (TextKit 2) for the log (D§3.10): any range can be selected and copied,
/// only the visible part is laid out, new lines are appended rather than replacing the text, and
/// the bottom stays pinned while the user is at the bottom.
///
/// A UIKit view, hosted with `UIViewRepresentable`: SwiftUI's `Text` can copy only its whole text on
/// iOS, and it lays out all of a 4 MB log. `LogViewerSheet` passes the model's whole text on each
/// update; this view compares it with what it shows and appends only the new tail. All of this runs
/// on the main thread.
struct LogTextView: UIViewRepresentable {
  let text: String
  /// Full Log opens at the bottom (the newest entries). Last Action and Last Error open at the top.
  var scrollToBottomOnOpen = false

  /// State that lives as long as the UIKit view. The SwiftUI struct is rebuilt on each update, so
  /// it cannot hold this.
  final class Coordinator {
    /// The text the view shows now, to find the appended tail on the next update.
    var shownText = ""
    var didInitialScroll = false
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeUIView(context: Context) -> UITextView {
    // `usingTextLayoutManager: true` selects TextKit 2, which lays out only the visible part.
    let view = UITextView(usingTextLayoutManager: true)
    view.isEditable = false
    view.isSelectable = true
    view.alwaysBounceVertical = true
    view.adjustsFontForContentSizeCategory = true
    // The caption text style in the system monospaced font, scaled with Dynamic Type.
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
    // Read before the text changes: "at the bottom" describes where the user was reading.
    // 24 points of slack count as the bottom.
    let atBottom = view.contentOffset.y + view.bounds.height >= view.contentSize.height - 24
    if !c.shownText.isEmpty && text.hasPrefix(c.shownText) {
      // The common case: new lines at the end. Appending keeps the user's selection and scroll
      // position, and lays out only the new part.
      let added = String(text.dropFirst(c.shownText.count))
      let attributes: [NSAttributedString.Key: Any] = [.font: view.font as Any, .foregroundColor: UIColor.label]
      view.textStorage.append(NSAttributedString(string: added, attributes: attributes))
    } else {
      // The text changed in the middle (for example, a re-rendered tree inserted a line): replace it.
      view.text = text
    }
    c.shownText = text
    if (scrollToBottomOnOpen && !c.didInitialScroll) || (c.didInitialScroll && atBottom) {
      // Deferred to the next main-queue turn, so the content size includes the new text first.
      DispatchQueue.main.async {
        view.layoutIfNeeded()
        let bottom = max(0, view.contentSize.height - view.bounds.height + view.adjustedContentInset.bottom)
        view.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
      }
    }
    c.didInitialScroll = true
  }
}
