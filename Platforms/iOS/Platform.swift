import Combine
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// iOS implementations for platform-specific queries and actions.
@MainActor
enum Platform {
  /// Operating system name and version for the launch log.
  static var osDescription: String { "iOS \(UIDevice.current.systemVersion)" }

  /// URL for the app's page in the iOS Settings app.
  static var settingsURL: URL? { URL(string: UIApplication.openSettingsURLString) }

  static func open(_ url: URL) { UIApplication.shared.open(url) }

  /// Requests landscape orientation for UI debugging.
  static func requestLandscape() {
    UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?
      .requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight))
  }
}

/// The system pasteboard, or an isolated instance in tests.
@MainActor
struct SystemPasteboard {
  fileprivate let board: UIPasteboard

  static var general: SystemPasteboard { SystemPasteboard(board: .general) }

  /// Fires whenever the pasteboard contents change.
  static var changes: AnyPublisher<Void, Never> {
    NotificationCenter.default.publisher(for: UIPasteboard.changedNotification).map { _ in }.eraseToAnyPublisher()
  }

  /// Creates a throwaway pasteboard for testing; call `discard()` when done.
  static func unique() -> SystemPasteboard { SystemPasteboard(board: .withUniqueName()) }

  func discard() { UIPasteboard.remove(withName: board.name) }

  var string: String? {
    get { board.string }
    nonmutating set { board.string = newValue }
  }

  var hasImages: Bool { board.hasImages }

  /// Replaces the pasteboard contents with data under the given type identifier.
  func setData(_ data: Data, type: UTType) { board.setItems([[type.identifier: data]]) }

  func data(for type: UTType) -> Data? { board.data(forPasteboardType: type.identifier) }

  var itemCount: Int { board.numberOfItems }
  var typeIdentifiers: [String] { board.types }
}

extension ToolbarItemPlacement {
  static var leadingBar: ToolbarItemPlacement { .topBarLeading }
  static var trailingBar: ToolbarItemPlacement { .topBarTrailing }
}

extension View {
  func pagedTabStyle() -> some View { tabViewStyle(.page(indexDisplayMode: .never)) }

  func inlineNavigationTitle() -> some View { navigationBarTitleDisplayMode(.inline) }

  func neverAutocapitalize() -> some View { textInputAutocapitalization(.never) }

  func hidesStatusBar(_ hidden: Bool) -> some View { statusBarHidden(hidden) }

  /// Presents the image viewer full-screen over the window.
  func viewerCover<Item: Identifiable, Content: View>(
    item: Binding<Item?>, @ViewBuilder content: @escaping (Item) -> Content
  ) -> some View {
    fullScreenCover(item: item, content: content)
  }
}
