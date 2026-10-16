import SwiftUI

/// + (attachments arrive in M6), the text field, and Send or Stop (D§3.5).
struct ComposerInputRow: View {
  @Bindable var model: ChatScreenModel
  @FocusState private var focused: Bool

  var body: some View {
    HStack(alignment: .bottom, spacing: 8) {
      Menu {
        Button("Photo Library", systemImage: "photo.on.rectangle") {}.disabled(true)
        Button("Files", systemImage: "folder") {}.disabled(true)
      } label: {
        Image(systemName: "plus").font(.title3).frame(width: 36, height: 36)
      }
      .glassEffect(.regular.interactive(), in: .circle)
      .accessibilityLabel("Add images")

      TextField("Describe an image or an edit", text: $model.composerText, axis: .vertical)
        .lineLimit(1...6)
        .focused($focused)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .glassEffect(in: .rect(cornerRadius: 18))

      if model.liveRequest != nil {
        Button {
          Task { await model.stop() }
        } label: {
          Image(systemName: "stop.fill").frame(width: 22, height: 22)
        }
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.circle)
        .accessibilityLabel("Stop")
      } else {
        Button {
          Task { await model.send() }
        } label: {
          Image(systemName: "arrow.up").frame(width: 22, height: 22)
        }
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.circle)
        .disabled(!model.canSend)
        .accessibilityLabel("Send")
      }
    }
    .onChange(of: model.isTextFieldFocused) { _, v in focused = v }
    .onChange(of: focused) { _, v in model.isTextFieldFocused = v }
  }
}
