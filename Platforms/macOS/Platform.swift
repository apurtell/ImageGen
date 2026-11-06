import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// macOS implementations for platform-specific queries and actions.
@MainActor
enum Platform {
  /// Operating system name and version for the launch log.
  static var osDescription: String {
    let v = ProcessInfo.processInfo.operatingSystemVersion
    return "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
  }

  /// macOS has no per-app page in System Settings.
  static var settingsURL: URL? { nil }

  static func open(_ url: URL) { NSWorkspace.shared.open(url) }

  /// Window orientation changes do not apply to macOS.
  static func requestLandscape() {}
}

/// The system pasteboard, or an isolated instance in tests.
@MainActor
struct SystemPasteboard {
  fileprivate let board: NSPasteboard

  static var general: SystemPasteboard { SystemPasteboard(board: .general) }

  /// Emits periodic ticks; macOS does not post change notifications for NSPasteboard.
  static var changes: AnyPublisher<Void, Never> {
    Timer.publish(every: 1, on: .main, in: .common).autoconnect().map { _ in }.eraseToAnyPublisher()
  }

  /// Creates a throwaway pasteboard for testing; call `discard()` when done.
  static func unique() -> SystemPasteboard { SystemPasteboard(board: NSPasteboard(name: NSPasteboard.Name("ImageGenTests-\(UUID().uuidString)"))) }

  func discard() { board.releaseGlobally() }

  var string: String? {
    get { board.string(forType: .string) }
    nonmutating set {
      board.clearContents()
      if let newValue { board.setString(newValue, forType: .string) }
    }
  }

  var hasImages: Bool {
    (board.types ?? []).contains { UTType($0.rawValue)?.conforms(to: .image) == true }
  }

  /// Replaces the pasteboard contents with data under the given type identifier.
  func setData(_ data: Data, type: UTType) {
    board.clearContents()
    board.setData(data, forType: NSPasteboard.PasteboardType(type.identifier))
  }

  func data(for type: UTType) -> Data? { board.data(forType: NSPasteboard.PasteboardType(type.identifier)) }

  var itemCount: Int { board.pasteboardItems?.count ?? 0 }
  var typeIdentifiers: [String] { (board.types ?? []).map(\.rawValue) }
}

extension ToolbarItemPlacement {
  static var leadingBar: ToolbarItemPlacement { .navigation }
  static var trailingBar: ToolbarItemPlacement { .primaryAction }
}

extension View {
  func pagedTabStyle() -> some View { self }

  func inlineNavigationTitle() -> some View { self }

  func neverAutocapitalize() -> some View { self }

  func hidesStatusBar(_ hidden: Bool) -> some View { self }

  /// Presents the image viewer as a sheet; macOS does not have full-screen covers.
  func viewerCover<Item: Identifiable, Content: View>(
    item: Binding<Item?>, @ViewBuilder content: @escaping (Item) -> Content
  ) -> some View {
    sheet(item: item, content: content)
  }
}
