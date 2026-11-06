import AppKit
import SwiftUI

/// Application menu bar builder installing File, Edit, View, Chat, Image, and Developer command menus.
///
/// Dynamically routes commands to key window focus targets, routing image operations to either
/// the dedicated image viewer window or the active conversation's trailing image asset.
struct MacCommands: Commands {
  let env: AppEnvironment?
  @FocusedValue(\.chatCommands) private var chat

  var body: some Commands {
    SidebarCommands()
    TextEditingCommands()
    CommandGroup(replacing: .appInfo) {
      Button("About ImageGen") { Self.showAboutPanel() }
    }
    CommandGroup(replacing: .newItem) {
      if let env { NewChatItems(env: env, chat: chat) }
    }
    CommandGroup(after: .saveItem) {
      if env != nil { SaveImageItem(chat: chat) }
    }
    CommandGroup(after: .pasteboard) {
      Button("Paste Image") { chat?.pasteImage() }
        .disabled(chat?.canAddImages != true || chat?.isPresenting == true)
    }
    CommandGroup(after: .toolbar) {
      Button("Jump to Latest") { chat?.jumpToLatest() }
        .keyboardShortcut(.downArrow, modifiers: [.command, .option])
        .disabled(chat?.canJumpToLatest != true)
      if env != nil { ViewerViewItems() }
    }
    CommandMenu("Chat") { ChatItems(chat: chat) }
    CommandMenu("Image") {
      if env != nil { ImageItems(chat: chat) }
    }
    CommandMenu("Developer") {
      if let env { DeveloperMenuItems(model: env.developerMenu, navigator: env.navigator) }
    }
    CommandGroup(replacing: .help) {
      Link("ImageGen Help", destination: URL(string: "https://github.com/apurtell/ImageGen#readme")!)
    }
  }

  /// Presents standard system about panel configured with SynthID disclosure credits.
  private static func showAboutPanel() {
    let note = NSAttributedString(
      string: "Images made by Gemini carry Google's invisible SynthID watermark.",
      attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.secondaryLabelColor])
    NSApp.orderFrontStandardAboutPanel(options: [.credits: note])
    NSApp.activate()
  }
}

/// File menu items for conversation creation and deletion.
private struct NewChatItems: View {
  let env: AppEnvironment
  let chat: ChatCommandHandle?

  var body: some View {
    Button("New Chat") { newChat() }
      .keyboardShortcut("n")
      // Disable conversation lifecycle operations during onboarding and modal presentations.
      .disabled(env.navigator.needsOnboarding || chat?.isPresenting == true)
    Divider()
    Button("Delete Chat…") { chat?.delete() }
      .keyboardShortcut(.delete, modifiers: [.command, .option])
      .disabled(chat == nil || chat?.isPresenting == true)
  }

  /// Creates a new conversation and brings the main window to the foreground.
  private func newChat() {
    MacAppDelegate.showMainWindow()
    Task {
      guard let id = await env.chatActions.newChat() else { return }
      env.navigator.open(id)
      env.navigator.requestComposerFocus(for: id)
    }
  }
}

/// Contextual menu commands targeting the active conversation and prompt composer.
private struct ChatItems: View {
  let chat: ChatCommandHandle?

  private var isBlocked: Bool { chat == nil || chat?.isPresenting == true }

  var body: some View {
    Button("Send") { chat?.send() }
      .keyboardShortcut(.return, modifiers: .command)
      .disabled(chat?.canSend != true || isBlocked)
    Button("Stop Generating") { chat?.stop() }
      .keyboardShortcut(".")
      .disabled(chat?.canStop != true)
    Divider()
    Button("Choose from Photos…") { chat?.choosePhotos() }
      .disabled(chat?.canAddImages != true || isBlocked)
    Button("Choose File…") { chat?.chooseFiles() }
      .keyboardShortcut("o")
      .disabled(chat?.canAddImages != true || isBlocked)
    Divider()
    Button("Regenerate Last Reply") { chat?.regenerateLastReply?() }
      .disabled(chat?.regenerateLastReply == nil || isBlocked)
    Button("Edit and Resend Last Prompt") { chat?.editLastPrompt?() }
      .disabled(chat?.editLastPrompt == nil || isBlocked)
    Button("Last Reply Info") { chat?.lastReplyInfo?() }
      .disabled(chat?.lastReplyInfo == nil || isBlocked)
    Button("Delete Last Message…") { chat?.deleteLastMessage?() }
      .disabled(chat?.deleteLastMessage == nil || isBlocked)
    Divider()
    Button("Rename") { chat?.rename() }
      .keyboardShortcut("r", modifiers: [.command, .shift])
      .disabled(isBlocked)
    Button("Chat Settings…") { chat?.showSettings() }
      .keyboardShortcut(",", modifiers: [.command, .option])
      .disabled(isBlocked)
  }
}

/// Resolves the active dispatch target for image operations based on window key status.
@MainActor
private struct ImageCommandTarget {
  let export: (ImageExportAction) -> Void
  let editFromHere: () -> Void
  let view: (() -> Void)?
  let info: (() -> Void)?

  static func current(chat: ChatCommandHandle?) -> ImageCommandTarget? {
    let viewer = ViewerWindowController.shared
    if viewer.isKey {
      let router = viewer.router
      return ImageCommandTarget(export: { router.export($0) }, editFromHere: { router.editFromHere() }, view: nil, info: { router.showInfo() })
    }
    guard chat?.isPresenting != true, let image = chat?.latestImage else { return nil }
    return ImageCommandTarget(export: image.export, editFromHere: image.editFromHere, view: image.view, info: nil)
  }
}

/// File menu item dispatching asset file export.
private struct SaveImageItem: View {
  let chat: ChatCommandHandle?

  var body: some View {
    let target = ImageCommandTarget.current(chat: chat)
    Button("\(ViewerWindowController.shared.isKey ? "Save Image As…" : "Save Latest Image As…")") { target?.export(.files) }
      .keyboardShortcut("s", modifiers: [.command, .shift])
      .disabled(target == nil)
  }
}

/// Image menu commands providing export, editing, and inspection workflows.
private struct ImageItems: View {
  let chat: ChatCommandHandle?

  var body: some View {
    let target = ImageCommandTarget.current(chat: chat)
    Button("View Latest Image") { target?.view?() }
      .disabled(target?.view == nil)
    Divider()
    Button(Platform.editFromHereTitle) { target?.editFromHere() }
      .disabled(target == nil)
    Button("Save to Photos") { target?.export(.photos) }
      .disabled(target == nil)
    Button("Share…") { target?.export(.share) }
      .disabled(target == nil)
    Button(Platform.copyImageTitle) { target?.export(.copy) }
      .disabled(target == nil)
    Divider()
    Button(Platform.infoTitle) { target?.info?() }
      .keyboardShortcut("i")
      .disabled(target?.info == nil)
  }
}

/// View menu commands forwarding discrete magnification and paging shortcuts to the image viewer.
private struct ViewerViewItems: View {
  private var viewer: ViewerWindowController { .shared }

  var body: some View {
    Divider()
    Button("Zoom In") { viewer.router.zoom(.zoomIn) }
      .keyboardShortcut("=")
      .disabled(!viewer.isKey)
    Button("Zoom Out") { viewer.router.zoom(.zoomOut) }
      .keyboardShortcut("-")
      .disabled(!viewer.isKey)
    Button("Actual Size") { viewer.router.zoom(.actualSize) }
      .keyboardShortcut("1")
      .disabled(!viewer.isKey)
    Button("Zoom to Fit") { viewer.router.zoom(.fit) }
      .keyboardShortcut("0")
      .disabled(!viewer.isKey)
    Divider()
    Button("Previous Image") { viewer.router.move(-1) }
      .keyboardShortcut("[")
      .disabled(!viewer.isKey || !viewer.canMoveBack)
    Button("Next Image") { viewer.router.move(1) }
      .keyboardShortcut("]")
      .disabled(!viewer.isKey || !viewer.canMoveForward)
  }
}

/// Developer menu commands presenting diagnostic activity log inspection windows and maintenance actions.
private struct DeveloperMenuItems: View {
  let model: DeveloperMenuModel
  let navigator: Navigator
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Button("Last Action") { present(.lastAction) }
    Button("Last Error") { present(.lastError) }
      .disabled(!model.hasError)
    Button("Full Log") { present(.fullLog) }
    Divider()
    Button("Clear Log…") {
      MacAppDelegate.showMainWindow()
      model.confirmingClear = true
    }
    // Disable log purge confirmation during initial onboarding flows.
    .disabled(navigator.needsOnboarding)
  }

  private func present(_ kind: LogViewerModel.Kind) {
    model.present(kind)
    openWindow(id: LogWindow.id)
    NSApp.activate()
  }
}

/// Dedicated window scene hosting diagnostic activity log inspection views.
struct LogWindow: View {
  static let id = "log"
  /// Window scene title and corresponding Window menu identifier.
  static let title = "Activity Log"
  let model: DeveloperMenuModel

  /// Active log presentation kind, defaulting to full log view when opened without a specific target.
  private var kind: LogViewerModel.Kind { model.requested ?? .fullLog }

  var body: some View {
    LogViewerSheet(
      model: LogViewerModel(
        kind: kind, log: model.log,
        startingAt: kind == .lastAction ? model.lastActionID : kind == .lastError ? model.lastErrorID : nil)
    )
    .id(model.presentation)
    .frame(minWidth: 640, minHeight: 420)
  }
}
