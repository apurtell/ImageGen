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
    frame(maxWidth: TranscriptLayout.readableWidth).frame(maxWidth: .infinity)
  }

  /// Enforces readable line-length constraints on text blocks within expanded transcript columns.
  func readableMeasure(alignment: Alignment = .leading) -> some View {
    frame(maxWidth: TranscriptLayout.readableWidth, alignment: alignment)
  }

  /// Constrains reply image and placeholder dimensions to responsive column width and vertical viewport limits.
  func replyImageSizing(aspect: CGFloat) -> some View { modifier(ReplyImageFrame(aspect: aspect)) }

  /// Reserves vertical space in placeholder cards matching expected metadata and textual content to prevent layout shifts upon completion.
  func replyFooterSizing(expectsText: Bool) -> some View { modifier(ReplyFooterHeight(expectsText: expectsText)) }

  /// Propagates enclosing viewport dimensions to child transcript views, notifying observers on dimension changes.
  func measuresTranscriptViewport(onChange: @escaping () -> Void) -> some View {
    modifier(TranscriptViewportProvider(onChange: onChange))
  }

  /// Propagates row layout geometry to coordinate scroll anchor preservation across viewport resizes.
  func reportsTranscriptRow(id: UUID, to reflow: TranscriptReflow) -> some View { modifier(TranscriptRowReport(id: id, reflow: reflow)) }

  /// Tags the primary input field view hierarchy to enable keystroke forwarding from the sidebar.
  func marksComposerField() -> some View { background(ComposerFieldAnchor()) }

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

  func body(content: Self.Content) -> some View {
    content
      .environment(\.transcriptViewport, size)
      .environment(\.transcriptGutter, gutter)
      .onGeometryChange(for: CGSize.self) {
        CGSize(width: $0.size.width.rounded(), height: $0.size.height.rounded())
      } action: { new in
        if size != nil { onChange() }
        size = new
      }
      .onReceive(NotificationCenter.default.publisher(for: NSScroller.preferredScrollerStyleDidChangeNotification)) { _ in
        let new = Self.currentGutter
        guard new != gutter else { return }
        onChange()
        gutter = new
      }
  }
}

extension EnvironmentValues {
  /// Lateral margin clearance reserved to accommodate persistent legacy scrollbars without shifting content.
  @Entry fileprivate var transcriptGutter: CGFloat = 0
}

/// Structural marker view identifying the backing NSTextView within the AppKit hierarchy.
private struct ComposerFieldAnchor: NSViewRepresentable {
  func makeNSView(context: Context) -> ComposerFieldAnchorView { ComposerFieldAnchorView() }

  func updateNSView(_ view: ComposerFieldAnchorView, context: Context) {}
}

final class ComposerFieldAnchorView: NSView {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  /// Immediately assigns AppKit first responder focus to the composer text view, positioning the insertion point at the end of existing draft text.
  static func takeKeyboard(in window: NSWindow) {
    guard let root = window.contentView, let anchor = first(ComposerFieldAnchorView.self, in: root),
      let field = anchor.fieldOverAnchor(in: root), window.makeFirstResponder(field)
    else { return }
    if let editor = (field as? NSTextField)?.currentEditor() ?? (field as? NSTextView) {
      editor.selectedRange = NSRange(location: (editor.string as NSString).length, length: 0)
    }
  }

  private func fieldOverAnchor(in root: NSView) -> NSView? {
    let center = convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil)
    func search(_ view: NSView) -> NSView? {
      if view.isHidden { return nil }
      let isField = (view as? NSTextField)?.isEditable == true || (view as? NSTextView)?.isEditable == true
      if isField, view.bounds.contains(view.convert(center, from: nil)) { return view }
      for subview in view.subviews {
        if let found = search(subview) { return found }
      }
      return nil
    }
    return search(root)
  }

  /// Iterative view hierarchy traversal avoiding closure re-evaluation overhead during deep search passes.
  private static func first<View: NSView>(_ type: View.Type, in view: NSView) -> View? {
    if let found = view as? View { return found }
    for subview in view.subviews {
      if let found = first(type, in: subview) { return found }
    }
    return nil
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
        if targeted { ImageDropHighlight().transition(.opacity) }
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
  /// Centers transcript content within an invariant column width calculated independently of scrollbar presence.
  ///
  /// Under legacy scrollbar modes ("Show scroll bars: Always"), scrollbar appearance consumes layout width
  /// when content vertically overflows. Content whose vertical height derives from its width (such as aspect-ratio-locked cards)
  /// can trigger unstable layout oscillations if scrollbar presence alters available width. By computing maximum width
  /// and gutter offsets directly from the invariant outer window frame, the column remains stable and centered.
  func scrollBarIndependentColumn(reflow: TranscriptReflow) -> some View { modifier(ScrollBarIndependentColumn(reflow: reflow)) }

  /// Expands container bounds to encompass full available window width.
  func fillsTranscriptWidth() -> some View { frame(maxWidth: .infinity) }

  /// Background styling for composer status pills and context chips on macOS.
  func composerControlSurface(_ scheme: ColorScheme, interactive: Bool = false) -> some View {
    overlay(Capsule().strokeBorder(.separator))
  }
}

/// Non-lazy transcript stack ensuring authoritative layout geometry calculation for all message rows.
/// Unlike lazy vertical stacks whose estimated content heights drift significantly when window resizing mutates aspect-constrained row heights,
/// eager layout guarantees accurate scroll offsets and avoids blank viewport artifacts during continuous window resizing.
struct TranscriptStack<Content: View>: View {
  let spacing: CGFloat
  @ViewBuilder let content: Content

  var body: some View {
    VStack(spacing: spacing) { content }
  }
}

private struct ScrollBarIndependentColumn: ViewModifier {
  let reflow: TranscriptReflow
  @Environment(\.transcriptViewport) private var viewport
  @Environment(\.transcriptGutter) private var gutter

  func body(content: Self.Content) -> some View {
    content
      .frame(
        maxWidth: viewport.map { TranscriptLayout.columnWidth(viewportWidth: $0.width, gutter: gutter) } ?? TranscriptLayout.readableWidth)
      .frame(maxWidth: .infinity, alignment: .leading)
      .offset(x: viewport.map { TranscriptLayout.columnOrigin(viewportWidth: $0.width, gutter: gutter) } ?? 0)
      .coordinateSpace(.named(TranscriptContent.coordinateSpace))
      .background(TranscriptScrollHandle(reflow: reflow))
  }
}

/// NSViewRepresentable bridge binding native NSScrollView clip view geometry and programmatic scrolling to TranscriptReflow.
private struct TranscriptScrollHandle: NSViewRepresentable {
  let reflow: TranscriptReflow

  func makeNSView(context: Context) -> TranscriptScrollHandleView { TranscriptScrollHandleView() }

  func updateNSView(_ view: TranscriptScrollHandleView, context: Context) {
    reflow.scrollTo = { [weak view] visibleTop, topInset in view?.scroll(toVisibleTop: visibleTop, topInset: topInset) }
    reflow.position = { [weak view] in view?.position }
    view.onScrollViewChange = { [weak reflow] in reflow?.scrollViewDidChange() }
  }
}

final class TranscriptScrollHandleView: NSView {
  /// Notification handler fired on clip view bounds or document frame mutations, extracting updated scroll metrics.
  var onScrollViewChange: (() -> Void)?

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    let center = NotificationCenter.default
    center.removeObserver(self)
    guard window != nil, let scrollView = enclosingScrollView else { return }
    let clip = scrollView.contentView
    clip.postsBoundsChangedNotifications = true
    clip.postsFrameChangedNotifications = true
    center.addObserver(self, selector: #selector(scrollViewChanged), name: NSView.boundsDidChangeNotification, object: clip)
    center.addObserver(self, selector: #selector(scrollViewChanged), name: NSView.frameDidChangeNotification, object: clip)
    guard let document = scrollView.documentView else { return }
    document.postsFrameChangedNotifications = true
    center.addObserver(self, selector: #selector(scrollViewChanged), name: NSView.frameDidChangeNotification, object: document)
  }

  @objc private func scrollViewChanged() {
    onScrollViewChange?()
  }

  /// Computes authoritative scroll offset and trailing bottom distance directly from NSClipView geometry.
  var position: (offset: CGFloat, distanceFromBottom: CGFloat)? {
    guard let scrollView = enclosingScrollView, let document = scrollView.documentView else { return nil }
    let clip = scrollView.contentView.bounds
    return (clip.minY, document.frame.maxY + scrollView.contentInsets.bottom - clip.maxY)
  }

  /// Directly positions NSClipView bounds origin, enabling programmatic scroll repositioning during active layout passes without violating SwiftUI state mutation rules.
  func scroll(toVisibleTop visibleTop: CGFloat, topInset: CGFloat) {
    guard let scrollView = enclosingScrollView else { return }
    let clip = scrollView.contentView
    let lastOffset = (scrollView.documentView?.frame.maxY ?? 0) + scrollView.contentInsets.bottom - clip.bounds.height
    let wanted = visibleTop.isFinite ? visibleTop - topInset : lastOffset
    var bounds = clip.bounds
    bounds.origin.y = wanted
    let origin = clip.constrainBoundsRect(bounds).origin
    guard abs(origin.y - clip.bounds.minY) > 0.25 else { return }
    clip.scroll(to: origin)
    scrollView.reflectScrolledClipView(clip)
  }
}
