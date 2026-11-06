import AppKit
import SwiftUI

/// Displays selectable monospaced log text in a scroll view, optionally pinned to the bottom.
struct LogTextView: NSViewRepresentable {
  let text: String
  /// Controls whether initial presentation positions the viewport at trailing log entries.
  var scrollToBottomOnOpen = false

  /// Maintains cached document text and initial scroll state to optimize incremental text updates.
  final class Coordinator {
    var shownText = ""
    var didInitialScroll = false
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSTextView.scrollableTextView()
    scroll.hasHorizontalScroller = false
    if let view = scroll.documentView as? NSTextView {
      view.isEditable = false
      view.isSelectable = true
      view.isRichText = false
      // Enable native find bar and incremental search interaction.
      view.usesFindBar = true
      view.isIncrementalSearchingEnabled = true
      view.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
      view.textColor = .labelColor
      view.backgroundColor = .textBackgroundColor
      view.textContainerInset = NSSize(width: 8, height: 12)
      view.setAccessibilityIdentifier("log-text")
    }
    return scroll
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    guard let view = scroll.documentView as? NSTextView else { return }
    let c = context.coordinator
    // Fast-path UTF-8 prefix matching avoids high overhead Unicode grapheme cluster traversal on large buffers.
    guard !text.utf8.elementsEqual(c.shownText.utf8) else { return }
    let visible = scroll.contentView.bounds
    let atBottom = visible.maxY >= view.frame.height - 24
    if !c.shownText.isEmpty && text.utf8.starts(with: c.shownText.utf8) {
      let added = String(decoding: text.utf8.dropFirst(c.shownText.utf8.count), as: UTF8.self)
      let attributes: [NSAttributedString.Key: Any] = [.font: view.font as Any, .foregroundColor: NSColor.labelColor]
      view.textStorage?.append(NSAttributedString(string: added, attributes: attributes))
    } else {
      view.string = text
    }
    c.shownText = text
    if (scrollToBottomOnOpen && !c.didInitialScroll) || (c.didInitialScroll && atBottom) {
      DispatchQueue.main.async { view.scrollToEndOfDocument(nil) }
    }
    c.didInitialScroll = true
  }
}
