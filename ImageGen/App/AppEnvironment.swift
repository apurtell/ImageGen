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
///
/// Place in the design: this is the assembly layer. It builds every service once, in a fixed order, and
/// hands them to the screens (`chatServices()`, `settingsModel()`) and to `AppDelegate`. It also turns
/// lifecycle events (launch, first frame, scene phase) into calls on the services. The start-up order
/// in `init` and `didFinishLaunching` is part of the design:
/// 1. the activity log and the Launch Begin, so every later step can log;
/// 2. storage: retire the old staging folder before any screen can stage a file, then the store;
/// 3. the transport (its stream before its session) before `GenerationService`, its one consumer;
/// 4. in `didFinishLaunching`, the Reconciler; the Janitor only after the Reconciler and the first frame.
///
/// Concurrency: `@MainActor`, so all of its own state is read and written on the main thread. The
/// slow work (Reconciler, Janitor) runs in detached tasks off the main thread. `@Observable` lets SwiftUI
/// views that read it update when a property changes; `@ObservationIgnored` excludes the bookkeeping
/// properties. See the primer, *Actors* and *SwiftUI: the user interface*.
@Observable @MainActor
final class AppEnvironment {
  /// Everything that differs between production, DEBUG mock mode and tests. Tests build their own
  /// configuration (temporary folders, fake providers, instant sleepers).
  struct Configuration {
    var root: URL
    var cachesRoot: URL
    var transportConfiguration: URLSessionConfiguration
    var sessionDescription: String
    var makeKeyStore: (SecretRegistry) -> any APIKeyStore
    var defaults: UserDefaults
    /// The `UserDefaults` suite name, for the nonisolated readers. They make their own `UserDefaults`
    /// from the name, because a `UserDefaults` object is not `Sendable`. nil means `.standard`.
    var defaultsSuite: String?
    var modelsProtocolClasses: [AnyClass] = []
    var mockModeDescription = "off"
    var inMemoryStore = false
    /// Deletes the store, the files and `Logs/` before the log is created (DEBUG `-ResetStore 1`).
    var resetBeforeLaunch = false
    var makeBackgroundTasks: (ActivityLog) -> any BackgroundTaskProviding = { UIApplicationBackgroundTaskProvider(log: $0) }
    /// Replaces the system notification center (tests). nil uses `UNUserNotificationCenter`.
    var deliverNotification: (@Sendable (ReplyNotification) async -> Void)? = nil
    var connectivity: any ConnectivityMonitoring = NWPathConnectivityMonitor()
    var reconcilerSleeper: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }  // Cancellation only ends the wait early.
    var transportSleeper: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }  // Cancellation only ends the wait early.
    var notificationAuthorizer: any NotificationAuthorizing = UserNotificationAuthorizer()
    var skipNotificationPrompt = false
  }

  static let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

  /// The app's instance. Never touched under the unit-test host (plan §2.2).
  ///
  /// A Swift `static let` is lazy: the first read runs the initializer, exactly once. That is what lets
  /// `ImageGenApp.init` and `AppDelegate` both "create" it without a race or a second copy.
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
  // The Janitor waits for both flags (see `startJanitorIfReady`).
  @ObservationIgnored private var reconcilerFinished = false
  @ObservationIgnored private var firstFrameSeen = false
  @ObservationIgnored private(set) var janitorTask: Task<Janitor.Report, Never>?

  init(_ config: Configuration) {
    if config.resetBeforeLaunch {
      Self.deleteAllData(root: config.root, cachesRoot: config.cachesRoot)
    }
    // 1. The log, and the Launch Begin, before anything else.
    // The registry comes first because the log's sanitizer reads it: any key that is read later is
    // removed from every log line.
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
      // The app still starts, so the user can read the log; nothing is saved in this run.
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
    // On a background relaunch, creating the transport reconnects to the system's session, and
    // completions can arrive at once. They wait in the stream's buffer until the service reads them.
    transport = URLSessionTransport(
      configuration: config.transportConfiguration, files: files, sleeper: config.transportSleeper)
    backgroundTasks = config.makeBackgroundTasks(log)
    // These values are copied into locals because the `@Sendable` closures below run on other actors.
    // A closure in `init` also cannot capture `self` before every property has a value.
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
        // The service reads defaults straight from `UserDefaults` and writes through the main actor
        // (D§5, "Settings written from the actor").
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
    navigator.needsOnboarding = ((try? keyStore.read()) ?? nil)?.isEmpty ?? true  // A Keychain error counts as no key: onboarding asks for one.
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
    // `Task.detached` runs the Reconciler off the main actor, at low priority, so launch is not slowed.
    // `[weak self]`: the task does not keep the environment alive.
    // The last line hops back to the main actor, because `reconcilerDidFinish` is main-actor state.
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

  /// Called by `ImageGenApp` on every scene phase change. The phase can change several times in a
  /// second (see the primer, *iOS application lifecycle*), so each branch is safe to repeat.
  func scenePhaseChanged(isActive: Bool, isBackground: Bool) {
    activity.setActive(isActive)
    if isActive {
      let service = self.service
      let availability = self.availability
      // `Task {}` keeps the main actor; the two calls `await` other actors, so the main thread is free
      // while they run.
      Task {
        await service.appBecameActive()
        await availability.refreshIfStale()
      }
    }
    if isBackground {
      // iOS can suspend the app a few seconds after this. A short background-task assertion keeps it
      // running while the log reaches the disk.
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

  /// Starts the Janitor once, after both the Reconciler and the first frame (D§4.4). After the
  /// Reconciler, so the Janitor never races a launch-time re-parse. After the first frame, so the
  /// clean-up stays out of the launch path (D§8); a background relaunch with no UI never starts it.
  /// Both callers run on the main actor, so the check and the `janitorTask` write cannot interleave.
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
  /// In Release builds the `DebugHooks` calls are empty stubs, so this is always the production setup.
  static func production() -> Configuration {
    let root = applicationSupportRoot
    // Before the log exists, so a reset run's log starts with its own Launch Begin.
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
      // The mock key store was made with its own registry; this registers its key with the app's
      // registry too, so the log sanitizer removes it.
      config.makeKeyStore = { registry in
        try? mock.keyStore.read().map(registry.register)  // The in-memory store does not throw.
        return mock.keyStore
      }
      config.modelsProtocolClasses = mock.modelsProtocolClasses
      config.mockModeDescription = mock.description
    }
    return config
  }

  /// Everything under `Application Support/ImageGen/` (store, images, requests, staging, `Logs/`)
  /// and the thumbnails.
  /// `nonisolated`: callable without the main actor, because it touches only the file system.
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
