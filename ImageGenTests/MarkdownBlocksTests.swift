import Foundation
import Testing

@testable import ImageGen

@Suite(.tags(.pure))
struct MarkdownBlocksTests {
  @Test func headings() {
    #expect(MarkdownBlocks.parse("# Title\n## Sub ##\n###### Six\n####### Seven") == [
      .heading(level: 1, text: "Title"), .heading(level: 2, text: "Sub"), .heading(level: 6, text: "Six"),
      .paragraph("####### Seven"),
    ])
  }

  @Test func strayHashWithoutSpaceIsParagraph() {
    #expect(MarkdownBlocks.parse("#hashtag and more") == [.paragraph("#hashtag and more")])
  }

  @Test func nestedLists() {
    let text = """
      - fruit
        - apple
          - green
        - pear
      - bread
      1. first
      2) second
      """
    #expect(MarkdownBlocks.parse(text) == [
      .listItem(depth: 0, number: nil, text: "fruit"), .listItem(depth: 1, number: nil, text: "apple"),
      .listItem(depth: 2, number: nil, text: "green"), .listItem(depth: 1, number: nil, text: "pear"),
      .listItem(depth: 0, number: nil, text: "bread"), .listItem(depth: 0, number: 1, text: "first"),
      .listItem(depth: 0, number: 2, text: "second"),
    ])
  }

  @Test func looseListKeepsNestingAcrossBlankLines() {
    let text = """
      - fruit

        - apple

      - bread

      Then a paragraph.

        - indented again
      """
    #expect(MarkdownBlocks.parse(text) == [
      .listItem(depth: 0, number: nil, text: "fruit"), .listItem(depth: 1, number: nil, text: "apple"),
      .listItem(depth: 0, number: nil, text: "bread"), .paragraph("Then a paragraph."),
      // An intervening paragraph terminates list context, resetting subsequent list items to base depth 0 regardless of indentation.
      .listItem(depth: 0, number: nil, text: "indented again"),
    ])
  }

  @Test func listContinuationLine() {
    #expect(MarkdownBlocks.parse("* item one\n  continues here\n* item two") == [
      .listItem(depth: 0, number: nil, text: "item one\ncontinues here"), .listItem(depth: 0, number: nil, text: "item two"),
    ])
  }

  @Test func fencedCodeWithLanguage() {
    let text = "Before\n```swift\nlet x = 1\n  # not a heading\n- not a list\n```\nAfter"
    #expect(MarkdownBlocks.parse(text) == [
      .paragraph("Before"), .code(language: "swift", text: "let x = 1\n  # not a heading\n- not a list"), .paragraph("After"),
    ])
    #expect(MarkdownBlocks.parse("```\nunterminated") == [.code(language: nil, text: "unterminated")])
  }

  @Test func quote() {
    #expect(MarkdownBlocks.parse("> quoted line\n> second\n\nafter") == [.quote("quoted line\nsecond"), .paragraph("after")])
  }

  @Test func mixedParagraphs() {
    let text = "First paragraph\nwraps here.\n\nSecond *with* **style** and [a link](https://example.com).\n# Heading\nThird"
    #expect(MarkdownBlocks.parse(text) == [
      .paragraph("First paragraph\nwraps here."),
      .paragraph("Second *with* **style** and [a link](https://example.com)."),
      .heading(level: 1, text: "Heading"), .paragraph("Third"),
    ])
  }

  @Test func markdownImagesIgnored() {
    #expect(MarkdownBlocks.parse("Look: ![alt](data:image/png;base64,AAAA) done") == [.paragraph("Look:  done")])
    #expect(MarkdownBlocks.parse("![only](https://x/y.png)\n\nText") == [.paragraph("Text")])
    #expect(MarkdownBlocks.parse("- ![img](a.png)") == [])
  }

  @Test func inlineStylingParses() {
    let attributed = MarkdownView.inline("Some **bold** and a [link](https://example.com)\nnext line")
    #expect(String(attributed.characters) == "Some bold and a link\nnext line")
    #expect(attributed.runs.contains { $0.link == URL(string: "https://example.com") })
  }
}
