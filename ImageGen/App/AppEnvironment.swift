import Foundation
import Observation
import SwiftData
import UIKit
import UserNotifications

/// Configuration bundle for mock environments, substituting background network sessions
/// and secure Keychain storage with ephemeral protocols and in-memory credential stores.
struct MockEnvironment: Sendable {
  let transportConfiguration: URLSessionConfiguration
  let modelsProtocolClasses: [AnyClass]
  let keyStore: any APIKeyStore
  let description: String
}

/// Dependency injection container and service orchestrator.
///
/// Encapsulates application initialization order, subsystem instantiation, and lifecycle event routing.
/// The container initializes lazily upon first access across foreground launches or background wakes,
/// establishing dependency wiring in deterministic sequence:
/// 1. Diagnostic activity logging initialization with credential redaction registries.
/// 2. Relational persistence (`DataStore`) and file system hierarchy (`FileStore`).
/// 3. Network transport layer (`URLSessionTransport`) prior to consumer pipeline construction.
/// 4. Post-launch state reconciliation (`Reconciler`) followed by background file maintenance (`Janitor`).
///
/// State mutations and coordinator access are bound to `@MainActor`, with compute-intensive operations
/// delegated to background actor contexts or detached task streams.
@Observable @MainActor
final class AppEnvironment {
  /// Parameterization for application runtime environments across production, testing, and mock executions.
  struct Configuration {
    var root: URL
    var cachesRoot: URL
    var transportConfiguration: URLSessionConfiguration
    var sessionDescription: String
    var makeKeyStore: (SecretRegistry) -> any APIKeyStore
    var defaults: UserDefaults
    /// Optional UserDefaults suite identifier for non-isolated readers.
    var defaultsSuite: String?
    var modelsProtocolClasses: [AnyClass] = []
    var mockModeDescription = "off"
    var inMemoryStore = false
    /// Triggers filesystem and store purge prior to initialization.
    var resetBeforeLaunch = false
    var makeBackgroundTasks: (ActivityLog) -> any BackgroundTaskProviding = { UIApplicationBackgroundTaskProvider(log: $0) }
    /// Custom notification delivery hook for test environments; nil delegates to `UNUserNotificationCenter`.
    var deliverNotification: (@Sendable (ReplyNotification) async -> Void)? = nil
    var connectivity: any ConnectivityMonitoring = NWPathConnectivityMonitor()
    var reconcilerSleeper: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    var transportSleeper: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    var notificationAuthorizer: any NotificationAuthorizing = UserNotificationAuthorizer()
    var skipNotificationPrompt = false
  }

  static let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

  /// Shared singleton instance, initialized lazily on first access.
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
  // Janitor execution is gated on completion of both Reconciler and the initial presentation frame.
  @ObservationIgnored private var reconcilerFinished = false
  @ObservationIgnored private var firstFrameSeen = false
  @ObservationIgnored private(set) var janitorTask: Task<Janitor.Report, Never>?

  init(_ config: Configuration) {
    if config.resetBeforeLaunch {
      Self.deleteAllData(root: config.root, cachesRoot: config.cachesRoot)
    }
    // 1. Diagnostic logging and initialization action tracking.
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

    // 2. Storage engine and persistent state initialization.
    files = FileStore(root: config.root, cachesRoot: config.cachesRoot)
    files.retireStaging()
    do {
      container = try StoreFactory.makeContainer(root: config.root, inMemory: config.inMemoryStore)
    } catch {
      // Degrades to transient in-memory storage upon persistent store corruption to preserve diagnostic logging.
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

    // 3. Network transport stream and generation pipeline assembly.
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

    // 4. Auxiliary coordinators and navigation state.
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

  /// Constructs feature dependency bundle for chat presentation workflows.
  func chatServices() -> ChatServices {
    ChatServices(
      store: store, files: files, generation: service, settings: settings, log: log, connectivity: connectivity,
      activity: activity, notifications: notificationPermission, navigator: navigator, thumbnails: thumbnails,
      copyToPasteboard: { UIPasteboard.general.string = $0 })
  }

  /// Constructs view model dependencies for application settings presentation.
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

  /// Finalizes post-launch initialization: logs application execution context and initiates
  /// background reconciliation off the main actor.
  func didFinishLaunching(applicationState: UIApplication.State) {
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

  /// Signals initial presentation frame appearance, qualifying filesystem garbage collection to proceed.
  func firstFrameAppeared() {
    firstFrameSeen = true
    startJanitorIfReady()
  }

  /// Propagates system scene phase transitions across active coordinators.
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
      // Secures diagnostic log flushing via a short-lived background execution assertion.
      let tasks = backgroundTasks
      Task {
        let token = await tasks.begin(name: "log-flush") {}
        await tasks.end(token)
      }
    }
  }

  /// Awaits completion of background launch reconciliation (testing utility).
  func waitForReconciler() async {
    await reconcilerTask?.value
  }

  private func reconcilerDidFinish() {
    reconcilerFinished = true
    startJanitorIfReady()
  }

  /// Evaluates readiness preconditions (reconciliation completed and initial frame presented)
  /// before scheduling detached filesystem maintenance.
  private func startJanitorIfReady() {
    guard firstFrameSeen, reconcilerFinished, janitorTask == nil else { return }
    let janitor = Janitor(files: files, store: store, log: log)
    janitorTask = Task.detached(priority: .utility) { await janitor.run() }
  }

  static var applicationSupportRoot: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("ImageGen", isDirectory: true)
  }

  static var cachesRoot: URL {
    FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
  }

  /// Resolves runtime environment configuration, falling back to mock configurations when flags are set.
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

  /// Purges application support and cache directories.
  nonisolated static func deleteAllData(root: URL, cachesRoot: URL) {
    try? FileManager.default.removeItem(at: root)
    try? FileManager.default.removeItem(at: cachesRoot.appendingPathComponent("Thumbnails"))
  }
}

extension URLSessionTransport {
  /// Diagnostic label for transport session classification.
  var sessionKind: String { isBackgroundSession ? "background session" : "ephemeral session" }
}
