import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// macOS implementations for platform specific queries and actions.
@MainActor
enum Platform {
  /// Operating system name and version for the launch log.
  static var osDescription: String {
    let v = ProcessInfo.processInfo.operatingSystemVersion
    return "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
  }

  /// System Settings deep link for application notification preferences.
  static var settingsURL: URL? {
    URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier ?? "")")
  }

  /// System Settings deep link for Photos privacy authorizations.
  static var photosSettingsURL: URL? { URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") }

  static var openSettingsTitle: String { "Open System Settings" }

  static var photosDeniedMessage: String {
    "Allow ImageGen to add photos in System Settings > Privacy & Security > Photos to save images to your library."
  }

  /// Action title for file export operations.
  static var saveToFilesTitle: String { "Save As" }
  static var savedToFilesToast: String { "Saved" }
  /// Display label describing file-imported image origins.
  nonisolated static var fileOriginName: String { "File" }

  static var editFromHereTitle: String { "Edit From Here" }
  static var copyImageTitle: String { "Copy Image" }
  static var infoTitle: String { "Get Info" }

  /// Prefers placing viewer navigation leading export actions in desktop context menus.
  static var leadsImageMenuWithView: Bool { true }

  /// Indicates whether file export failures present via modal alerts.
  static var showsExportFailuresAsAlerts: Bool { true }

  /// Indicates whether the log viewer interface renders an explicit dismissal button.
  static var logViewerHasDoneButton: Bool { false }

  /// Indicates whether viewer chrome is hosted in the window toolbar.
  static var viewerUsesWindowToolbar: Bool { true }

  /// Dispatches accessibility voice announcements for status updates.
  static func announce(_ text: String) {
    AccessibilityNotification.Announcement(text).post()
  }

  nonisolated static var interruptedRequestMessage: String {
    "The app quit before the reply arrived, so it was lost. Retry to send the request again."
  }

  static var notificationsDeniedStatus: String { "Off in System Settings" }
  static var deleteEverythingTitle: String { "Delete Everything?" }
  static var savedImagesKeptNote: String { "Images you saved to Photos or elsewhere on your Mac are kept." }
  static var customModelsFooter: String { "Each ID is checked with Google before it's added." }
  static var modelsCheckAgainHint: String { "" }
  static var actionFailedTitle: String { "Can't Start the Request" }

  /// Explanatory body text presented in conversation deletion confirmation dialogs.
  static var deleteChatWarning: String? { "This can't be undone." }

  /// Controls whether metadata details present inline rather than as secondary pushed sheets.
  static var showsReplyDetailsInline: Bool { true }

  /// Controls inclusion of an About section within the preferences window.
  static var showsAboutInSettings: Bool { false }

  /// Periodic interval for background storage cleanup during extended process lifecycles.
  static var janitorRerunInterval: TimeInterval? { 6 * 3600 }

  /// Controls whether background-scheduled retries are recreated upon application activation.
  static var recreatesInactiveRetries: Bool { false }
  static var inactiveDeliveryNote: String { "delivered while the app was inactive" }

  /// Reveals and orders front the primary conversation window.
  static func revealChatWindow() { MacAppDelegate.showMainWindow() }

  /// Controls presence of an explicit dismissal button on full-screen viewer presentations.
  static var viewerShowsCloseButton: Bool { false }

  /// Controls whether window resize transitions recreate paging container state.
  static var recreatesViewerOnResize: Bool { false }

  static func open(_ url: URL) { NSWorkspace.shared.open(url) }

  /// Maximum input attachment byte size permitted during import on macOS.
  nonisolated static var maxAttachmentBytes: Int? { 512 * 1024 * 1024 }

  /// Controls retention of uncommitted draft inputs and staging artifacts upon navigation.
  static var keepsUnsentChats: Bool { true }

  static var choosePhotosCommandTitle: String { "Choose from Photos…" }
  static var chooseFilesCommandTitle: String { "Choose File…" }

  /// Indicates whether conversation views undergo teardown and recreation during layout transitions; false on macOS.
  static var rebuildsChatOnLayoutChange: Bool { false }

  /// Closes active image viewer windows associated with the specified conversation, or all viewers when nil.
  static func closeViewer(ofConversation id: UUID?) { ViewerWindowController.shared.close(ofConversation: id) }

  /// Hardware platform noun used in user-facing messaging.
  static var deviceNoun: String { "Mac" }

  /// Controls presence of a dedicated new conversation row in the list view.
  static var showsNewChatRow: Bool { false }

  /// Enables adaptive multi-resolution thumbnail fetching for expanded desktop viewport displays.
  static var sharpensLargeReplyImages: Bool { true }

  /// No-op orientation change request on macOS.
  static func requestLandscape() {}

  /// Standardized point diameter for circular overlay and composer controls on macOS.
  static var circleButtonSize: CGFloat { 30 }

  static var chatRowThumbnailSize: CGFloat { 34 }
  static var chatRowTitleFont: Font { .body.weight(.medium) }
  static var chatRowSnippetFont: Font { .subheadline }
  /// Typography applied to conversation modification dates in the sidebar.
  static var chatRowDateFont: Font { .subheadline }

  /// Standardized typography for compact status pills and context chips on macOS.
  static var composerControlFont: Font { .callout }
  static var toastFont: Font { .callout }
  static var trayCaptionFont: Font { .subheadline }
  static var statusCardMessageFont: Font { .callout }

  /// Visibility flag for horizontal scroll indicators.
  static var showsHorizontalScrollIndicators: Bool { true }

  /// Fill color applied to user prompt message bubbles.
  static var promptBubbleFill: Color { Color("AccentColor") }
}

/// The system pasteboard, or an isolated instance in tests.
@MainActor
struct SystemPasteboard {
  let board: NSPasteboard

  static var general: SystemPasteboard { SystemPasteboard(board: .general) }

  /// Creates an isolated pasteboard instance for testing; call `discard()` when done.
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
  @discardableResult
  func setData(_ data: Data, type: UTType) -> Bool {
    board.clearContents()
    return board.setData(data, forType: NSPasteboard.PasteboardType(type.identifier))
  }

  func data(for type: UTType) -> Data? { board.data(forType: NSPasteboard.PasteboardType(type.identifier)) }

  /// Inspects pasteboard contents for attachable image files or raw image data payloads.
  func imageCandidates(preferringText: Bool = true) -> [AttachmentCandidate] {
    imageContent(preferringText: preferringText, readsDataNow: false).candidates
  }

  /// Ingests image representations from the pasteboard and reports non-image file counts.
  func imageContent(preferringText: Bool, readsDataNow: Bool) -> (candidates: [AttachmentCandidate], rejected: Int) {
    let types = board.types ?? []
    if types.contains(.fileURL) {
      let urls = fileURLs()
      let images = urls.filter(Self.isImageFile)
      if !images.isEmpty { return (images.map(AttachmentCandidate.file), urls.count - images.count) }
      if !urls.isEmpty && !types.contains(where: Self.isRawImageType) { return ([], urls.count) }
    }
    if preferringText && types.contains(.string) { return ([], 0) }
    return (rawImages(readsDataNow: readsDataNow), 0)
  }

  /// Extracts file URLs from the pasteboard, resolving sandbox security scopes.
  private func fileURLs() -> [URL] {
    (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
  }

  /// Validates whether a file URL represents a supported image type via extension or uniform type identifier.
  private static func isImageFile(_ url: URL) -> Bool {
    if !url.pathExtension.isEmpty { return UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true }
    return CGImageSourceCreateWithURL(url as CFURL, ImageInspector.noCache).flatMap(CGImageSourceGetType) != nil
  }

  private static func isRawImageType(_ type: NSPasteboard.PasteboardType) -> Bool {
    UTType(type.rawValue)?.conforms(to: .image) == true
  }

  /// Extracts image data candidates from pasteboard items matching supported image types.
  private func rawImages(readsDataNow: Bool) -> [AttachmentCandidate] {
    let preferred: [UTType] = [.png, .jpeg, .heic, .tiff]
    return (board.pasteboardItems ?? []).enumerated().compactMap { index, item in
      let offered = item.types.compactMap { UTType($0.rawValue) }
      guard let type = preferred.first(where: offered.contains) ?? offered.first(where: { $0.conforms(to: .image) }) else { return nil }
      let ext = type.preferredFilenameExtension
      if readsDataNow {
        guard let data = data(forItem: index, type: type) else { return nil }
        return .data(data, preferredExtension: ext)
      }
      return AttachmentCandidate(filename: nil) { dir, id in
        guard let data = await self.data(forItem: index, type: type) else { throw FileImport.Unreadable() }
        try FileImport.checkSize(data.count)
        return try AttachmentStaging.write(data, into: dir, id: id, preferredExtension: ext)
      }
    }
  }

  private func data(forItem index: Int, type: UTType) -> Data? {
    guard let items = board.pasteboardItems, items.indices.contains(index) else { return nil }
    return items[index].data(forType: NSPasteboard.PasteboardType(type.identifier))
  }

  var itemCount: Int { board.pasteboardItems?.count ?? 0 }
  var typeIdentifiers: [String] { (board.types ?? []).map(\.rawValue) }
}

extension ToolbarItemPlacement {
  static var leadingBar: ToolbarItemPlacement { .navigation }
  /// Configures toolbar leading item placement for modal sheets on macOS.
  static var sheetLeadingBar: ToolbarItemPlacement { .automatic }
  static var trailingBar: ToolbarItemPlacement { .primaryAction }
}

extension View {
  func inlineNavigationTitle() -> some View { toolbarTitleDisplayMode(.inline) }

  /// Updates window title and subtitle for the diagnostic log viewer window.
  func logViewerTitle(_ title: String) -> some View {
    navigationTitle(LogWindow.title).navigationSubtitle(title)
  }

  func neverAutocapitalize() -> some View { self }

  func hidesStatusBar(_ hidden: Bool) -> some View { self }

  /// No-op content type modifier on macOS to prevent automatic password manager popovers.
  func apiKeyContentType() -> some View { self }

  /// Configures form field label visibility for compact inline inputs.
  func hidesFormFieldLabel() -> some View { labelsHidden() }

  func submitsOnReturn(_ action: @escaping () -> Void) -> some View { onSubmit(action) }

  func formPrimaryButtonStyle() -> some View { buttonStyle(.borderedProminent) }
  func formSecondaryButtonStyle() -> some View { buttonStyle(.bordered) }

  /// Layout container for onboarding action buttons.
  func onboardingButtonLabel() -> some View { self }
  func onboardingButtonPlacement() -> some View { frame(maxWidth: .infinity, alignment: .trailing) }

  /// Enables text selection for sheet metadata detail rows.
  func selectableDetails() -> some View { textSelection(.enabled) }

  /// Configures form styling for modal sheets on macOS.
  func sheetFormStyle() -> some View { formStyle(.grouped) }

  /// Enforces minimum content dimensions for modal sheets on macOS.
  func sheetSizing(minWidth: CGFloat, minHeight: CGFloat? = nil) -> some View {
    frame(minWidth: minWidth, minHeight: minHeight)
  }

  /// Binds return key shortcut to the default action button.
  func defaultActionShortcut() -> some View { keyboardShortcut(.defaultAction) }

  /// Configures onboarding container to span full window geometry, ensuring titlebar visual vibrancy renders consistently.
  func onboardingLayout() -> some View { self }

  /// Constrains onboarding form content to optimal reading widths centered within the scroll view.
  func onboardingFormWidth() -> some View { frame(maxWidth: 520).frame(maxWidth: .infinity) }

  /// Publishes active conversation command handlers to the focused environment.
  func publishesChatCommands(_ handle: @autoclosure () -> ChatCommandHandle) -> some View {
    focusedSceneValue(\.chatCommands, handle())
  }

  /// Presents the image viewer within a dedicated floating window on macOS.
  func viewerCover<Content: View>(
    item: Binding<ViewerRequest?>, @ViewBuilder content: @escaping (ViewerRequest) -> Content
  ) -> some View {
    onChange(of: item.wrappedValue?.id) { _, _ in
      guard let request = item.wrappedValue else { return }
      let controller = ViewerWindowController.shared
      controller.show(request, content: AnyView(content(request).environment(\.viewerKeyRouter, controller.router)))
      item.wrappedValue = nil
    }
  }
}
