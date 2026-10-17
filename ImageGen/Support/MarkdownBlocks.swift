import Foundation

/// Abstract syntax tree representation of a top-level block element within assistant markdown text.
enum MarkdownBlock: Sendable, Equatable {
  case heading(level: Int, text: String)
  case paragraph(String)
  /// Structured list item specifying hierarchical nesting depth, optional numeric index, and item content.
  case listItem(depth: Int, number: Int?, text: String)
  case code(language: String?, text: String)
  case quote(String)
}

/// Single-pass structural block parser converting raw markdown strings into discrete block primitives.
///
/// Recognizes ATX headings, ordered and unordered lists with arbitrary nesting depths, fenced code blocks,
/// block quotes, and paragraphs while omitting unsupported inline image tags.
enum MarkdownBlocks {
  static func parse(_ text: String) -> [MarkdownBlock] {
    var blocks: [MarkdownBlock] = []
    var paragraph: [String] = []
    var quote: [String] = []
    var listIndents: [Int] = []
    var lastWasListItem = false

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

      // Blank lines terminate open paragraphs and quotes while preserving loose list nesting.
      if trimmed.isEmpty {
        flushAll()
        lastWasListItem = false
        continue
      }

      // Fenced code block ingestion up to the matching closing fence delimiter.
      if let fence = fenceMarker(trimmed) {
        flushAll()
        lastWasListItem = false
        listIndents = []
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
        listIndents = []
        blocks.append(.heading(level: level, text: stripImages(content)))
        continue
      }

      if let content = quoteContent(line) {
        flushParagraph()
        lastWasListItem = false
        listIndents = []
        quote.append(content)
        continue
      }

      if let (indent, number, content) = listItem(line) {
        flushAll()
        // Adjust active indentation stack to match current list item nesting level.
        while let top = listIndents.last, indent < top { listIndents.removeLast() }
        if listIndents.isEmpty || indent > listIndents.last! { listIndents.append(indent) }
        blocks.append(.listItem(depth: listIndents.count - 1, number: number, text: stripImages(content)))
        lastWasListItem = true
        continue
      }

      if lastWasListItem, case .listItem(let depth, let number, let previous)? = blocks.last {
        blocks[blocks.count - 1] = .listItem(depth: depth, number: number, text: previous + "\n" + stripImages(trimmed))
        continue
      }
      if !quote.isEmpty {
        quote.append(trimmed)
        continue
      }
      listIndents = []
      paragraph.append(trimmed)
    }
    flushAll()
    // Filter empty headings and list items resulting from image stripping.
    return blocks.filter {
      switch $0 {
      case .heading(_, let t), .listItem(_, _, let t): !t.trimmingCharacters(in: .whitespaces).isEmpty
      default: true
      }
    }
  }

  private static func fenceMarker(_ trimmed: String) -> String? {
    if trimmed.hasPrefix("```") { return "```" }
    if trimmed.hasPrefix("~~~") { return "~~~" }
    return nil
  }

  /// Parses ATX heading syntax (levels 1-6) preceded by up to 3 spaces of indentation.
  private static func heading(_ line: String) -> (Int, String)? {
    let indent = line.prefix { $0 == " " }.count
    guard indent <= 3 else { return nil }
    let rest = line.dropFirst(indent)
    let hashes = rest.prefix { $0 == "#" }.count
    guard (1...6).contains(hashes) else { return nil }
    let after = rest.dropFirst(hashes)
    guard let first = after.first, first == " " || first == "\t" else { return nil }
    var content = after.trimmingCharacters(in: .whitespaces)
    if let range = content.range(of: #"\s+#+$"#, options: .regularExpression) {
      content.removeSubrange(range)
    } else if content.allSatisfy({ $0 == "#" }) {
      content = ""
    }
    return (hashes, content)
  }

  /// Parses blockquote prefix markers preceded by up to 3 spaces of indentation.
  private static func quoteContent(_ line: String) -> String? {
    let indent = line.prefix { $0 == " " }.count
    guard indent <= 3 else { return nil }
    let rest = line.dropFirst(indent)
    guard rest.first == ">" else { return nil }
    let content = rest.dropFirst()
    return String(content.first == " " ? content.dropFirst() : content)
  }

  /// Identifies ordered and unordered list markers, normalizing tab indentation to 4 spaces.
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

  /// Strips embedded markdown image tags from input text.
  static func stripImages(_ s: String) -> String {
    s.replacingOccurrences(of: #"!\[[^\]]*\]\([^)]*\)"#, with: "", options: .regularExpression)
  }
}
