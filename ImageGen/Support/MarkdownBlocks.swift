import Foundation

/// One block of reply text. An enum with associated values: each case carries its own data.
enum MarkdownBlock: Sendable, Equatable {
  case heading(level: Int, text: String)
  case paragraph(String)
  /// `depth` 0 is the outermost level. `number` is set for numbered items.
  case listItem(depth: Int, number: Int?, text: String)
  case code(language: String?, text: String)
  case quote(String)
}

/// A small block parser for reply text (D§4.12): ATX headings, `-`/`*`/`+`/`1.` lists with nesting,
/// fenced code, block quotes and paragraphs. Inline styling is left to
/// `AttributedString(markdown:)`; Markdown images are dropped. Pure.
///
/// `MarkdownView` calls `parse`. It reads the text line by line in one pass. Its state is the open
/// paragraph, the open quote and the indents of the open list levels. A blank line ends every open
/// block. Pure, so any thread or actor can call it.
enum MarkdownBlocks {
  static func parse(_ text: String) -> [MarkdownBlock] {
    var blocks: [MarkdownBlock] = []
    var paragraph: [String] = []
    var quote: [String] = []
    var listIndents: [Int] = []
    var lastWasListItem = false

    // Local functions: they can change the variables of `parse` around them.
    func flushParagraph() {
      let joined = stripImages(paragraph.joined(separator: "\n")).trimmingCharacters(in: .whitespacesAndNewlines)
      if !joined.isEmpty { blocks.append(.paragraph(joined)) }
      paragraph = []
    }
    func flushQuote() {
      let joined = stripImages(quote.joined(separator: "\n")).trimmingCharacters(in: .whitespacesAndNewlines)
      if !joined.isEmpty { blocks.append(.quote(joined)) }
      quote = []
    }
    func flushAll() {
      flushParagraph()
      flushQuote()
    }

    let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    var i = 0
    while i < lines.count {
      let line = lines[i]
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      i += 1

      // A blank line also ends the list, so nesting starts again after it.
      if trimmed.isEmpty {
        flushAll()
        lastWasListItem = false
        listIndents = []
        continue
      }

      // Fenced code: everything up to the closing fence (or the end) verbatim.
      // The closing fence is any line that starts with the same marker.
      if let fence = fenceMarker(trimmed) {
        flushAll()
        lastWasListItem = false
        let info = trimmed.dropFirst(fence.count).trimmingCharacters(in: .whitespaces)
        var body: [String] = []
        while i < lines.count {
          let l = lines[i]
          i += 1
          if l.trimmingCharacters(in: .whitespaces).hasPrefix(fence) { break }
          body.append(l)
        }
        blocks.append(.code(language: info.isEmpty ? nil : info, text: body.joined(separator: "\n")))
        continue
      }

      if let (level, content) = heading(line) {
        flushAll()
        lastWasListItem = false
        blocks.append(.heading(level: level, text: stripImages(content)))
        continue
      }

      if let content = quoteContent(line) {
        flushParagraph()
        lastWasListItem = false
        quote.append(content)
        continue
      }

      if let (indent, number, content) = listItem(line) {
        flushAll()
        // Close the levels deeper than this indent, then open a level if it is deeper than the
        // open one. The depth is the number of open levels, less one.
        while let top = listIndents.last, indent < top { listIndents.removeLast() }
        if listIndents.isEmpty || indent > listIndents.last! { listIndents.append(indent) }
        blocks.append(.listItem(depth: listIndents.count - 1, number: number, text: stripImages(content)))
        lastWasListItem = true
        continue
      }

      // A continuation line belongs to the list item or quote it follows.
      if lastWasListItem, case .listItem(let depth, let number, let previous)? = blocks.last {
        blocks[blocks.count - 1] = .listItem(depth: depth, number: number, text: previous + "\n" + stripImages(trimmed))
        continue
      }
      if !quote.isEmpty {
        quote.append(trimmed)
        continue
      }
      paragraph.append(trimmed)
    }
    flushAll()
    // Drop headings and list items with no text, for example after `stripImages`.
    return blocks.filter {
      switch $0 {
      case .heading(_, let t), .listItem(_, _, let t): !t.trimmingCharacters(in: .whitespaces).isEmpty
      default: true
      }
    }
  }

  // MARK: Line kinds

  private static func fenceMarker(_ trimmed: String) -> String? {
    if trimmed.hasPrefix("```") { return "```" }
    if trimmed.hasPrefix("~~~") { return "~~~" }
    return nil
  }

  /// `#`–`######` followed by a space (a `#` with no space is a paragraph), up to 3 spaces of indent.
  private static func heading(_ line: String) -> (Int, String)? {
    let indent = line.prefix { $0 == " " }.count
    guard indent <= 3 else { return nil }
    let rest = line.dropFirst(indent)
    let hashes = rest.prefix { $0 == "#" }.count
    guard (1...6).contains(hashes) else { return nil }
    let after = rest.dropFirst(hashes)
    guard let first = after.first, first == " " || first == "\t" else { return nil }
    var content = after.trimmingCharacters(in: .whitespaces)
    // An optional closing run of #s.
    if let range = content.range(of: #"\s+#+$"#, options: .regularExpression) {
      content.removeSubrange(range)
    } else if content.allSatisfy({ $0 == "#" }) {
      content = ""
    }
    return (hashes, content)
  }

  /// `>` with up to 3 spaces of indent. One space after `>` is removed.
  private static func quoteContent(_ line: String) -> String? {
    let indent = line.prefix { $0 == " " }.count
    guard indent <= 3 else { return nil }
    let rest = line.dropFirst(indent)
    guard rest.first == ">" else { return nil }
    let content = rest.dropFirst()
    return String(content.first == " " ? content.dropFirst() : content)
  }

  /// `- `, `* `, `+ ` or `1. ` / `1) `, with its indent (a tab counts as 4 spaces).
  private static func listItem(_ line: String) -> (indent: Int, number: Int?, text: String)? {
    var indent = 0
    var rest = Substring(line)
    while let c = rest.first, c == " " || c == "\t" {
      indent += c == "\t" ? 4 : 1
      rest = rest.dropFirst()
    }
    if let c = rest.first, "-*+".contains(c) {
      let after = rest.dropFirst()
      guard after.isEmpty || after.first == " " || after.first == "\t" else { return nil }
      return (indent, nil, after.trimmingCharacters(in: .whitespaces))
    }
    let digits = rest.prefix { $0.isASCII && $0.isNumber }
    guard (1...9).contains(digits.count), let number = Int(digits) else { return nil }
    let after = rest.dropFirst(digits.count)
    guard let marker = after.first, marker == "." || marker == ")" else { return nil }
    let body = after.dropFirst()
    guard body.isEmpty || body.first == " " || body.first == "\t" else { return nil }
    return (indent, number, body.trimmingCharacters(in: .whitespaces))
  }

  /// Markdown images aren't rendered (D§4.12).
  static func stripImages(_ s: String) -> String {
    s.replacingOccurrences(of: #"!\[[^\]]*\]\([^)]*\)"#, with: "", options: .regularExpression)
  }
}
