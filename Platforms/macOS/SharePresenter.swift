import AppKit
import SwiftUI

extension ImageExportModel {
  /// Indicates whether a modal file export sheet is currently presented.
  var isPresenting: Bool { fileExport != nil }
}

extension View {
  /// Attaches a system sharing picker anchored to the pointer location.
  func sharePresentation(_ model: ImageExportModel) -> some View {
    background(
      SharePickerAnchor(ticket: model.share) { ticket, service, completed, error in
        model.shareFinished(ticket, activityType: service, completed: completed, error: error)
      })
  }
}

extension View {
  /// Presents an explicit `NSSavePanel` sheet on the host window when an export item is requested.
  ///
  /// Uses a dedicated AppKit save panel rather than SwiftUI's `fileExporter` to control panel
  /// titles and accessibility labels.
  func saveFilePresentation(_ model: ImageExportModel) -> some View {
    background(SavePanelAnchor(item: model.fileExport) { model.filesFinished($0) })
  }
}

/// View representable hosting the save panel presentation anchor.
private struct SavePanelAnchor: NSViewRepresentable {
  let item: ExportItem?
  let onFinished: (Result<URL, any Error>?) -> Void

  func makeNSView(context: Context) -> SavePanelAnchorView { SavePanelAnchorView() }

  func updateNSView(_ view: SavePanelAnchorView, context: Context) {
    view.onFinished = onFinished
    view.item = item
  }
}

/// Host view coordinating modal save panel presentation and lifecycle.
final class SavePanelAnchorView: NSView {
  var onFinished: (Result<URL, any Error>?) -> Void = { _ in }
  var item: ExportItem? {
    didSet { update() }
  }
  private var panel: NSSavePanel?
  private var presentedID: ExportItem.ID?

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    update()
  }

  private func update() {
    guard let item else {
      presentedID = nil
      dismissPanel()
      return
    }
    guard let window, presentedID != item.id else { return }
    dismissPanel()
    presentedID = item.id
    let panel = NSSavePanel()
    self.panel = panel
    panel.title = "Save"
    panel.prompt = "Save"
    panel.nameFieldLabel = "Save As:"
    panel.nameFieldStringValue = item.suggestedName
    panel.allowedContentTypes = [item.utType]
    panel.setAccessibilityLabel("Save")
    let file = item.file
    // Defer presentation until the current runloop cycle completes to avoid event collisions.
    DispatchQueue.main.async { [weak self] in
      guard self?.panel === panel else { return }
      panel.beginSheetModal(for: window) { response in
        self?.finished(panel, response: response, file: file)
      }
    }
  }

  /// Dismisses any active save panel without emitting a completion callback.
  private func dismissPanel() {
    guard let panel else { return }
    self.panel = nil
    panel.cancel(nil)
  }

  private func finished(_ panel: NSSavePanel, response: NSApplication.ModalResponse, file: ImageFile) {
    guard self.panel === panel else { return }
    self.panel = nil
    guard response == .OK, let url = panel.url else { return onFinished(nil) }
    do {
      try file.write(to: url)
      onFinished(.success(url))
    } catch {
      onFinished(.failure(error))
    }
  }
}

/// View representable hosting the sharing service picker anchor.
private struct SharePickerAnchor: NSViewRepresentable {
  let ticket: ShareTicket?
  let onFinished: (ShareTicket, String?, Bool, (any Error)?) -> Void

  func makeNSView(context: Context) -> SharePickerAnchorView { SharePickerAnchorView() }

  func updateNSView(_ view: SharePickerAnchorView, context: Context) {
    view.onFinished = onFinished
    view.ticket = ticket
  }
}

final class SharePickerAnchorView: NSView {
  var onFinished: (ShareTicket, String?, Bool, (any Error)?) -> Void = { _, _, _, _ in }
  var ticket: ShareTicket? {
    didSet { presentIfNeeded() }
  }
  private var presentedID: ShareTicket.ID?

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    presentIfNeeded()
  }

  private func presentIfNeeded() {
    guard let ticket, window != nil, presentedID != ticket.id else { return }
    presentedID = ticket.id
    // Defer presentation until the initiating event finishes processing.
    DispatchQueue.main.async { [weak self] in self?.present(ticket) }
  }

  private func present(_ ticket: ShareTicket) {
    let finished = onFinished
    ShareSession.start(file: ticket.item.file, relativeTo: anchorRect, of: self) { service, completed, error in
      finished(ticket, service, completed, error)
    }
  }

  /// Mouse pointer location clamped to the view bounds for anchoring the sharing picker.
  private var anchorRect: CGRect {
    let point = window.map { convert($0.mouseLocationOutsideOfEventStream, from: nil) } ?? CGPoint(x: bounds.midX, y: bounds.maxY)
    let x = min(max(point.x, bounds.minX), bounds.maxX)
    let y = min(max(point.y, bounds.minY), bounds.maxY)
    return CGRect(x: x - 1, y: y - 1, width: 2, height: 2).intersection(bounds)
  }
}

/// Coordinates a sharing service lifecycle, maintaining session retention until delegate callbacks conclude.
@MainActor
private final class ShareSession: NSObject, NSSharingServicePickerDelegate, NSSharingServiceDelegate {
  private static var active: [ObjectIdentifier: ShareSession] = [:]

  private let onComplete: (String?, Bool, (any Error)?) -> Void
  private var service: String?
  private var picker: NSSharingServicePicker?

  private init(onComplete: @escaping (String?, Bool, (any Error)?) -> Void) { self.onComplete = onComplete }

  /// Initiates sharing with a named copy in scratch storage to isolate the primary file.
  static func start(
    file: ImageFile, relativeTo rect: CGRect, of view: NSView, onComplete: @escaping (String?, Bool, (any Error)?) -> Void
  ) {
    let copy: URL
    do {
      copy = try ExportScratch.namedCopy(of: file.url, name: file.suggestedName)
    } catch {
      onComplete(nil, false, error)
      return
    }
    let session = ShareSession(onComplete: onComplete)
    active[ObjectIdentifier(session)] = session
    let picker = NSSharingServicePicker(items: [copy])
    picker.delegate = session
    session.picker = picker
    picker.show(relativeTo: rect, of: view, preferredEdge: .minY)
  }

  private func finish(completed: Bool, error: (any Error)? = nil) {
    guard Self.active.removeValue(forKey: ObjectIdentifier(self)) != nil else { return }
    onComplete(service, completed, error)
  }

  nonisolated func sharingServicePicker(_ picker: NSSharingServicePicker, didChoose service: NSSharingService?) {
    let title = service?.title
    MainActor.assumeIsolated {
      guard let title else { return finish(completed: false) }
      self.service = title
    }
  }

  nonisolated func sharingServicePicker(
    _ picker: NSSharingServicePicker, delegateFor service: NSSharingService
  ) -> (any NSSharingServiceDelegate)? { self }

  nonisolated func sharingService(_ service: NSSharingService, didShareItems items: [Any]) {
    MainActor.assumeIsolated { finish(completed: true) }
  }

  nonisolated func sharingService(_ service: NSSharingService, didFailToShareItems items: [Any], error: any Error) {
    let failure = (error as? CocoaError)?.code == .userCancelled ? nil : error
    MainActor.assumeIsolated { finish(completed: false, error: failure) }
  }
}
