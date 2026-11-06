import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Attachment source action menu presenting photo library, document pickers, and clipboard paste on macOS.
struct ComposerAddMenu: View {
  let model: ChatScreenModel
  @Binding var showPhotos: Bool
  @Binding var showFiles: Bool

  var body: some View {
    Menu {
      Button("Choose from Photos…", systemImage: "photo.on.rectangle") { showPhotos = true }
        .disabled(!model.canAddAttachments)
      Button("Choose File…", systemImage: "folder") { showFiles = true }
        .disabled(!model.canAddAttachments)
      Button("Paste Image", systemImage: "doc.on.clipboard") { pasteImage(into: model) }
        .disabled(!model.canAddAttachments)
      if !model.canAddAttachments {
        Text(ChatScreenModel.fullTrayHint)
      }
    } label: {
      Image(systemName: "plus").font(.title3).frame(width: Platform.circleButtonSize, height: Platform.circleButtonSize)
        .contentShape(Circle())
    }
    .chromelessMenu()
    .frame(width: Platform.circleButtonSize, height: Platform.circleButtonSize)
    .contentShape(Circle())
    .glassEffect(.regular.interactive(), in: .circle)
    .menuOrder(.fixed)
    .tooltip("Add images")
    .accessibilityLabel("Add images")
  }
}

/// Attaches image content from the system pasteboard or presents a feedback toast if none is present.
@MainActor
func pasteImage(into model: ChatScreenModel) {
  // Explicit invocation attaches image content even when companion text flavors are present.
  let candidates = SystemPasteboard.general.imageCandidates(preferringText: false)
  guard !candidates.isEmpty else {
    model.showToast("There's no image on the clipboard.")
    return
  }
  Task { await model.attach(candidates, from: .paste) }
}

/// Selection menu item displaying standard macOS checkmark state for active options.
struct MenuCheckItem: View {
  let title: String
  let isSelected: Bool
  let action: () -> Void

  var body: some View {
    Toggle(title, isOn: Binding(get: { isSelected }, set: { _ in action() }))
  }
}

/// No-op on macOS; clipboard paste operations are routed via menus and standard keyboard shortcuts.
struct ComposerPasteControl: View {
  let model: ChatScreenModel
  let hasImages: Bool

  var body: some View { EmptyView() }
}

extension View {
  /// Attaches descriptive tooltip text to interactive controls.
  func tooltip(_ text: String) -> some View { help(text) }

  /// Suppresses default button bezel rendering within custom glass containers.
  func chromelessButton() -> some View { buttonStyle(.plain).contentShape(Rectangle()) }

  /// Suppresses default menu bezel and disclosure indicator within custom glass containers.
  func chromelessMenu() -> some View { menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden) }

  /// Expands menu hit-testing area across enclosing capsule bounds.
  func pillHitShape() -> some View { contentShape(Capsule()) }

  /// Configures plain text field styling within custom enclosing frames.
  func framelessFieldStyle() -> some View { textFieldStyle(.plain) }

  /// No-op on macOS; pasteboard image presence monitoring is specific to iOS paste controls.
  func watchesPasteboardImages(_ hasImages: Binding<Bool>) -> some View { self }

  /// Centers content within readable column bounds for widescreen presentation.
  func readableColumn() -> some View {
    frame(maxWidth: 820).frame(maxWidth: .infinity)
  }

  /// Constrains inline reply image geometry within maximum display bounds and transcript height.
  func replyImageSizing(aspect: CGFloat) -> some View { modifier(ReplyImageFrame(aspect: aspect)) }

  /// Propagates enclosing transcript height down the view hierarchy for proportional image scaling.
  func providesTranscriptHeight() -> some View { modifier(TranscriptHeightProvider()) }

  /// Attaches double-click and accessibility activation triggers for image navigation.
  func opensOnDoubleClick(name: @autoclosure () -> String, _ action: @escaping () -> Void) -> some View {
    onTapGesture(count: 2, perform: action)
      .accessibilityLabel(name())
      .accessibilityAddTraits(.isButton)
      .accessibilityAction(.default, action)
      .focusable(interactions: .activate)
      .onKeyPress(.return) {
        action()
        return .handled
      }
  }

  /// Configures drag source providing an isolated, named file copy of the asset.
  func draggableImage(_ item: @autoclosure () -> ExportItem) -> some View {
    let file = item().file
    return onDrag { file.draggedCopyProvider() }
  }

  /// Anchors bubble geometry preferences for message action button positioning.
  func marksPromptBubble() -> some View { anchorPreference(key: PromptBubbleBounds.self, value: .bounds) { $0 } }

  /// Attaches contextual menu commands and hover-revealed action controls to message rows.
  func messageRowMenu<Menu: View>(isPrompt: Bool, @ViewBuilder _ menu: @escaping () -> Menu) -> some View {
    modifier(MessageRowMenu(isPrompt: isPrompt, menu: menu))
  }

  /// Overlays custom secondary click menu handling while preserving native text selection.
  func selectableTextMenu<Menu: View>(@ViewBuilder _ menu: @escaping () -> Menu) -> some View {
    overlay(SecondaryClickMenu(menu: menu))
  }

  /// Configures return key interception to trigger submission or multiline insertion.
  func composerKeys(canSend: Bool, send: @escaping () -> Void) -> some View {
    onKeyPress(.return, phases: .down) { press in
      if (NSApp.keyWindow?.firstResponder as? NSTextInputClient)?.hasMarkedText() == true { return .ignored }
      let mods = press.modifiers.subtracting([.capsLock, .numericPad])
      if mods.contains(.shift) || mods.contains(.option) {
        NSApp.sendAction(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), to: nil, from: nil)
        return .handled
      }
      guard mods.isEmpty || mods == .command else { return .ignored }
      if canSend { send() }
      return .handled
    }
  }

  /// Resets the window undo manager upon programmatic buffer replacements.
  func clearsUndoHistory(on revision: Int) -> some View {
    onChange(of: revision) { _, _ in
      DispatchQueue.main.async { NSApp.keyWindow?.undoManager?.removeAllActions() }
    }
  }

  /// Focuses the prompt composer when the parent conversation appears unless focus resides elsewhere.
  func focusesWhenShown(_ focus: FocusState<Bool>.Binding, conversationID: UUID) -> some View {
    modifier(ComposerAutoFocus(focus: focus, conversationID: conversationID))
  }

  /// Asserts initial keyboard focus on the bound state property.
  func takesInitialFocus(_ focus: FocusState<Bool>.Binding) -> some View {
    task {
      try? await Task.sleep(for: .milliseconds(150))
      focus.wrappedValue = true
    }
  }

  /// Configures drag-and-drop ingestion target for external image files and raw image data.
  func acceptsImageDrops(_ model: ChatScreenModel) -> some View { modifier(ImageDropTarget(model: model)) }

  /// Intercepts Command-V keystrokes to attach pasteboard images when text fields do not claim focus.
  func interceptsImagePaste(_ model: ChatScreenModel, isActive: @escaping () -> Bool) -> some View {
    background(
      EventMonitor(mask: .keyDown) { event in
        guard event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
          event.characters(byApplyingModifiers: .command) == "v",
          isActive() || !(event.window?.firstResponder is NSText)
        else { return false }
        let candidates = SystemPasteboard.general.imageCandidates()
        guard !candidates.isEmpty else { return false }
        Task { await model.attach(candidates, from: .paste) }
        return true
      })
  }

  /// Monitors vertical wheel and trackpad scroll gestures to inform transcript settling heuristics.
  func onUserWheelScroll(_ action: @escaping () -> Void) -> some View {
    background(
      EventMonitor(mask: .scrollWheel, onlyWithinBounds: true) { event in
        if event.phase != .mayBegin, abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) { action() }
        return false
      })
  }

  /// Suppresses bottom scroll edge bounce effects behind the opaque composer bar.
  func composerScrollEdge() -> some View { scrollEdgeEffectHidden(true, for: .bottom) }

  /// Background styling and border divider for the desktop composer bar.
  func composerBarSurface() -> some View {
    background(Color(nsColor: .windowBackgroundColor)).overlay(alignment: .top) { Divider() }
  }

  /// Applies bottom content margin to scrollable transcript content.
  func transcriptBottomMargin() -> some View { contentMargins(.bottom, 16, for: .scrollContent) }
}

/// View modifier applying proportional width constraints based on aspect ratio and transcript height.
private struct ReplyImageFrame: ViewModifier {
  let aspect: CGFloat
  @Environment(\.transcriptHeight) private var transcriptHeight

  func body(content: Self.Content) -> some View {
    content.frame(maxWidth: ReplyImageCap.maxWidth(aspect: aspect, transcriptHeight: transcriptHeight), alignment: .leading)
  }
}

/// Geometry reader propagating viewport height into the view hierarchy.
private struct TranscriptHeightProvider: ViewModifier {
  @State private var height: CGFloat?

  func body(content: Self.Content) -> some View {
    content
      .environment(\.transcriptHeight, height)
      .onGeometryChange(for: CGFloat.self) { $0.size.height.rounded() } action: { height = $0 }
  }
}

/// Preference key tracking prompt bubble bounds for overlay button alignment.
private struct PromptBubbleBounds: PreferenceKey {
  static var defaultValue: Anchor<CGRect>? { nil }

  static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
    value = value ?? nextValue()
  }
}

/// Contextual menu and hover button modifier for transcript message rows.
private struct MessageRowMenu<Items: View>: ViewModifier {
  let isPrompt: Bool
  let menu: () -> Items
  @State private var isHovering = false

  func body(content: Self.Content) -> some View {
    content
      .contentShape(Rectangle())
      .contextMenu(menuItems: menu)
      .overlayPreferenceValue(PromptBubbleBounds.self) { bubble in
        if isHovering {
          if isPrompt, let bubble {
            // Align action trigger adjacent to user prompt bubble.
            GeometryReader { row in
              button.position(x: row[bubble].minX - Self.buttonSize / 2 - 4, y: row[bubble].minY + Self.buttonSize / 2)
            }
          } else {
            button.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
          }
        }
      }
      .onHover { isHovering = $0 }
  }

  private static var buttonSize: CGFloat { 24 }

  private var button: some View {
    Menu(content: menu) {
      Image(systemName: "ellipsis").frame(width: Self.buttonSize, height: Self.buttonSize).contentShape(Circle())
    }
    .chromelessMenu()
    .frame(width: Self.buttonSize, height: Self.buttonSize)
    .glassEffect(.regular.interactive(), in: .circle)
    .tooltip("Message actions")
    .accessibilityLabel("Message actions")
  }
}

/// NSView host intercepting secondary mouse clicks to present an NSHostingMenu.
private struct SecondaryClickMenu<Items: View>: NSViewRepresentable {
  let menu: () -> Items

  func makeNSView(context: Context) -> SecondaryClickView { SecondaryClickView() }

  func updateNSView(_ view: SecondaryClickView, context: Context) {
    let menu = self.menu
    view.makeMenu = { NSHostingMenu(rootView: menu()) }
  }
}

final class SecondaryClickView: NSView {
  var makeMenu: () -> NSMenu? = { nil }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard let event = NSApp.currentEvent else { return nil }
    let isSecondary = event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
    return isSecondary ? super.hitTest(point) : nil
  }

  override func menu(for event: NSEvent) -> NSMenu? { makeMenu() }
}

/// Manages keyboard focus acquisition for the conversation prompt composer.
private struct ComposerAutoFocus: ViewModifier {
  let focus: FocusState<Bool>.Binding
  let conversationID: UUID
  @Environment(Navigator.self) private var navigator

  func body(content: Self.Content) -> some View {
    content
      .task {
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled else { return }
        if navigator.pendingComposerFocus == conversationID {
          navigator.pendingComposerFocus = nil
          focus.wrappedValue = true
        } else if !Self.keyboardIsElsewhere {
          focus.wrappedValue = true
        }
      }
      .onChange(of: navigator.pendingComposerFocus) { _, pending in
        guard pending == conversationID else { return }
        navigator.pendingComposerFocus = nil
        focus.wrappedValue = true
      }
  }

  /// Evaluates whether the sidebar list or another text input currently owns first responder.
  private static var keyboardIsElsewhere: Bool {
    let responder = NSApp.keyWindow?.firstResponder
    return responder is NSTableView || responder is NSText
  }
}

/// View modifier managing drag-and-drop image acceptance and visual drop target indicators.
private struct ImageDropTarget: ViewModifier {
  let model: ChatScreenModel
  @State private var targeted = false

  func body(content: Self.Content) -> some View {
    content
      .overlay {
        ImageDropReceiver(targeted: $targeted) { candidates, rejected in
          if rejected > 0 { model.showToast("Only images can be attached.") }
          guard !candidates.isEmpty else { return }
          Task { await model.attach(candidates, from: .drop) }
        } onDragEnded: {
          model.services.navigator.requestComposerFocus(for: model.conversationID)
        }
      }
      .overlay {
        if targeted {
          RoundedRectangle(cornerRadius: 12)
            .strokeBorder(Color.accentColor, lineWidth: 3)
            .background(Color.accentColor.opacity(0.08), in: .rect(cornerRadius: 12))
            .padding(6)
            .allowsHitTesting(false)
            .transition(.opacity)
        }
      }
      .animation(.easeOut(duration: 0.12), value: targeted)
  }
}

/// NSViewRepresentable bridging AppKit image drag reception to SwiftUI.
private struct ImageDropReceiver: NSViewRepresentable {
  @Binding var targeted: Bool
  let onDrop: ([AttachmentCandidate], _ rejected: Int) -> Void
  let onDragEnded: () -> Void

  func makeNSView(context: Context) -> ImageDropView { ImageDropView() }

  func updateNSView(_ view: ImageDropView, context: Context) {
    view.onTargeted = { targeted = $0 }
    view.onDrop = onDrop
    view.onDragEnded = onDragEnded
  }
}

/// AppKit view handling incoming drag sessions containing file URLs and image payloads.
final class ImageDropView: NSView {
  var onTargeted: (Bool) -> Void = { _ in }
  var onDrop: ([AttachmentCandidate], Int) -> Void = { _, _ in }
  var onDragEnded: () -> Void = {}
  private var acceptsDrag = false
  private var tookKeyboard = false

  init() {
    super.init(frame: .zero)
    var types: [NSPasteboard.PasteboardType] = [.fileURL]
    types += NSImage.imageTypes.filter { UTType($0)?.conforms(to: .image) == true }.map { NSPasteboard.PasteboardType($0) }
    registerForDraggedTypes(types)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  override func hitTest(_ point: NSPoint) -> NSView? {
    let eventType = NSApp.currentEvent?.type
    let isDragging = NSEvent.pressedMouseButtons & 1 != 0 && eventType != .leftMouseDown && eventType != .rightMouseDown
    guard isDragging, let types = NSPasteboard(name: .drag).types, types.contains(where: registeredDraggedTypes.contains) else { return nil }
    return super.hitTest(point)
  }

  override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
    let accepts = !SystemPasteboard(board: sender.draggingPasteboard)
      .imageContent(preferringText: false, readsDataNow: false).candidates.isEmpty
    onTargeted(accepts)
    acceptsDrag = accepts
    if accepts, window?.firstResponder is NSText {
      tookKeyboard = true
      window?.makeFirstResponder(nil)
    }
    return accepts ? .copy : []
  }

  override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { acceptsDrag ? .copy : [] }

  override func draggingExited(_ sender: (any NSDraggingInfo)?) {
    onTargeted(false)
    endDrag()
  }

  override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
    onTargeted(false)
    let content = SystemPasteboard(board: sender.draggingPasteboard).imageContent(preferringText: false, readsDataNow: true)
    onDrop(content.candidates, content.rejected)
    endDrag()
    return !content.candidates.isEmpty
  }

  private func endDrag() {
    guard tookKeyboard else { return }
    tookKeyboard = false
    onDragEnded()
  }
}

/// Window-level event monitor intercepting matching NSEvent types.
struct EventMonitor: NSViewRepresentable {
  let mask: NSEvent.EventTypeMask
  /// Restricts event handling to pointer locations within view bounds.
  var onlyWithinBounds = false
  let handler: @MainActor (NSEvent) -> Bool

  func makeNSView(context: Context) -> MonitorView {
    let view = MonitorView(mask: mask, onlyWithinBounds: onlyWithinBounds)
    view.handler = handler
    return view
  }

  func updateNSView(_ view: MonitorView, context: Context) { view.handler = handler }

  static func dismantleNSView(_ view: MonitorView, coordinator: ()) { view.removeMonitor() }
}

/// Underlying NSView managing local NSEvent monitoring tokens across window lifecycles.
final class MonitorView: NSView {
  private let mask: NSEvent.EventTypeMask
  private let onlyWithinBounds: Bool
  var handler: @MainActor (NSEvent) -> Bool = { _ in false }
  private var token: Any?

  init(mask: NSEvent.EventTypeMask, onlyWithinBounds: Bool) {
    self.mask = mask
    self.onlyWithinBounds = onlyWithinBounds
    super.init(frame: .zero)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    removeMonitor()
    guard window != nil else { return }
    token = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
      // Process local monitor callbacks on the main thread.
      nonisolated(unsafe) let event = event
      let swallowed = MainActor.assumeIsolated {
        guard let self, event.window === self.window else { return false }
        if self.onlyWithinBounds && !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) { return false }
        return self.handler(event)
      }
      return swallowed ? nil : event
    }
  }

  func removeMonitor() {
    if let token { NSEvent.removeMonitor(token) }
    token = nil
  }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

extension View {
  /// Applies maximum width constraints accounting for legacy scrollbar gutters.
  func scrollBarIndependentWidth(viewport: CGFloat?) -> some View { modifier(ScrollBarIndependentWidth(viewport: viewport)) }

  /// Measures outer scroll viewport width for layout constraint calculations.
  func measuresScrollViewportWidth(_ width: Binding<CGFloat?>) -> some View {
    frame(maxWidth: .infinity)
      .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width.wrappedValue = $0 }
  }

  /// Background styling for composer status pills and context chips on macOS.
  func composerControlSurface(_ scheme: ColorScheme, interactive: Bool = false) -> some View {
    overlay(Capsule().strokeBorder(.separator))
  }
}

private struct ScrollBarIndependentWidth: ViewModifier {
  let viewport: CGFloat?
  @State private var gutter = Self.currentGutter

  private static var currentGutter: CGFloat {
    NSScroller.preferredScrollerStyle == .legacy ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
  }

  func body(content: Self.Content) -> some View {
    content
      .frame(maxWidth: viewport.map { max($0 - gutter, 0) })
      .onReceive(NotificationCenter.default.publisher(for: NSScroller.preferredScrollerStyleDidChangeNotification)) { _ in
        gutter = Self.currentGutter
      }
  }
}
