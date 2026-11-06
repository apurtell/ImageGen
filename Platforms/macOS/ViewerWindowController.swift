import AppKit
import Observation
import SwiftUI

/// Specialized window intercepting viewer keyboard navigation shortcuts prior to default AppKit handling.
final class ViewerWindow: NSWindow {
  weak var router: ViewerKeyRouter?

  override func sendEvent(_ event: NSEvent) {
    if event.type == .keyDown, handle(event) { return }
    super.sendEvent(event)
  }

  private func handle(_ event: NSEvent) -> Bool {
    guard let router else { return false }
    let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
    if flags.isEmpty {
      switch event.keyCode {
      case 53:
        // Exit full screen if active; otherwise close the window.
        if styleMask.contains(.fullScreen) { toggleFullScreen(nil) } else { router.close() }
      case 123: router.move(-1)
      case 124: router.move(1)
      default: return false
      }
      return true
    }
    // Handle Command-Plus key combinations.
    if flags == [.command, .shift], event.charactersIgnoringModifiers == "+" || event.charactersIgnoringModifiers == "=" {
      router.zoom(.zoomIn)
      return true
    }
    return false
  }

  /// Dispatches the standard copy action to the viewer router.
  @objc func copy(_ sender: Any?) {
    router?.export(.copy)
  }
}

/// Manages the single-instance image viewer window and routes menu and keyboard commands.
@Observable @MainActor
final class ViewerWindowController: NSObject, NSWindowDelegate {
  static let shared = ViewerWindowController()

  /// Indicates whether the viewer window currently has key focus.
  private(set) var isKey = false
  /// Indicates whether backward paging is available.
  private(set) var canMoveBack = false
  /// Indicates whether forward paging is available.
  private(set) var canMoveForward = false

  /// Router connecting window key events to viewer content actions.
  @ObservationIgnored let router = ViewerKeyRouter()
  @ObservationIgnored private var window: ViewerWindow?
  @ObservationIgnored private let host = NSHostingView(rootView: AnyView(EmptyView()))
  @ObservationIgnored private var presentation = 0
  /// Identifier of the conversation containing the displayed images.
  @ObservationIgnored private var conversationID: UUID?

  override private init() {
    super.init()
    // Restrict hosting view size constraints to minimum size, allowing the window controller to drive frame dimensions.
    host.sizingOptions = [.minSize]
    host.sceneBridgingOptions = [.toolbars]
    router.close = { [weak self] in self?.window?.close() }
    router.setTitle = { [weak self] in self?.window?.title = $0 }
    router.setPosition = { [weak self] in self?.window?.subtitle = $0 }
    router.setPaging = { [weak self] back, forward in
      self?.canMoveBack = back
      self?.canMoveForward = forward
    }
  }

  /// Presents the viewer window for `request`, sizing the window to accommodate the target image.
  func show(_ request: ViewerRequest, content: AnyView) {
    let window = self.window ?? makeWindow()
    self.window = window
    // Target the current display if already visible, otherwise the key window's display.
    let screen = window.isVisible ? window.screen : NSApp.keyWindow?.screen ?? NSApp.mainWindow?.screen ?? NSScreen.main
    // Increment presentation token to reset viewer zoom and selection state.
    presentation += 1
    conversationID = request.conversationID
    let minimum = ViewerWindowSizing.minimumContent
    host.rootView = AnyView(content.id(presentation).frame(minWidth: minimum.width, minHeight: minimum.height))
    window.title = "Image"
    window.subtitle = ""
    let image = request.images.first { $0.id == request.startID } ?? request.images.first
    var contentHeight: CGFloat?
    if !window.styleMask.contains(.fullScreen) {
      let size = ViewerWindowSizing.contentSize(
        image: CGSize(width: image?.item.pixelWidth ?? 0, height: image?.item.pixelHeight ?? 0),
        available: screen?.visibleFrame.size ?? CGSize(width: 1440, height: 900), pixelScale: screen?.backingScaleFactor ?? 2)
      contentHeight = size.height
      var frame = window.frameRect(forContentRect: CGRect(origin: .zero, size: size))
      if window.isVisible {
        // Anchor frame adjustments to top-left origin.
        frame.origin = CGPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
      } else if let visible = screen?.visibleFrame {
        frame = ViewerWindowSizing.centered(frame.size, in: visible)
      }
      window.setFrame(screen.map { ViewerWindowSizing.clamped(frame, to: $0.visibleFrame) } ?? frame, display: window.isVisible)
    }
    NSApp.activate()
    window.makeKeyAndOrderFront(nil)
    // Adjust layout once toolbar and titlebar chrome dimensions resolve.
    if !window.styleMask.contains(.fullScreen), let contentHeight {
      DispatchQueue.main.async { Self.match(window, contentHeight: contentHeight) }
    }
  }

  /// Adjusts window frame height to ensure content layout matches target height.
  private static func match(_ window: NSWindow, contentHeight: CGFloat) {
    let excess = window.contentLayoutRect.height - contentHeight
    guard abs(excess) >= 1 else { return }
    var frame = window.frame
    frame.size.height -= excess
    frame.origin.y += excess
    window.setFrame(frame, display: true)
  }

  /// Closes the viewer window if matching the specified conversation identifier, or unconditionally if nil.
  func close(ofConversation id: UUID?) {
    guard let window, window.isVisible, id == nil || id == conversationID else { return }
    window.close()
  }

  private func makeWindow() -> ViewerWindow {
    let window = ViewerWindow(
      contentRect: CGRect(origin: .zero, size: ViewerWindowSizing.fallback),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    window.router = router
    window.contentView = host
    window.collectionBehavior = [.fullScreenPrimary]
    window.tabbingMode = .disallowed
    window.isReleasedWhenClosed = false
    window.isRestorable = false
    window.backgroundColor = .black
    window.appearance = NSAppearance(named: .darkAqua)
    window.titlebarSeparatorStyle = .none
    window.delegate = self
    return window
  }

  /// Releases content and clears routing handlers when the window closes.
  func windowWillClose(_ notification: Notification) {
    host.rootView = AnyView(EmptyView())
    router.move = { _ in }
    router.zoom = { _ in }
    router.export = { _ in }
    router.editFromHere = {}
    router.showInfo = {}
    conversationID = nil
    isKey = false
    canMoveBack = false
    canMoveForward = false
  }

  func windowDidBecomeKey(_ notification: Notification) { isKey = true }
  func windowDidResignKey(_ notification: Notification) { isKey = false }
}
