import SwiftUI

/// Renders reply text as Markdown blocks (D§4.12). Inline styling comes from
/// `AttributedString(markdown:)`; links open in Safari through the environment's `openURL`.
///
/// `MessageRow` uses it for reply text. It is a SwiftUI view, so it runs on the main actor (see the
/// primer, *SwiftUI*). `init` parses the text with `MarkdownBlocks.parse`, and `body` only maps blocks
/// to views. SwiftUI makes the view struct again each time the parent's `body` runs, so the parse
/// runs again too; it is one linear pass, cheap for a reply.
struct MarkdownView: View {
  let blocks: [MarkdownBlock]

  init(_ text: String) {
    blocks = MarkdownBlocks.parse(text)
  }

  init(blocks: [MarkdownBlock]) {
    self.blocks = blocks
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      // Blocks have no identity of their own. The index is enough: one text's blocks never reorder.
      ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
        view(for: block)
      }
    }
    .textSelection(.enabled)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// `@ViewBuilder` (a result builder) lets each `switch` case produce a different view type.
  @ViewBuilder
  private func view(for block: MarkdownBlock) -> some View {
    switch block {
    case .heading(let level, let text):
      Text(Self.inline(text))
        .font(Self.headingFont(level))
        .padding(.top, level <= 2 ? 4 : 2)
    case .paragraph(let text):
      Text(Self.inline(text))
    case .listItem(let depth, let number, let text):
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text(number.map { "\($0)." } ?? "•")
          .monospacedDigit()
          .foregroundStyle(.secondary)
        Text(Self.inline(text))
      }
      .padding(.leading, CGFloat(depth) * 18)
    case .code(_, let text):
      // Scrolls sideways, so long code lines keep their shape instead of wrapping.
      ScrollView(.horizontal, showsIndicators: false) {
        Text(text)
          .font(.system(.callout, design: .monospaced))
          .padding(10)
      }
      .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    case .quote(let text):
      HStack(alignment: .top, spacing: 8) {
        RoundedRectangle(cornerRadius: 1.5)
          .fill(.tertiary)
          .frame(width: 3)
        Text(Self.inline(text))
          .foregroundStyle(.secondary)
      }
      .fixedSize(horizontal: false, vertical: true)  // Full text height, so the bar matches the text.
    }
  }

  /// Inline Markdown only (emphasis, code, links), with line breaks kept.
  static func inline(_ text: String) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)  // Invalid: plain.
  }

  private static func headingFont(_ level: Int) -> Font {
    switch level {
    case 1: .title2.bold()
    case 2: .title3.bold()
    case 3: .headline
    default: .subheadline.bold()
    }
  }
}
