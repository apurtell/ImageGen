import Foundation
import Testing

@testable import ImageGen

@Suite(.tags(.integration))
struct ModelsClientTests {
  static let list = URL(string: "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000")!
  static let page2 = URL(string: "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000&pageToken=page-2-token")!

  final class Rig: Sendable {
    let token = MockURLProtocol.makeToken()
    let client: ModelsClient
    init() {
      let token = self.token
      var c = ModelsClient(session: ModelsClient.makeSession(protocolClasses: [MockURLProtocol.self]))
      c.requestDecorator = { $0.setValue(token, forHTTPHeaderField: MockURLProtocol.tokenHeader) }
      client = c
    }
    deinit { MockURLProtocol.reset(token: token) }

    func respond(_ url: URL, _ fixture: String, status: Int = 200) throws {
      MockURLProtocol.register([.init(status: status, body: try FixtureLoader.data(fixture))], for: url, token: token)
    }
  }

  @Test func paging() async throws {
    let rig = Rig()
    try rig.respond(Self.list, "Models/models_page1.json")
    try rig.respond(Self.page2, "Models/models_page2.json")
    let (models, pages) = try await rig.client.listAll(apiKey: "k")
    #expect(pages == 2)
    #expect(models.map(\.id) == ["gemini-2.5-flash", "gemini-3-pro-image", "text-embedding-004", "gemini-3.1-flash-image", "gemini-nano-banana-2.1"])
    #expect(ModelsClient.flashListed(models))
    #expect(models.first { $0.id == "text-embedding-004" }?.supportsGenerateContent == false)
    let requests = MockURLProtocol.recorded(token: rig.token)
    #expect(requests.allSatisfy { $0.request.value(forHTTPHeaderField: "x-goog-api-key") == "k" })
    #expect(requests.allSatisfy { $0.request.url?.absoluteString.contains("key=") == false })
  }

  @Test func flashMissingWarning() async throws {
    let rig = Rig()
    try rig.respond(Self.list, "Models/models_no_flash.json")
    let (models, _) = try await rig.client.listAll(apiKey: "k")
    #expect(!ModelsClient.flashListed(models))
  }

  @Test func keyRejected400ApiKeyInvalid() async throws {
    let rig = Rig()
    try rig.respond(Self.list, "Errors/err_400_api_key_invalid.json", status: 400)
    await #expect(throws: ModelsClientError.keyRejected(status: 400, apiStatus: "INVALID_ARGUMENT", reason: "API_KEY_INVALID", message: "API key not valid. Please pass a valid API key.")) {
      _ = try await rig.client.listAll(apiKey: "k")
    }
  }

  @Test func rejected403() async throws {
    let rig = Rig()
    try rig.respond(Self.list, "Errors/err_403.json", status: 403)
    do {
      _ = try await rig.client.listAll(apiKey: "k")
      Issue.record("expected a rejection")
    } catch ModelsClientError.keyRejected(let status, let apiStatus, _, _) {
      #expect(status == 403)
      #expect(apiStatus == "PERMISSION_DENIED")
    }
  }

  @Test func plain400IsNotARejection() async throws {
    let rig = Rig()
    try rig.respond(Self.list, "Errors/err_400_invalid_argument.json", status: 400)
    await #expect(throws: ModelsClientError.http(status: 400, message: "Unsupported value for imageConfig.aspectRatio: '7:3'.")) {
      _ = try await rig.client.listAll(apiKey: "k")
    }
  }

  @Test func networkErrorMapsToUnreachable() async throws {
    let rig = Rig()
    // Nothing registered: the mock fails with URLError.resourceUnavailable.
    await #expect(throws: ModelsClientError.unreachable("resourceUnavailable")) { _ = try await rig.client.listAll(apiKey: "k") }
    try rig.respond(Self.list, "Errors/err_503.json", status: 503)
    await #expect(throws: ModelsClientError.unreachable("HTTP 503")) { _ = try await rig.client.listAll(apiKey: "k") }
  }

  @Test func getModelForCustomID() async throws {
    let rig = Rig()
    try rig.respond(URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-x-test")!, "Models/model_get_custom.json")
    let model = try await rig.client.getModel(id: "gemini-x-test", apiKey: "k")
    #expect(model.id == "gemini-x-test")
    #expect(model.supportsGenerateContent)
    try rig.respond(URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-gone")!, "Errors/err_404.json", status: 404)
    do {
      _ = try await rig.client.getModel(id: "gemini-gone", apiKey: "k")
      Issue.record("expected not found")
    } catch ModelsClientError.notFound {}
  }
}

@MainActor
@Suite(.tags(.integration))
struct ModelAvailabilityServiceTests {
  @MainActor
  final class Rig {
    let models = ModelsClientTests.Rig()
    let probe: ActivityLogProbe
    let registry = SecretRegistry()
    let suite = "ImageGenTests.\(UUID().uuidString)"
    let settings: AppSettings
    let service: ModelAvailabilityService
    let clock = TestClock()

    init(key: String? = "stored-key", sanitize: Bool = false) {
      let registry = self.registry
      let identity: @Sendable (String) -> String = { $0 }
      let sanitizer: @Sendable (String) -> String = sanitize ? Redactor.forLog(secrets: { registry.all }) : identity
      probe = ActivityLogProbe(sanitize: sanitizer)
      settings = AppSettings(defaults: UserDefaults(suiteName: suite)!)
      let clock = self.clock
      service = ModelAvailabilityService(
        client: models.client, keyStore: InMemoryKeyStore(key: key, registry: registry), settings: settings, log: probe.log,
        registry: registry, clock: { clock.now })
    }

    deinit { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
  }

  @Test func refreshLogged() async throws {
    let rig = Rig()
    try rig.models.respond(ModelsClientTests.list, "Models/models_page1.json")
    try rig.models.respond(ModelsClientTests.page2, "Models/models_page2.json")
    #expect(await rig.service.refresh(reason: .manual) == .refreshed(modelCount: 5, flashListed: true))
    let tree = await rig.probe.action(named: "Models refresh")
    #expect(tree.first?.origin == .user)
    #expect(tree.first?.message == "reason manual check · GET /v1beta/models?pageSize=1000")
    let result = try #require(tree.last)
    #expect(result.outcome == .success)
    #expect(result.message.contains("2 pages · 5 models · Flash listed"))
    #expect(rig.settings.modelAvailabilityCache?.models["gemini-3-pro-image"] == true)
    #expect(rig.settings.modelAvailabilityCache?.checkedAt == rig.clock.now)
    await rig.probe.assertPaired()
  }

  @Test func refreshIfStaleRunsAtMostDaily() async throws {
    let rig = Rig()
    try rig.models.respond(ModelsClientTests.list, "Models/models_no_flash.json")
    await rig.service.refreshIfStale()
    rig.clock.advance(3600)
    await rig.service.refreshIfStale()
    #expect(await rig.probe.entries().filter { $0.name == "Models refresh" && $0.kind == .begin }.count == 1)
    #expect(await rig.probe.action(named: "Models refresh").first?.origin == .system)
    try rig.models.respond(ModelsClientTests.list, "Models/models_no_flash.json")
    rig.clock.advance(24 * 3600)
    await rig.service.refreshIfStale()
    #expect(await rig.probe.entries().filter { $0.name == "Models refresh" && $0.kind == .begin }.count == 2)
  }

  @Test func refreshIfStaleSkipsWithoutKey() async throws {
    // Before onboarding saves a key, a foreground check logs nothing (no failed "no API key").
    let rig = Rig(key: nil)
    await rig.service.refreshIfStale()
    #expect(await rig.probe.entries().isEmpty)
    // A manual check still says why it can't run.
    #expect(await rig.service.refresh(reason: .manual) == .noKey)
    #expect(await rig.probe.action(named: "Models refresh").last?.message == "no API key")
  }

  @Test func validateKeyLoggedWithoutKey() async throws {
    let rig = Rig(key: nil, sanitize: true)
    let typed = "AIzaSyTYPED-KEY-0123456789abcdefghijkl"
    try rig.models.respond(ModelsClientTests.list, "Errors/err_400_api_key_invalid.json", status: 400)
    #expect(await rig.service.validateKey(typed) == .rejected("API key not valid. Please pass a valid API key.", reason: "API_KEY_INVALID"))
    #expect(rig.registry.all.contains(typed))
    let tree = await rig.probe.action(named: "Validate key")
    #expect(tree.first?.message == "GET /v1beta/models?pageSize=1000 · ephemeral session · 20 s timeout")
    #expect(tree.last?.outcome == .failed)
    #expect(tree.last?.message.contains("key rejected · HTTP 400 INVALID_ARGUMENT") == true)
    let raw = try String(contentsOf: rig.probe.fileURL, encoding: .utf8)
    #expect(!raw.contains(typed))
    #expect(!rig.probe.osLogStrings.joined().contains(typed))

    try rig.models.respond(ModelsClientTests.list, "Models/models_no_flash.json")
    #expect(await rig.service.validateKey(typed) == .valid(modelCount: 2, flashListed: false))
  }
}
