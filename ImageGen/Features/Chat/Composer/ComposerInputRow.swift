import SwiftUI

/// Interactive composer input bar containing media import menus, pasteboard shortcuts,
/// multiline prompt editing controls, and state adaptive execution/cancellation triggers.
struct ComposerInputRow: View {
  @Bindable var model: ChatScreenModel
  /// Focus binding synchronized bidirectionally with view-model state to accommodate programmatically
  /// triggered input focusing, such as during prompt reedit workflows.
  @FocusState private var focused: Bool
  @State private var showPhotos = false
  @State private var showFiles = false
  @State private var pasteboardHasImages = false

  var body: some View {
    HStack(alignment: .bottom, spacing: 8) {
      ComposerAddMenu(model: model, showPhotos: $showPhotos, showFiles: $showFiles)

      ComposerPasteControl(model: model, hasImages: pasteboardHasImages)

      TextField("Describe an image or an edit", text: $model.composerText, axis: .vertical)
        .framelessFieldStyle()
        .lineLimit(1...6)
        .focused($focused)
        .marksComposerField()
        .padding(.horizontal, 12).padding(.vertical, 8)
        .glassEffect(in: .rect(cornerRadius: 18))
        .composerKeys(canSend: model.canSend) { Task { await model.send() } }

      // Transition action button between generation dispatch and request cancellation based on active pipeline operations.
      if model.liveRequest != nil {
        Button {
          Task { await model.stop() }
        } label: {
          Image(systemName: "stop.fill").frame(width: 22, height: 22)
        }
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.circle)
        .tooltip("Stop generating")
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
        .tooltip("Send")
        .accessibilityLabel("Send")
      }
    }
    .focusesWhenShown($focused, conversationID: model.conversationID)
    .interceptsImagePaste(model) { focused }
    .watchesPasteboardImages($pasteboardHasImages)
    .clearsUndoHistory(on: model.programmaticTextEdits)
    .modifier(AttachmentImporters(model: model, showPhotos: $showPhotos, showFiles: $showFiles))
    .onChange(of: model.requestedPicker) { _, picker in
      guard let picker else { return }
      model.requestedPicker = nil
      switch picker {
      case .photos: showPhotos = true
      case .files: showFiles = true
      }
    }
    .onChange(of: showPhotos || showFiles) { _, isUp in model.isPickingAttachment = isUp }
    .onChange(of: model.isTextFieldFocused) { _, v in focused = v }
    .onChange(of: focused) { _, v in model.isTextFieldFocused = v }
  }
}
