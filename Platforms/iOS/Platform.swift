import Combine
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// iOS implementations for platform-specific queries and actions.
@MainActor
enum Platform {
  /// Indicates whether the runtime environment is executing on an iPad idiom. Resolved non-isolated via system architecture inspection.
  nonisolated static let isPad: Bool = {
    if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated.hasPrefix("iPad") }
    var info = utsname()
    uname(&info)
    return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }.hasPrefix("iPad")
  }()

  /// User-facing operating system platform identifier.
  nonisolated private static var systemName: String { isPad ? "iPadOS" : "iOS" }

  /// Operating system descriptor formatted for diagnostic launch logs.
  static var osDescription: String { "\(systemName) \(UIDevice.current.systemVersion)" }

  /// URL for the app's page in the iOS Settings app.
  static var settingsURL: URL? { URL(string: UIApplication.openSettingsURLString) }

  /// System Settings deep link for Photos privacy authorizations.
  static var photosSettingsURL: URL? { settingsURL }

  static var openSettingsTitle: String { "Open Settings" }

  static var photosDeniedMessage: String { "Allow ImageGen to add photos in Settings to save images to your library." }

  /// Action title for file export operations.
  static var saveToFilesTitle: String { "Save to Files" }
  static var savedToFilesToast: String { "Saved to Files" }
  /// Display label describing file-imported image origins.
  nonisolated static var fileOriginName: String { "Files" }

  static var editFromHereTitle: String { "Edit from here" }
  static var copyImageTitle: String { "Copy" }
  static var infoTitle: String { "Info" }

  /// Menu ordering preference placing viewer navigation trailing export actions on iOS.
  static var leadsImageMenuWithView: Bool { false }

  /// Indicates whether file export errors should surface via transient toasts rather than alerts.
  static var showsExportFailuresAsAlerts: Bool { false }

  /// Indicates whether the log viewer interface renders an explicit dismissal button.
  static var logViewerHasDoneButton: Bool { true }

  /// Indicates whether viewer chrome is hosted in the window toolbar.
  static var viewerUsesWindowToolbar: Bool { false }

  /// Dispatches accessibility voice announcements for status updates; no-op on iOS.
  static func announce(_ text: String) {}

  nonisolated static var interruptedRequestMessage: String {
    "\(systemName) stopped the request (for example after a force-quit). Retry to send it again."
  }

  static var notificationsDeniedStatus: String { "Off in system Settings" }
  static var deleteEverythingTitle: String { "Are you sure?" }
  static var savedImagesKeptNote: String { "Images you saved to Photos or Files are kept." }
  static var customModelsFooter: String { "Each ID is checked with Google before it's added. Swipe to remove one." }
  static var modelsCheckAgainHint: String { " Pull down to check again." }
  static var actionFailedTitle: String { "Couldn't do that" }

  /// Optional explanatory body text for conversation deletion alerts; nil on iOS.
  static var deleteChatWarning: String? { nil }

  /// Controls whether metadata details present as distinct pushed sheets.
  static var showsReplyDetailsInline: Bool { false }

  /// Controls inclusion of an About section within the preferences window.
  static var showsAboutInSettings: Bool { true }

  /// Periodic interval for background storage cleanup; nil for transient process lifecycles.
  static var janitorRerunInterval: TimeInterval? { nil }

  /// Controls whether background-scheduled retries are recreated upon application activation.
  static var recreatesInactiveRetries: Bool { true }
  static var inactiveDeliveryNote: String { "delivered while the app was in the background" }

  /// Reveals the primary conversation window; no-op in single-window environments.
  static func revealChatWindow() {}

  /// Controls presence of an explicit dismissal button on full-screen viewer presentations.
  static var viewerShowsCloseButton: Bool { true }

  /// Governs whether fullscreen viewer presentation reconstructs its page hierarchy upon container resize events.
  static var recreatesViewerOnResize: Bool { !isPad }

  static func open(_ url: URL) { UIApplication.shared.open(url) }

  /// Maximum input attachment byte size permitted during import; unconstrained on iOS.
  nonisolated static var maxAttachmentBytes: Int? { nil }

  /// Governs whether empty conversations containing draft modifications or staged attachments are retained when navigated away.
  static var keepsUnsentChats: Bool { isPad }

  static var choosePhotosCommandTitle: String { "Photo Library…" }
  static var chooseFilesCommandTitle: String { "Files…" }

  /// Indicates whether view hierarchies rebuild during adaptive layout transitions between split and stack presentations.
  static var rebuildsChatOnLayoutChange: Bool { isPad }

  /// Dismisses image viewer window instances; no-op on iOS where viewer presentation uses modal covers.
  static func closeViewer(ofConversation id: UUID?) {}

  /// Localized device category noun utilized in contextual dialogs.
  static var deviceNoun: String { isPad ? "iPad" : "iPhone" }

  /// Controls presence of a dedicated new conversation row in the list view.
  static var showsNewChatRow: Bool { true }

  /// Indicates whether reply image presentation requests adaptive high-resolution display buckets beyond baseline dimensions.
  static var sharpensLargeReplyImages: Bool { isPad }

  /// Standardized point diameter for circular overlay and composer controls.
  static var circleButtonSize: CGFloat { 36 }

  static var chatRowThumbnailSize: CGFloat { 44 }
  static var chatRowTitleFont: Font { .headline }
  static var chatRowSnippetFont: Font { .subheadline }

  /// Standardized typography for compact status pills and context chips.
  static var composerControlFont: Font { .footnote }
  static var toastFont: Font { .footnote }
  static var trayCaptionFont: Font { .caption }
  static var statusCardMessageFont: Font { .subheadline }

  /// Visibility flag for horizontal scroll indicators across touch surfaces.
  static var showsHorizontalScrollIndicators: Bool { false }

  /// Fill color applied to user prompt message bubbles.
  static var promptBubbleFill: Color { .accentColor }

  /// Requests landscape interface orientation for testing and diagnostics.
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
  @discardableResult
  func setData(_ data: Data, type: UTType) -> Bool {
    board.setItems([[type.identifier: data]])
    return true
  }

  func data(for type: UTType) -> Data? { board.data(forPasteboardType: type.identifier) }

  var itemCount: Int { board.numberOfItems }
  var typeIdentifiers: [String] { board.types }
}

extension ToolbarItemPlacement {
  static var leadingBar: ToolbarItemPlacement { .topBarLeading }
  static var sheetLeadingBar: ToolbarItemPlacement { .topBarLeading }
  static var trailingBar: ToolbarItemPlacement { .topBarTrailing }
}

extension View {
  func inlineNavigationTitle() -> some View { navigationBarTitleDisplayMode(.inline) }

  /// Assigns modal sheet navigation titles to log viewer presentations.
  func logViewerTitle(_ title: String) -> some View { navigationTitle(title).inlineNavigationTitle() }

  /// Presents the system document exporter sheet to persist asset files.
  func saveFilePresentation(_ model: ImageExportModel) -> some View {
    fileExporter(
      // Defer action completion until explicit onCompletion or onCancellation callback resolution.
      isPresented: Binding(get: { model.fileExport != nil }, set: { if !$0 { model.fileExport = nil } }),
      document: model.fileExport.map { ImageFileDocument(file: $0.file) }, contentTypes: [model.fileExport?.utType ?? .jpeg],
      defaultFilename: model.fileExport?.suggestedName,
      onCompletion: { model.filesFinished($0) },
      onCancellation: { model.filesFinished(nil) }
    )
  }

  func neverAutocapitalize() -> some View { textInputAutocapitalization(.never) }

  func hidesStatusBar(_ hidden: Bool) -> some View { statusBarHidden(hidden) }

  /// Configures text content type annotations for credential autofill integration.
  func apiKeyContentType() -> some View { textContentType(.password) }

  /// Configures form field label visibility conventions for iOS.
  func hidesFormFieldLabel() -> some View { self }

  /// Submits or dismisses the software keyboard on return key entry.
  func submitsOnReturn(_ action: @escaping () -> Void) -> some View { self }

  func formPrimaryButtonStyle() -> some View { buttonStyle(.borderless) }
  func formSecondaryButtonStyle() -> some View { buttonStyle(.borderless) }

  /// Button width layout style for onboarding actions.
  func onboardingButtonLabel() -> some View { frame(maxWidth: .infinity) }
  func onboardingButtonPlacement() -> some View { self }

  /// Text selection behavior for sheet metadata lists.
  func selectableDetails() -> some View { self }

  /// Form style modifier applied to modal sheet content.
  func sheetFormStyle() -> some View { self }

  /// Dynamic sizing constraints applied to modal sheet presentations.
  func sheetSizing(minWidth: CGFloat, minHeight: CGFloat? = nil) -> some View { self }

  /// Keyboard shortcut modifier for default sheet actions; no-op on iOS.
  func defaultActionShortcut() -> some View { self }

  /// Applies adaptive presentation constraints to onboarding view hierarchies.
  @ViewBuilder
  func onboardingLayout() -> some View {
    if Platform.isPad { frame(maxWidth: 560).frame(maxWidth: .infinity, maxHeight: .infinity) } else { self }
  }

  /// Width constraint wrapper for onboarding form content.
  func onboardingFormWidth() -> some View { self }

  /// Publishes contextual conversation commands to system menu bar hierarchies and keybinding dispatchers on iPad.
  @ViewBuilder
  func publishesChatCommands(_ handle: @autoclosure () -> ChatCommandHandle) -> some View {
    if Platform.isPad { focusedSceneValue(\.chatCommands, handle()) } else { self }
  }

  /// Coordinates full-screen image viewer presentation detached from individual navigation controllers.
  func viewerCover<Content: View>(
    item: Binding<ViewerRequest?>, @ViewBuilder content: @escaping (ViewerRequest) -> Content
  ) -> some View {
    onChange(of: item.wrappedValue?.id) { _, _ in
      guard let request = item.wrappedValue else { return }
      ViewerCoverController.shared.show(AnyView(content(request)))
      item.wrappedValue = nil
    }
  }
}
