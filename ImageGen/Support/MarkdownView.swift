import SwiftUI

/// Declarative renderer transforming parsed markdown AST blocks into stylized SwiftUI views.
///
/// Dispatches block nodes to tailored view hierarchies for headings, paragraphs, indented list items,
/// horizontally scrollable code containers, and blockquotes with inline attributed string styling.
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
      // Positionally identified block sequence.
      ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
        view(for: block)
      }
    }
    .textSelection(.enabled)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// Generates the appropriate visual representation for an individual AST block node.
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
      // Horizontal scrolling container preserving monospace line indentation and wrapping.
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
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  /// Parses inline markdown styling while preserving whitespace and newline semantics.
  static func inline(_ text: String) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
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
