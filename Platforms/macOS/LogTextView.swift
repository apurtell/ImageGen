import SwiftUI

/// Displays selectable monospaced log text in a scroll view, optionally pinned to the bottom.
struct LogTextView: View {
  let text: String
  var scrollToBottomOnOpen = false

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        Text(text)
          .font(.system(.caption, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(12)
        Color.clear.frame(height: 1).id("end")
      }
      .defaultScrollAnchor(scrollToBottomOnOpen ? .bottom : .top)
      .onChange(of: text) { if scrollToBottomOnOpen { proxy.scrollTo("end") } }
    }
    .accessibilityIdentifier("log-text")
  }
}
