import AppKit
import UserNotifications

/// Handles macOS application lifecycle and notification events.
///
/// Forwards launch and notification events to `AppEnvironment`. Background URLSession wake
/// events do not exist on macOS, so the app handles completion events directly.
final class MacAppDelegate: NSObject, NSApplicationDelegate {
  /// Identifier of the main window scene.
  static let mainWindowID = "main"

  private var observers: [any NSObjectProtocol] = []

  func applicationDidFinishLaunching(_ notification: Notification) {
    guard !AppEnvironment.isTestHost else { return }
    UNUserNotificationCenter.current().delegate = self
    AppEnvironment.shared.didFinishLaunching(applicationState: NSApp.isActive ? .active : .inactive)
    // Observe NSApplication activation notifications to drive application lifecycle state transitions.
    let center = NotificationCenter.default
    observers = [
      center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
        MainActor.assumeIsolated { AppEnvironment.shared.scenePhaseChanged(isActive: true, isBackground: false) }
      },
      center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
        MainActor.assumeIsolated { AppEnvironment.shared.scenePhaseChanged(isActive: false, isBackground: true) }
      },
    ]
    // Monitor window miniaturization and occlusion states to track conversation visibility.
    for name in [NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification, NSWindow.didChangeOcclusionStateNotification] {
      observers.append(
        center.addObserver(forName: name, object: nil, queue: .main) { note in
          let window = note.object as? NSWindow
          MainActor.assumeIsolated {
            guard let window, window.identifier?.rawValue.hasPrefix(Self.mainWindowID) == true else { return }
            AppEnvironment.shared.activity.setChatWindowVisible(window.occlusionState.contains(.visible) && !window.isMiniaturized)
          }
        })
    }
  }

  /// Preserves background generation and notification delivery when all application windows are closed.
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

  /// Coordinates graceful termination, allowing pending draft writes and diagnostic flushes to complete before exit.
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard !AppEnvironment.isTestHost else { return .terminateNow }
    let (finished, finish) = AsyncStream<Void>.makeStream()
    Task { @MainActor in
      await AppEnvironment.shared.prepareToTerminate()
      finish.yield()
    }
    Task {
      try? await Task.sleep(for: .seconds(1))
      finish.yield()
    }
    Task { @MainActor in
      for await _ in finished { break }
      NSApp.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }

  /// Restores and orders front the main application window upon Dock reactivation.
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    Self.showMainWindow()
    return false
  }

  /// Activates the process and reveals the primary application window.
  @MainActor static func showMainWindow() {
    NSApp.activate()
    let window = NSApp.windows.first { $0.identifier?.rawValue.hasPrefix(mainWindowID) == true }
    window?.makeKeyAndOrderFront(nil)
  }
}

extension MacAppDelegate: UNUserNotificationCenterDelegate {
  /// Suppresses completion banners if the user is already viewing the target chat in the foreground.
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    let id = (notification.request.content.userInfo["conversationID"] as? String).flatMap(UUID.init(uuidString:))
    nonisolated(unsafe) let done = completionHandler
    DispatchQueue.main.async {
      MainActor.assumeIsolated {
        let activity = AppEnvironment.shared.activity
        done(activity.isOnScreen(id) ? [] : [.banner, .sound])
      }
    }
  }

  /// Routes notification taps to `NotificationRouter` to navigate to the chat.
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let id = (response.notification.request.content.userInfo["conversationID"] as? String).flatMap(UUID.init(uuidString:))
    nonisolated(unsafe) let done = completionHandler
    DispatchQueue.main.async {
      MainActor.assumeIsolated {
        if let id {
          AppEnvironment.shared.router.open(id)
          Self.showMainWindow()
        }
        done()
      }
    }
  }
}
