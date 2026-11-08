import GameController
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Attachment source action menu presenting photo library and document pickers on iOS.
struct ComposerAddMenu: View {
  let model: ChatScreenModel
  @Binding var showPhotos: Bool
  @Binding var showFiles: Bool

  var body: some View {
    Menu {
      Button("Photo Library", systemImage: "photo.on.rectangle") { showPhotos = true }
        .disabled(!model.canAddAttachments)
      Button("Files", systemImage: "folder") { showFiles = true }
        .disabled(!model.canAddAttachments)
      if !model.canAddAttachments {
        Text(ChatScreenModel.fullTrayHint)
      }
    } label: {
      Image(systemName: "plus").font(.title3).frame(width: Platform.circleButtonSize, height: Platform.circleButtonSize)
    }
    .glassEffect(.regular.interactive(), in: .circle)
    .padHoverEffect()
    .menuOrder(.fixed)
    .accessibilityLabel("Add images")
  }
}

/// No-op programmatic paste dispatch on iOS.
@MainActor
func pasteImage(into model: ChatScreenModel) {}

/// Selection menu item displaying checkmark iconography for selected options.
struct MenuCheckItem: View {
  let title: String
  let isSelected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      if isSelected { Label(title, systemImage: "checkmark") } else { Text(title) }
    }
  }
}

/// Conditional presentation wrapper displaying the system paste button when image data is present.
struct ComposerPasteControl: View {
  let model: ChatScreenModel
  let hasImages: Bool

  var body: some View {
    if hasImages && model.canAddAttachments {
      ComposerPasteButton(model: model)
    }
  }
}

extension View {
  /// Attaches descriptive tooltip help text to interactive controls on iPad.
  @ViewBuilder
  func tooltip(_ text: String) -> some View {
    if Platform.isPad { help(text) } else { self }
  }

  /// Attaches system pointer hover interactions on supported iPad hardware.
  func padHoverEffect() -> some View { hoverEffect(.automatic, isEnabled: Platform.isPad) }

  /// Suppresses default button bezel rendering within custom glass containers.
  func chromelessButton() -> some View { padHoverEffect() }

  /// Preserves standard menu styling within glass containers on iOS.
  func chromelessMenu() -> some View { self }

  /// Retains default menu hit-testing geometry on iOS.
  func pillHitShape() -> some View { self }

  /// Retains standard text field styling on iOS.
  func framelessFieldStyle() -> some View { self }

  /// Subscribes to pasteboard image changes to update attachment control visibility.
  func watchesPasteboardImages(_ hasImages: Binding<Bool>) -> some View {
    modifier(PasteboardImageWatcher(hasImages: hasImages))
  }

  /// Adjusts composer column width between full window extent in stack layouts and constrained reading widths in split layouts.
  func readableColumn() -> some View { inSplitLayout(ReadableColumn()) }

  /// Applies responsive reply image constraints, expanding to full container width in stack layouts while following TranscriptLayout rules in split layouts.
  func replyImageSizing(aspect: CGFloat) -> some View { inSplitLayout(ReplyImageFrame(aspect: aspect)) }

  /// Computes placeholder reply card footer height based on navigation layout presentation.
  func replyFooterSizing(expectsText: Bool) -> some View { inSplitLayout(ReplyFooterHeight(expectsText: expectsText)) }

  /// Constrains text lines and status cards to optimal line-length bounds in split view presentation while utilizing full width in stack presentation.
  func readableMeasure(alignment: Alignment = .leading) -> some View { inSplitLayout(ReadableMeasure(alignment: alignment)) }

  /// Propagates outer viewport dimensions to the transcript view hierarchy in split navigation layouts.
  func measuresTranscriptViewport(onChange: @escaping () -> Void) -> some View { inSplitLayout(PadTranscriptViewport(onChange: onChange)) }

  /// Propagates row layout geometry to coordinate scroll anchor reflow in split navigation layouts.
  func reportsTranscriptRow(id: UUID, to reflow: TranscriptReflow) -> some View { inSplitLayout(TranscriptRowReport(id: id, reflow: reflow)) }

  /// Tracks the first visible message row identifier in stack layouts to seed scroll anchor restoration upon transitioning to split layouts.
  @ViewBuilder
  func tracksFirstVisibleRow(in reflow: TranscriptReflow) -> some View {
    if Platform.isPad {
      onScrollTargetVisibilityChange(idType: UUID.self, threshold: 0.01) { reflow.firstVisibleRow = $0.first }
    } else {
      self
    }
  }

  /// Key forwarding from sidebar to composer is not supported on iOS.
  func marksComposerField() -> some View { self }

  /// Configures multi-tap and secondary pointer gesture recognizers for fullscreen image presentation.
  @ViewBuilder
  func opensOnDoubleClick(name: @autoclosure () -> String, _ action: @escaping () -> Void) -> some View {
    if Platform.isPad { onTapGesture(count: 2, perform: action) } else { self }
  }

  /// No-op modifier; drag-out file exporting is handled via share sheets on iOS.
  func draggableImage(_ item: @autoclosure () -> ExportItem) -> some View { self }

  /// No-op layout anchor on iOS.
  func marksPromptBubble() -> some View { self }

  /// Binds contextual action menus to long-press gestures on iOS.
  func messageRowMenu<Menu: View>(isPrompt: Bool, @ViewBuilder _ menu: () -> Menu) -> some View { contextMenu(menuItems: menu) }

  /// Preserves native text selection and contextual menu interaction on iOS.
  func selectableTextMenu<Menu: View>(@ViewBuilder _ menu: @escaping () -> Menu) -> some View { self }

  /// Intercepts hardware keyboard Return keystrokes on iPad, routing Return and Command-Return to send operations
  /// while mapping Shift-Return and Option-Return to multiline text insertion, respecting active input method composition.
  @ViewBuilder
  func composerKeys(canSend: Bool, send: @escaping () -> Void) -> some View {
    if Platform.isPad {
      onKeyPress(.return, phases: .down) { press in
        if ComposerKeyboard.isComposingText { return .ignored }
        let mods = press.modifiers.subtracting([.capsLock, .numericPad])
        if mods.contains(.shift) || mods.contains(.option) {
          ComposerKeyboard.insertNewline()
          return .handled
        }
        guard mods.isEmpty || mods == .command else { return .ignored }
        if canSend { send() }
        return .handled
      }
    } else {
      self
    }
  }

  /// Automatically assigns focus to the primary input field upon navigation on iPad when a hardware keyboard is attached.
  @ViewBuilder
  func focusesWhenShown(_ focus: FocusState<Bool>.Binding, conversationID: UUID) -> some View {
    if Platform.isPad { modifier(PadComposerFocus(focus: focus, conversationID: conversationID)) } else { self }
  }

  /// Preserves manual touch-driven keyboard focus behavior on iOS.
  func takesInitialFocus(_ focus: FocusState<Bool>.Binding) -> some View { self }

  /// Relies on system text field undo management on iOS.
  func clearsUndoHistory(on revision: Int) -> some View { self }

  /// Configures scroll edge background styling, rendering a translucent backdrop behind composer controls in split layouts.
  func composerScrollEdge() -> some View { inSplitLayout(HardComposerEdge()) }

  /// Preserves translucent floating composer bar presentation on iOS.
  func composerBarSurface() -> some View { self }

  /// Retains standard transcript content inset on iOS.
  func transcriptBottomMargin() -> some View { self }

  /// Configures drag-and-drop ingestion target for image assets on iPad.
  @ViewBuilder
  func acceptsImageDrops(_ model: ChatScreenModel) -> some View {
    if Platform.isPad { modifier(PadImageDropTarget(model: model)) } else { self }
  }

  /// No-op paste interceptor; pasteboard attachments use dedicated controls on iOS.
  func interceptsImagePaste(_ model: ChatScreenModel, isActive: @escaping () -> Bool) -> some View { self }

  /// No-op scroll listener; scroll phase tracking captures interactive gestures on iOS.
  func onUserWheelScroll(_ action: @escaping () -> Void) -> some View { self }
}

/// Conditionally applies layout modifier when rendered within split navigation presentation.
private struct InSplitLayout<Wrapper: ViewModifier>: ViewModifier {
  let wrapper: Wrapper
  @Environment(\.navigationLayout) private var layout

  func body(content: Self.Content) -> some View {
    if layout == .split { content.modifier(wrapper) } else { content }
  }
}

extension View {
  fileprivate func inSplitLayout<Wrapper: ViewModifier>(_ wrapper: Wrapper) -> some View {
    modifier(InSplitLayout(wrapper: wrapper))
  }
}

private struct HardComposerEdge: ViewModifier {
  func body(content: Self.Content) -> some View {
    content.scrollEdgeEffectStyle(.hard, for: .bottom)
  }
}

private struct ReadableColumn: ViewModifier {
  func body(content: Self.Content) -> some View {
    content.frame(maxWidth: TranscriptLayout.readableWidth).frame(maxWidth: .infinity)
  }
}

private struct ReadableMeasure: ViewModifier {
  let alignment: Alignment

  func body(content: Self.Content) -> some View {
    content.frame(maxWidth: TranscriptLayout.readableWidth, alignment: alignment)
  }
}

/// Measures outer transcript dimensions excluding software keyboard insets, ensuring stable image sizing across keyboard presentations.
private struct PadTranscriptViewport: ViewModifier {
  let onChange: () -> Void
  @State private var size: CGSize?

  func body(content: Self.Content) -> some View {
    content
      .environment(\.transcriptViewport, size)
      .background {
        // Geometry reader positioned outside safe area ignore modifiers to isolate base window dimensions.
        Color.clear
          .onGeometryChange(for: CGSize.self) {
            CGSize(width: $0.size.width.rounded(), height: $0.size.height.rounded())
          } action: { new in
            if size != nil { onChange() }
            size = new
          }
          .ignoresSafeArea(.keyboard)
      }
  }
}

/// Adapts vertical stack layout strategy, utilizing an eager stack in split layouts to calculate accurate row geometries for reflow,
/// and a lazy stack in standard stack layouts.
struct TranscriptStack<Content: View>: View {
  let spacing: CGFloat
  @ViewBuilder let content: Content
  @Environment(\.navigationLayout) private var layout

  var body: some View {
    if layout == .split {
      VStack(spacing: spacing) { content }
        .scrollTargetLayout()
    } else {
      LazyVStack(spacing: spacing) { content }
        .scrollTargetLayout()
    }
  }
}

/// Centers transcript content within maximum width constraints derived from container viewport dimensions.
private struct PadTranscriptColumn: ViewModifier {
  let reflow: TranscriptReflow
  @Environment(\.transcriptViewport) private var viewport

  func body(content: Self.Content) -> some View {
    content
      .frame(maxWidth: viewport.map { TranscriptLayout.columnWidth(viewportWidth: $0.width) } ?? TranscriptLayout.readableWidth)
      .frame(maxWidth: .infinity)
      .coordinateSpace(.named(TranscriptContent.coordinateSpace))
      .background(TranscriptScrollHandle(reflow: reflow))
  }
}

/// UIViewRepresentable bridge connecting UIScrollView geometry and programmatic scrolling to TranscriptReflow.
private struct TranscriptScrollHandle: UIViewRepresentable {
  let reflow: TranscriptReflow

  func makeUIView(context: Context) -> TranscriptScrollHandleView { TranscriptScrollHandleView() }

  func updateUIView(_ view: TranscriptScrollHandleView, context: Context) {
    reflow.scrollTo = { [weak view] visibleTop, topInset in view?.scroll(toVisibleTop: visibleTop, topInset: topInset) }
    reflow.position = { [weak view] in view?.position }
    view.onScrollViewChange = { [weak reflow] in reflow?.scrollViewDidChange() }
  }
}

final class TranscriptScrollHandleView: UIView {
  /// Synchronizes scroll metrics following UIScrollView bounds, contentOffset, or contentSize modifications.
  var onScrollViewChange: (() -> Void)?
  private var observations: [NSKeyValueObservation] = []

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    for name in [UIResponder.keyboardWillHideNotification, UIResponder.keyboardDidHideNotification] {
      NotificationCenter.default.addObserver(self, selector: #selector(keyboardWentAway), name: name, object: nil)
    }
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    observations = []
    guard window != nil, let scrollView else { return }
    let changed: @Sendable () -> Void = { [weak self] in
      MainActor.assumeIsolated { self?.onScrollViewChange?() }
    }
    observations = [
      scrollView.observe(\.contentOffset) { _, _ in changed() },
      scrollView.observe(\.contentSize) { _, _ in changed() },
      scrollView.observe(\.bounds) { _, _ in changed() },
    ]
  }

  /// Schedules scroll correction on the next run loop pass to allow keyboard inset animations to complete.
  @objc private func keyboardWentAway() {
    DispatchQueue.main.async { [weak self] in self?.pullBackIfPastEnd() }
  }

  private var scrollView: UIScrollView? {
    sequence(first: self as UIView, next: \.superview).lazy.compactMap { $0 as? UIScrollView }.first
  }

  /// Computes maximum allowable vertical contentOffset before overscroll.
  private func lastOffset(of scrollView: UIScrollView) -> CGFloat {
    let insets = scrollView.adjustedContentInset
    return max(scrollView.contentSize.height + insets.bottom - scrollView.bounds.height, -insets.top)
  }

  /// Extracts authoritative scroll offset and trailing bottom distance directly from underlying UIScrollView presentation state.
  var position: (offset: CGFloat, distanceFromBottom: CGFloat)? {
    guard let scrollView else { return nil }
    let offset = scrollView.contentOffset.y
    return (offset, scrollView.contentSize.height + scrollView.adjustedContentInset.bottom - scrollView.bounds.height - offset)
  }

  /// Adjusts UIScrollView contentOffset when keyboard dismissal reduces bottom insets, preventing detached overscroll while preserving interactive rubber-banding.
  private func pullBackIfPastEnd() {
    guard let scrollView, !scrollView.isTracking, !scrollView.isDragging, !scrollView.isDecelerating else { return }
    let last = lastOffset(of: scrollView)
    guard scrollView.contentOffset.y > last + 0.5 else { return }
    scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: last), animated: false)
  }

  /// Directly mutates UIScrollView contentOffset, allowing programmatic repositioning during active layout passes.
  func scroll(toVisibleTop visibleTop: CGFloat, topInset: CGFloat) {
    guard let scrollView else { return }
    let last = lastOffset(of: scrollView)
    let wanted = visibleTop.isFinite ? visibleTop - topInset : last
    let offset = min(max(wanted, -scrollView.adjustedContentInset.top), last)
    guard abs(offset - scrollView.contentOffset.y) > 0.25 else { return }
    scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: offset), animated: false)
  }
}

/// Inspects active UIResponder text input context to determine text composition and formatting state.
@MainActor
private enum ComposerKeyboard {
  /// Indicates whether the active text input is composing marked text within an input method.
  static var isComposingText: Bool { field?.markedTextRange != nil }

  /// Inserts a newline character at the current insertion point.
  static func insertNewline() { field?.insertText("\n") }

  private static var field: UITextInput? {
    let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
    return windows.first(where: \.isKeyWindow).flatMap(firstResponder) as? UITextInput
  }

  /// Iterative view hierarchy traversal avoiding closure re-evaluation overhead during deep search passes.
  private static func firstResponder(in view: UIView) -> UIView? {
    if view.isFirstResponder { return view }
    for subview in view.subviews {
      if let found = firstResponder(in: subview) { return found }
    }
    return nil
  }
}

/// Manages programmatic keyboard focus acquisition for the composer input field on iPad when external keyboards are attached.
private struct PadComposerFocus: ViewModifier {
  let focus: FocusState<Bool>.Binding
  let conversationID: UUID
  @Environment(Navigator.self) private var navigator

  private var isDue: Bool { navigator.pendingComposerFocus == conversationID && !navigator.isChatCovered }

  func body(content: Self.Content) -> some View {
    content.task(id: isDue) {
      guard isDue else { return }
      do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
      navigator.pendingComposerFocus = nil
      if GCKeyboard.coalesced != nil { focus.wrappedValue = true }
    }
  }
}

/// Configures drop destination for image assets, providing visual drag boundary highlights.
private struct PadImageDropTarget: ViewModifier {
  let model: ChatScreenModel
  @State private var targeted = false

  func body(content: Self.Content) -> some View {
    content
      .onDrop(of: [.image], isTargeted: $targeted) { providers in
        let candidates = providers.map(AttachmentCandidate.dropped)
        Task { await model.attach(candidates, from: .drop) }
        return !candidates.isEmpty
      }
      .overlay {
        if targeted { ImageDropHighlight().transition(.opacity) }
      }
      .animation(.easeOut(duration: 0.12), value: targeted)
  }
}

extension AttachmentCandidate {
  /// Ingests dropped NSItemProvider payloads immediately during the drop transaction.
  static func dropped(_ provider: NSItemProvider) -> AttachmentCandidate {
    // Execute loadDataRepresentation within local scope to satisfy concurrency boundaries.
    nonisolated(unsafe) let provider = provider
    let loading = Task { try await provider.loadOriginalImageData() }
    return AttachmentCandidate(filename: nil) { dir, id in
      try AttachmentStaging.write(try await loading.value, into: dir, id: id)
    }
  }
}

extension NSItemProvider {
  /// Ingests image binary data from the first matching uniform type identifier supported by the item provider.
  fileprivate func loadOriginalImageData() async throws -> Data {
    let type = registeredTypeIdentifiers.first { UTType($0)?.conforms(to: .image) == true } ?? UTType.image.identifier
    return try await withCheckedThrowingContinuation { continuation in
      _ = loadDataRepresentation(forTypeIdentifier: type) { data, error in
        if let data { continuation.resume(returning: data) } else { continuation.resume(throwing: error ?? FileImport.Unreadable()) }
      }
    }
  }
}

/// View modifier maintaining real-time awareness of pasteboard image presence, synchronizing across
/// system pasteboard notification events and application foreground reactivation cycles.
struct PasteboardImageWatcher: ViewModifier {
  @Binding var hasImages: Bool
  @Environment(\.scenePhase) private var scenePhase

  func body(content: Self.Content) -> some View {
    content
      .onAppear { hasImages = SystemPasteboard.general.hasImages }
      .onChange(of: scenePhase) { _, phase in
        if phase == .active { hasImages = SystemPasteboard.general.hasImages }
      }
      .onReceive(SystemPasteboard.changes) { _ in
        hasImages = SystemPasteboard.general.hasImages
      }
  }
}

extension Glass {
  /// High opacity glass styling calibrated for small composer controls (pills, chips) to maintain
  /// text legibility against complex imagery scrolling beneath the translucent floating panel.
  /// Evaluates color scheme values to ensure reliable dynamic light/dark mode adaptation.
  static func composerControl(_ scheme: ColorScheme) -> Glass {
    .regular.tint(scheme == .dark ? Color.black.opacity(0.8) : Color.white.opacity(0.85))
  }
}

extension View {
  /// Computes lateral padding for transcript columns; iOS overlay scroll indicators do not consume content layout width.
  func scrollBarIndependentColumn(reflow: TranscriptReflow) -> some View { inSplitLayout(PadTranscriptColumn(reflow: reflow)) }

  /// Preserves flexible content width on iOS.
  func fillsTranscriptWidth() -> some View { self }

  /// Applies capsule glass background styling to composer control elements.
  @ViewBuilder
  func composerControlSurface(_ scheme: ColorScheme, interactive: Bool = false) -> some View {
    if interactive {
      glassEffect(.composerControl(scheme).interactive(), in: .capsule)
    } else {
      glassEffect(.composerControl(scheme))
    }
  }
}
