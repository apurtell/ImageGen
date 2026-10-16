import SwiftUI

/// Renders reply text as Markdown blocks (D§4.12). Inline styling comes from
/// `AttributedString(markdown:)`; links open in Safari through the environment's `openURL`.
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
      ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
        view(for: block)
      }
    }
    .textSelection(.enabled)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

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
