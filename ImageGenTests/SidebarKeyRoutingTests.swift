import Testing

@testable import ImageGen

@Suite(.tags(.pure))
struct SidebarKeyRoutingTests {
  private let free = SidebarKeyRouting.Situation(listHasKeyboard: true, chatIsOpen: true, isEditingRow: false, isSheetUp: false)

  private func press(_ text: String, ignoring: String? = nil, command: Bool = false, control: Bool = false, function: Bool = false)
    -> SidebarKeyRouting.Press
  {
    SidebarKeyRouting.Press(
      characters: text, charactersIgnoringModifiers: ignoring ?? text, command: command, control: control, function: function)
  }

  @Test func typedCharactersGoToTheComposer() {
    for text in ["a", "Z", "1", "!", " ", "é", "я", "あ", "😀"] {
      #expect(SidebarKeyRouting.forwardsToComposer(press(text), in: free), "\(text)")
    }
  }

  @Test func optionIsTyping() {
    #expect(SidebarKeyRouting.forwardsToComposer(press("å", ignoring: "a"), in: free))
  }

  @Test func deadKeyHasNoTextYetAndStillGoes() {
    #expect(SidebarKeyRouting.forwardsToComposer(press("", ignoring: "e"), in: free))
  }

  @Test func listKeepsItsKeys() {
    let keys = ["\u{F700}", "\u{F701}", "\u{F702}", "\u{F703}", "\u{7F}", "\u{F728}", "\r", "\u{3}", "\t", "\u{19}", "\u{1B}", "\u{8}"]
    for key in keys {
      #expect(!SidebarKeyRouting.forwardsToComposer(press(key), in: free), "\(key.unicodeScalars.first!.value)")
    }
  }

  @Test func functionKeysStay() {
    #expect(!SidebarKeyRouting.forwardsToComposer(press("\u{F704}", function: true), in: free))
    #expect(!SidebarKeyRouting.forwardsToComposer(press("a", function: true), in: free))
  }

  @Test func shortcutsStay() {
    #expect(!SidebarKeyRouting.forwardsToComposer(press("n", command: true), in: free))
    #expect(!SidebarKeyRouting.forwardsToComposer(press("a", control: true), in: free))
    #expect(!SidebarKeyRouting.forwardsToComposer(press("", ignoring: "e", command: true), in: free))
  }

  @Test func aDeadKeyThatNeedsNoOptionGoes() {
    #expect(SidebarKeyRouting.forwardsToComposer(press(""), in: free))
  }

  @Test func keysStayWhenSomethingElseHasAClaim() {
    let typed = press("a")
    var situation = free
    situation.listHasKeyboard = false
    #expect(!SidebarKeyRouting.forwardsToComposer(typed, in: situation))
    situation = free
    situation.chatIsOpen = false
    #expect(!SidebarKeyRouting.forwardsToComposer(typed, in: situation))
    situation = free
    situation.isEditingRow = true
    #expect(!SidebarKeyRouting.forwardsToComposer(typed, in: situation))
    situation = free
    situation.isSheetUp = true
    #expect(!SidebarKeyRouting.forwardsToComposer(typed, in: situation))
  }
}
