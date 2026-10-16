import SwiftUI

/// A failed, refused, empty, cancelled or interrupted reply (D§3.4): glyph, title, message line
/// and buttons, exactly as `ReplyPresentation` maps them.
struct ReplyStatusCard: View {
  let card: ReplyPresentation.Card
  let onButton: (ReplyPresentation.Button) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label {
        Text(card.title).font(.headline)
      } icon: {
        Image(systemName: card.symbol).foregroundStyle(card.symbol == "hand.raised" ? .orange : .red)
      }
      if let message = card.message {
        Text(message).font(.subheadline).foregroundStyle(.secondary)
      }
      if !card.buttons.isEmpty {
        HStack(spacing: 8) {
          ForEach(card.buttons, id: \.self) { button in
            Button(button.rawValue) { onButton(button) }
              .buttonStyle(.bordered)
              .controlSize(.small)
          }
        }
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
  }
}
