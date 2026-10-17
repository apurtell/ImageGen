import Foundation
import Testing

@testable import ImageGen

/// End-to-end integration suite verifying live image generation and editing.
/// Conditionally executed when `GEMINI_API_KEY` is present in the environment.
@Suite(.tags(.live), .enabled(if: ProcessInfo.processInfo.environment["GEMINI_API_KEY"] != nil))
struct LiveSmokeTests {
  @Test(.timeLimit(.minutes(10)))
  func textToImageThenEdit() async throws {
    let key = try #require(ProcessInfo.processInfo.environment["GEMINI_API_KEY"])
    let s = try InMemoryStore(clock: TestClock(Date()))
    let registry = SecretRegistry()
    let probe = ActivityLogProbe(root: s.root, sanitize: Redactor.forLog(secrets: { registry.all }))
    let transport = URLSessionTransport(configuration: URLSessionTransport.ephemeralConfiguration(), files: s.files)
    defer { transport.invalidateAndWait() }
    let clock = s.clock
    var deps = GenerationService.Dependencies(
      transport: transport, store: s.store, files: s.files, keyStore: InMemoryKeyStore(key: key, registry: registry),
      log: probe.log, backgroundTasks: RecordingBackgroundTaskProvider(log: probe.log),
      notifier: NotificationPoster(activity: AppActivity(isActive: true), isEnabled: { false }, deliver: { _ in }),
      activity: AppActivity(isActive: true), thumbnails: nil, defaults: { GenerationDefaults() }, setOmitCivicOnMain: {},
      onBackgroundEventsFinished: { _, _ in })
    deps.sessionDescription = "ephemeral session (live)"
    deps.clock = { clock.now }
    let service = GenerationService(deps)
    defer { service.stop() }
    let conv = try await s.store.createConversation()

    func run(_ prompt: String, _ aspect: AspectRatio, _ size: ImageSize) async throws -> (Int, Int) {
      let settings = GenerationSettingsResolver.resolve(ChatOverrides(aspectRatio: aspect, imageSize: size), GenerationDefaults())
      let id = try await service.send(SendDraft(conversationID: conv, promptText: prompt, attachments: [], settings: settings))
      var snap = try #require(try await s.store.requestSnapshot(id))
      while snap.state.isLive {
        try await Task.sleep(for: .seconds(1))
        snap = try #require(try await s.store.requestSnapshot(id))
      }
      #expect(snap.state == .succeeded)
      let fields = try #require(try await s.store.outcomeFields(id))
      let w = try #require(fields.outputWidth)
      let h = try #require(fields.outputHeight)
      let honored = SizeClass.isSizeHonored(requested: size, width: w, height: h)
      Log.smoke.log(
        "\(aspect.rawValue, privacy: .public) \(size.rawValue, privacy: .public): \(w)×\(h) class \(SizeClass.classify(width: w, height: h).rawValue, privacy: .public) honored \(honored)")
      return (w, h)
    }

    _ = try await run("A small red lighthouse on a rock, simple flat illustration", .r1x1, .s512)
    // Subsequent turn reuses the generated output as input bytes to verify sequential image editing.
    _ = try await run("Make the sky purple", .r16x9, .s2K)
  }
}
