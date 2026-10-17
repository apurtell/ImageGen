import SwiftUI

/// The + menu, the PasteButton, the text field, and Send or Stop (D§3.5).
///
/// Send and Stop start a `Task` for the model's `async` method, so the tap returns at once; the
/// model's `isStarting` and `liveRequest` then decide which button shows and whether it is enabled.
struct ComposerInputRow: View {
  /// `@Bindable` gives `$model.composerText`, a two-way binding for the text field.
  @Bindable var model: ChatScreenModel
  /// The text field's focus. `@FocusState` can belong only to a view, so the two `.onChange`
  /// handlers below copy it to and from `model.isTextFieldFocused` (set by Edit and Resend).
  @FocusState private var focused: Bool
  @State private var showPhotos = false
  @State private var showFiles = false
  @State private var pasteboardHasImages = false

  var body: some View {
    HStack(alignment: .bottom, spacing: 8) {
      Menu {
        Button("Photo Library", systemImage: "photo.on.rectangle") { showPhotos = true }
          .disabled(!model.canAddAttachments)
        Button("Files", systemImage: "folder") { showFiles = true }
          .disabled(!model.canAddAttachments)
        if !model.canAddAttachments {
          Text(ChatScreenModel.fullTrayHint)
        }
      } label: {
        Image(systemName: "plus").font(.title3).frame(width: 36, height: 36)
      }
      .glassEffect(.regular.interactive(), in: .circle)
      .menuOrder(.fixed)
      .accessibilityLabel("Add images")

      if pasteboardHasImages && model.canAddAttachments {
        ComposerPasteButton(model: model)
      }

      TextField("Describe an image or an edit", text: $model.composerText, axis: .vertical)
        .lineLimit(1...6)
        .focused($focused)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .glassEffect(in: .rect(cornerRadius: 18))

      // While a request is live, Send turns into Stop (D§3.5).
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
    .modifier(PasteboardImageWatcher(hasImages: $pasteboardHasImages))
    .modifier(AttachmentImporters(model: model, showPhotos: $showPhotos, showFiles: $showFiles))
    .onChange(of: model.isTextFieldFocused) { _, v in focused = v }
    .onChange(of: focused) { _, v in model.isTextFieldFocused = v }
  }
}
