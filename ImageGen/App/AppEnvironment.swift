import Foundation
import Observation
import SwiftData
import UIKit
import UserNotifications

/// What DEBUG mock mode swaps in (D§2.6 of the plan): an ephemeral configuration with the mock
/// protocol, and an in-memory key store holding "mock-key".
struct MockEnvironment: Sendable {
  let transportConfiguration: URLSessionConfiguration
  let modelsProtocolClasses: [AnyClass]
  let keyStore: any APIKeyStore
  let description: String
}

/// The app's dependency container (D§4.2). Built once, lazily, by whichever of `ImageGenApp.init`
/// and `didFinishLaunching` runs first, so it also exists on a background relaunch. The activity
/// log comes first and the Launch action begins before anything else is built; the transport
/// creates its event stream before its session; the Reconciler starts in `didFinishLaunching`.
@Observable @MainActor
final class AppEnvironment {
  struct Configuration {
    var root: URL
    var cachesRoot: URL
    var transportConfiguration: URLSessionConfiguration
    var sessionDescription: String
    var makeKeyStore: (SecretRegistry) -> any APIKeyStore
    var defaults: UserDefaults
    var defaultsSuite: String?
    var modelsProtocolClasses: [AnyClass] = []
    var mockModeDescription = "off"
    var inMemoryStore = false
    /// Deletes the store, the files and `Logs/` before the log is created (DEBUG `-ResetStore 1`).
    var resetBeforeLaunch = false
    var makeBackgroundTasks: (ActivityLog) -> any BackgroundTaskProviding = { UIApplicationBackgroundTaskProvider(log: $0) }
    var deliverNotification: (@Sendable (ReplyNotification) async -> Void)? = nil
    var connectivity: any ConnectivityMonitoring = NWPathConnectivityMonitor()
    var reconcilerSleeper: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    var transportSleeper: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    var notificationAuthorizer: any NotificationAuthorizing = UserNotificationAuthorizer()
    var skipNotificationPrompt = false
  }

  static let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

  /// The app's instance. Never touched under the unit-test host (plan §2.2).
  static let shared: AppEnvironment = AppEnvironment(production())

  let registry: SecretRegistry
  let log: ActivityLog
  let launchAction: ActionID
  let files: FileStore
  let container: ModelContainer
  let store: DataStore
  let keyStore: any APIKeyStore
  let settings: AppSettings
  let thumbnails: ThumbnailService
  let activity: AppActivity
  let relay: BackgroundEventsRelay
  let router: NotificationRouter
  let transport: URLSessionTransport
  let backgroundTasks: any BackgroundTaskProviding
  let service: GenerationService
  let reconciler: Reconciler
  let modelsClient: ModelsClient
  let availability: ModelAvailabilityService
  let connectivity: any ConnectivityMonitoring
  let navigator: Navigator
  let developerMenu: DeveloperMenuModel
  let notificationPermission: NotificationPermission

  @ObservationIgnored private let launchStarted = ContinuousClock.now
  @ObservationIgnored private var reconcilerTask: Task<Void, Never>?
  @ObservationIgnored private var reconcilerFinished = false
  @ObservationIgnored private var firstFrameSeen = false
  @ObservationIgnored private(set) var janitorTask: Task<Janitor.Report, Never>?

  init(_ config: Configuration) {
    if config.resetBeforeLaunch {
      Self.deleteAllData(root: config.root, cachesRoot: config.cachesRoot)
    }
    // 1. The log, and the Launch Begin, before anything else.
    let registry = SecretRegistry()
    self.registry = registry
    log = ActivityLog(
      fileURL: config.root.appendingPathComponent("Logs/activity.jsonl"),
      sanitize: Redactor.forLog(secrets: { registry.all }))
    let info = Bundle.main.infoDictionary ?? [:]
    let version = info["CFBundleShortVersionString"] as? String ?? "?"
    let build = info["CFBundleVersion"] as? String ?? "?"
    launchAction = log.begin(
      "Launch", origin: .system,
      "ImageGen \(version) (\(build)) · iOS \(UIDevice.current.systemVersion) · mock mode \(config.mockModeDescription)")

    // 2. Storage, key, settings.
    files = FileStore(root: config.root, cachesRoot: config.cachesRoot)
    // Before any screen can stage a file: the Janitor removes only what earlier launches staged.
    files.retireStaging()
    do {
      container = try StoreFactory.makeContainer(root: config.root, inMemory: config.inMemoryStore)
    } catch {
      log.step(launchAction, "store failed to open (\(error.localizedDescription)); using a temporary in-memory store")
      container = try! StoreFactory.makeContainer(root: config.root, inMemory: true)
    }
    store = DataStore(container: container, files: files)
    keyStore = config.makeKeyStore(registry)
    settings = AppSettings(defaults: config.defaults)
    thumbnails = ThumbnailService(directory: files.thumbnailsDir)
    activity = AppActivity(isActive: false)
    relay = BackgroundEventsRelay(log: log)
    router = NotificationRouter()

    // 3. The transport (stream before session), then the service that consumes it.
    transport = URLSessionTransport(
      configuration: config.transportConfiguration, files: files, sleeper: config.transportSleeper)
    backgroundTasks = config.makeBackgroundTasks(log)
    let suite = config.defaultsSuite
    let activity = self.activity
    let poster =
      config.deliverNotification.map { deliver in
        NotificationPoster(
          activity: activity,
          isEnabled: { AppSettings.readNotifyOnBackgroundCompletion(suite.flatMap(UserDefaults.init(suiteName:)) ?? .standard) },
          deliver: deliver)
      } ?? NotificationPoster.userNotifications(activity: activity, settingsSuite: suite)
    let settings = self.settings
    let relay = self.relay
    service = GenerationService(
      GenerationService.Dependencies(
        transport: transport, store: store, files: files, keyStore: keyStore, log: log, backgroundTasks: backgroundTasks,
        notifier: poster, activity: activity, thumbnails: thumbnails,
        defaults: { AppSettings.readDefaults(suite.flatMap(UserDefaults.init(suiteName:)) ?? .standard) },
        setOmitCivicOnMain: { await MainActor.run { settings.omitCivicIntegrity = true } },
        onBackgroundEventsFinished: { id, handled in await relay.callAndClear(identifier: id, completionsHandled: handled) },
        sessionDescription: config.sessionDescription))

    // 4. The rest.
    reconciler = Reconciler(
      store: store, transport: transport, service: service, files: files, log: log, sleeper: config.reconcilerSleeper)
    modelsClient = ModelsClient(session: ModelsClient.makeSession(protocolClasses: config.modelsProtocolClasses))
    availability = ModelAvailabilityService(
      client: modelsClient, keyStore: keyStore, settings: settings, log: log, registry: registry)
    connectivity = config.connectivity
    navigator = Navigator()
    developerMenu = DeveloperMenuModel(log: log)
    notificationPermission = NotificationPermission(
      authorizer: config.notificationAuthorizer, defaults: config.defaults, log: log, skip: config.skipNotificationPrompt)
    navigator.needsOnboarding = ((try? keyStore.read()) ?? nil)?.isEmpty ?? true
  }

  /// What a chat screen needs.
  func chatServices() -> ChatServices {
    ChatServices(
      store: store, files: files, generation: service, settings: settings, log: log, connectivity: connectivity,
      activity: activity, notifications: notificationPermission, navigator: navigator, thumbnails: thumbnails,
      copyToPasteboard: { UIPasteboard.general.string = $0 })
  }

  /// What the Settings sheet needs.
  func settingsModel() -> SettingsModel {
    SettingsModel(
      services: SettingsModel.Services(
        settings: settings, keyStore: keyStore, availability: availability, modelsClient: modelsClient, store: store,
        files: files, thumbnails: thumbnails, generation: service, log: log, navigator: navigator,
        notificationStatus: {
          if let forced = DebugHooks.forcedNotificationState { return forced }
          return UserNotificationAuthorizer.name(await UNUserNotificationCenter.current().notificationSettings().authorizationStatus)
        }))
  }

  func apiKeySectionModel() -> APIKeySectionModel {
    APIKeySectionModel(keyStore: keyStore, log: log, availability: availability, registry: registry)
  }

  var chatActions: ChatActions {
    ChatActions(store: store, generation: service, log: log, navigator: navigator)
  }

  // MARK: Lifecycle

  /// Called from `didFinishLaunching`: logs the application state, starts the Reconciler at once
  /// (even on a background relaunch that never draws a frame), and ends the Launch action.
  func didFinishLaunching(applicationState: UIApplication.State) {
    // With the scene lifecycle this reads `background` until a scene connects, even for a user
    // launch; a background wake is identified by the Background events action that follows.
    let state = switch applicationState {
    case .active: "active"
    case .inactive: "inactive"
    case .background: "background"
    @unknown default: "unknown"
    }
    log.step(launchAction, "application state \(state)")
    let reconciler = self.reconciler
    reconcilerTask = Task.detached(priority: .utility) { [weak self] in
      await reconciler.run()
      await self?.reconcilerDidFinish()
    }
    log.result(
      launchAction, .success,
      "in \(Format.seconds(ContinuousClock.now - launchStarted)) · store opened · \(transport.sessionKind) recreated · Reconciler started"
    )
  }

  /// The first frame has been drawn; the Janitor may run once the Reconciler has finished too.
  func firstFrameAppeared() {
    firstFrameSeen = true
    startJanitorIfReady()
  }

  func scenePhaseChanged(isActive: Bool, isBackground: Bool) {
    activity.setActive(isActive)
    if isActive {
      let service = self.service
      let availability = self.availability
      Task {
        await service.appBecameActive()
        await availability.refreshIfStale()
      }
    }
    if isBackground {
      let tasks = backgroundTasks
      let log = self.log
      Task {
        let token = await tasks.begin(name: "log-flush") {}
        await log.flush(timeout: .seconds(1))
        await tasks.end(token)
      }
    }
  }

  /// For tests: waits until the Reconciler has finished.
  func waitForReconciler() async {
    await reconcilerTask?.value
  }

  private func reconcilerDidFinish() {
    reconcilerFinished = true
    startJanitorIfReady()
  }

  private func startJanitorIfReady() {
    guard firstFrameSeen, reconcilerFinished, janitorTask == nil else { return }
    let janitor = Janitor(files: files, store: store, log: log)
    janitorTask = Task.detached(priority: .utility) { await janitor.run() }
  }

  // MARK: Configuration

  static var applicationSupportRoot: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("ImageGen", isDirectory: true)
  }

  static var cachesRoot: URL {
    FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
  }

  /// The production configuration, or DEBUG mock mode when its launch option is set.
  static func production() -> Configuration {
    let root = applicationSupportRoot
    DebugHooks.resetBeforeLaunchIfRequested(root: root, cachesRoot: cachesRoot)
    let bundleID = Bundle.main.bundleIdentifier ?? "com.andrewpurtell.imagegen"
    var config = Configuration(
      root: root, cachesRoot: cachesRoot,
      transportConfiguration: URLSessionTransport.backgroundConfiguration(bundleID: bundleID),
      sessionDescription: "background session", makeKeyStore: { KeychainStore(registry: $0) }, defaults: .standard,
      defaultsSuite: nil)
    config.skipNotificationPrompt = DebugHooks.skipNotificationPrompt
    if let mock = DebugHooks.mockEnvironment() {
      config.transportConfiguration = mock.transportConfiguration
      config.sessionDescription = "ephemeral session (mock)"
      config.makeKeyStore = { registry in
        try? mock.keyStore.read().map(registry.register)
        return mock.keyStore
      }
      config.modelsProtocolClasses = mock.modelsProtocolClasses
      config.mockModeDescription = mock.description
    }
    return config
  }

  /// Everything under `Application Support/ImageGen/` (store, images, requests, staging, `Logs/`)
  /// and the thumbnails.
  nonisolated static func deleteAllData(root: URL, cachesRoot: URL) {
    // A folder that doesn't exist yet is already reset.
    try? FileManager.default.removeItem(at: root)
    try? FileManager.default.removeItem(at: cachesRoot.appendingPathComponent("Thumbnails"))
  }
}

extension URLSessionTransport {
  /// "background session" or "ephemeral session", for the Launch result.
  var sessionKind: String { isBackgroundSession ? "background session" : "ephemeral session" }
}
