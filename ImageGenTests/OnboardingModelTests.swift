import Foundation
import Testing

@testable import ImageGen

@MainActor
@Suite(.tags(.integration))
struct OnboardingModelTests {
  @MainActor
  final class Rig {
    let models = ModelsClientTests.Rig()
    let registry = SecretRegistry()
    let probe: ActivityLogProbe
    let keyStore: InMemoryKeyStore
    let suite = "ImageGenTests.\(UUID().uuidString)"
    let model: OnboardingModel

    init() {
      let registry = self.registry
      probe = ActivityLogProbe(sanitize: Redactor.forLog(secrets: { registry.all }))
      keyStore = InMemoryKeyStore(registry: registry)
      let availability = ModelAvailabilityService(
        client: models.client, keyStore: keyStore, settings: AppSettings(defaults: UserDefaults(suiteName: suite)!),
        log: probe.log, registry: registry)
      model = OnboardingModel(keyStore: keyStore, availability: availability, registry: registry, log: probe.log)
    }

    deinit { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
  }

  static let typed = "AIzaSyONBOARD-typed-key-0123456789abcde"

  @Test func saveKeyLogged() async throws {
    let r = Rig()
    try r.models.respond(ModelsClientTests.list, "Models/models_no_flash.json")
    try r.models.respond(ModelsClientTests.list, "Models/models_no_flash.json")
    r.model.keyText = Self.typed
    #expect(await r.model.validateAndSave())
    #expect(try r.keyStore.read() == Self.typed)
    #expect(r.model.phase == .saved(flashWarning: true))
    for _ in 0..<300 where !(await r.probe.entries()).contains(where: { $0.name == "Models refresh" && $0.kind == .result }) {
      try await Task.sleep(for: .milliseconds(10))
    }
    let entries = await r.probe.entries()
    let save = try #require(entries.first { $0.name == "Save API key" && $0.kind == .begin })
    #expect(save.message == "from onboarding")
    let validate = try #require(entries.first { $0.name == "Validate key" && $0.kind == .begin })
    #expect(validate.parentID == save.actionID)
    #expect(entries.contains { $0.name == "Validate key" && $0.kind == .result && $0.message.contains("HTTP 200 · 2 models") })
    let refresh = try #require(entries.first { $0.name == "Models refresh" && $0.kind == .begin })
    #expect(refresh.parentID == nil)
    #expect(refresh.message.hasPrefix("reason key saved"))
    #expect(!entries.contains { $0.message == "parent finished first" })
    let raw = try String(contentsOf: r.probe.fileURL, encoding: .utf8)
    #expect(!raw.contains(Self.typed))
    await r.probe.assertPaired()
  }

  @Test func rejectedKeyLoggedAsFailed() async throws {
    let r = Rig()
    try r.models.respond(ModelsClientTests.list, "Errors/err_400_api_key_invalid.json", status: 400)
    r.model.keyText = Self.typed
    #expect(!(await r.model.validateAndSave()))
    #expect(try r.keyStore.read() == nil)
    let entries = await r.probe.entries()
    let result = try #require(entries.last { $0.name == "Save API key" && $0.kind == .result })
    #expect(result.outcome == .failed)
    #expect(result.message.contains("API_KEY_INVALID"))
    #expect(ActivityLogQuery.lastError(await r.probe.records()) == result.actionID)
  }

  @Test func unreachableOffersSaveAnyway() async throws {
    let r = Rig()
    r.model.keyText = Self.typed
    #expect(!(await r.model.validateAndSave()))
    guard case .unreachable = r.model.phase else {
      Issue.record("expected unreachable, got \(r.model.phase)")
      return
    }
    #expect(r.model.saveAnyway())
    #expect(try r.keyStore.read() == Self.typed)
  }
}

@MainActor
@Suite(.tags(.io))
struct APIKeySectionTests {
  @Test func removeKeyLogged() async throws {
    let registry = SecretRegistry()
    let probe = ActivityLogProbe(sanitize: Redactor.forLog(secrets: { registry.all }))
    let key = "AIzaSyREMOVE-me-0123456789abcdefghijklm"
    let store = InMemoryKeyStore(key: key, registry: registry)
    let model = APIKeySectionModel(keyStore: store, log: probe.log)
    #expect(model.lastFour == "ijklm".suffix(4).description)
    #expect(model.removeKey())
    #expect(try store.read() == nil)
    #expect(!model.hasKey)
    let tree = await probe.action(named: "Remove API key")
    #expect(tree.last?.outcome == .success)
    #expect(tree.last?.message.contains("Keychain status ok") == true)
    let raw = try String(contentsOf: probe.fileURL, encoding: .utf8)
    #expect(!raw.contains(key))
    await probe.assertPaired()
  }
}
