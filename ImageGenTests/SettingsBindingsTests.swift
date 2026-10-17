import Foundation
import Testing

@testable import ImageGen

@MainActor
@Suite(.tags(.integration))
struct SettingsBindingsTests {
  /// Test fixture configuring a chat screen model and settings model sharing underlying preferences, store, and log subsystems.
  @MainActor
  final class Rig {
    let chat: ChatScreenModelTests.Rig
    let models = ModelsClientTests.Rig()
    let registry = SecretRegistry()
    let keyStore: InMemoryKeyStore
    let availability: ModelAvailabilityService
    let settingsModel: SettingsModel
    var notificationStatus = "authorized"

    init(key: String? = "stored-key-1234") async throws {
      chat = try await ChatScreenModelTests.Rig()
      keyStore = InMemoryKeyStore(key: key, registry: registry)
      availability = ModelAvailabilityService(
        client: models.client, keyStore: keyStore, settings: chat.settings, log: chat.probe.log, registry: registry)
      settingsModel = SettingsModel(
        services: SettingsModel.Services(
          settings: chat.settings, keyStore: keyStore, availability: availability, modelsClient: models.client,
          store: chat.s.store, files: chat.s.files, thumbnails: ThumbnailService(directory: chat.s.files.thumbnailsDir),
          generation: chat.generation, log: chat.probe.log, navigator: chat.navigator,
          notificationStatus: { "denied" }))
    }

    var settings: AppSettings { chat.settings }
    var model: ChatScreenModel { chat.model }

    func listed(_ ids: [String]) {
      settings.modelAvailabilityCache = ModelAvailabilityCache(
        models: Dictionary(uniqueKeysWithValues: ids.map { ($0, true) }), checkedAt: Date())
    }
  }

  static let pro = "gemini-3-pro-image"
  static let nb21 = "gemini-nano-banana-2.1"

  @Test func changingDefaultAspectAffectsNonOverriddenChatPills() async throws {
    let r = try await Rig()
    #expect(r.model.aspectPillLabel == "16:9")
    r.settingsModel.setDefaultAspect(.r1x1)
    r.settingsModel.setDefaultSize(.s1K)
    #expect(r.model.aspectPillLabel == "1:1")
    #expect(r.model.sizePillLabel == "1K")
    #expect(!r.model.aspectOverridden && !r.model.sizeOverridden)
    #expect(r.model.effective.aspectRatio == .r1x1)
  }

  @Test func doesNotAffectOverriddenChat() async throws {
    let r = try await Rig()
    await r.model.setAspect(.r9x16, from: .pill)
    r.settingsModel.setDefaultAspect(.r1x1)
    #expect(r.model.aspectPillLabel == "9:16")
    #expect(r.model.aspectOverridden)
  }

  @Test func doesNotChangeRecordedRequests() async throws {
    let r = try await Rig()
    let record = try await r.chat.s.send(r.chat.conv, prompt: "x")
    r.settingsModel.setDefaultAspect(.r1x1)
    r.settingsModel.setDefaultSize(.s4K)
    let snap = try #require(try await r.chat.s.store.requestSnapshot(record.requestID))
    #expect(snap.settings.aspectRatio == .r16x9)
    #expect(snap.settings.imageSize == .s2K)
  }

  @Test func flashToggleDisabled() async throws {
    let r = try await Rig()
    #expect(!r.settingsModel.toggleableModels.contains { $0.id == ModelCatalog.defaultModelID })
    r.settingsModel.setEnabled(ModelCatalog.defaultModelID, false)
    #expect(r.settingsModel.isEnabled(ModelCatalog.defaultModelID))
    #expect(await r.chat.probe.action(named: "Settings change").isEmpty)
  }

  @Test func customIDValidatedBeforeAdd() async throws {
    let r = try await Rig()
    try r.models.respond(
      URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-gone")!, "Errors/err_404.json", status: 404)
    #expect(await r.settingsModel.addCustomModel("gemini-gone") == .rejected("Google doesn't know this model for your key."))
    #expect(r.settings.customModelIDs.isEmpty)
    try r.models.respond(
      URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-x-test")!, "Models/model_get_custom.json")
    #expect(await r.settingsModel.addCustomModel(" models/gemini-x-test ") == .added)
    #expect(r.settings.customModelIDs == ["gemini-x-test"])
    #expect(await r.settingsModel.addCustomModel("gemini-x-test") == .invalid("That model is already in the list."))
    #expect(await r.settingsModel.addCustomModel("bad id/x") == .invalid("Model IDs use letters, digits, “-”, “.” and “_”."))
    r.settingsModel.removeCustomModel("gemini-x-test")
    #expect(r.settings.customModelIDs.isEmpty)
  }

  @Test func removeKeyReturnsToOnboarding() async throws {
    let r = try await Rig()
    let key = APIKeySectionModel(keyStore: r.keyStore, log: r.chat.probe.log, availability: r.availability, registry: r.registry)
    #expect(key.statusText == "Saved (…1234)")
    #expect(key.removeKey())
    #expect(!key.hasKey)
    #expect(key.statusText == "Not set")
    #expect(try r.keyStore.read() == nil)
  }

  @Test func deleteAllChatsWipesStoreAndFiles() async throws {
    let r = try await Rig()
    _ = try await r.chat.imageTurn()
    try FileStore.createDirectory(r.chat.s.files.thumbnailsDir)
    try Data(repeating: 1, count: 100).write(to: r.chat.s.files.thumbnailsDir.appendingPathComponent("t.jpg"))
    let other = try await r.chat.s.store.createConversation()
    try await r.chat.s.send(other, prompt: "with upload", attachments: [try r.chat.s.stage()])
    r.chat.navigator.path = [other]
    await r.settingsModel.deleteAllChats()
    let inventory = try await r.chat.s.store.inventory()
    #expect(inventory.chats == 0 && inventory.images == 0)
    #expect(FileStore.usage(of: r.chat.s.files.imagesDir).count == 0)
    #expect(FileStore.usage(of: r.chat.s.files.thumbnailsDir).count == 0)
    #expect(r.chat.navigator.path.isEmpty)
  }

  @Test func storageSizesComputed() async throws {
    let r = try await Rig()
    _ = try await r.chat.imageTurn()
    await r.settingsModel.refreshSizes()
    let expected = r.chat.s.files.sizes()
    #expect(r.settingsModel.sizes == expected)
    #expect(r.settingsModel.sizes.images > 0)
    #expect(r.settingsModel.totalBytes == expected.images + expected.requests + expected.staging + expected.thumbnails)
  }

  @Test func changingMaxLongEdgeAffectsNewAttachments() async throws {
    let r = try await Rig()
    r.settingsModel.setMaxLongEdge(3072)
    await r.model.attach([.data(ImageFactory.jpeg(width: 8064, height: 6048))], from: .photos)
    let prepared = try #require(r.model.tray.first?.prepared)
    #expect(prepared.longEdgeSetting == 3072)
    #expect(max(prepared.pixelWidth, prepared.pixelHeight) == 3072)
    let spec = RequestBodySpec(
      images: [BodyImage(fileURL: prepared.url, mimeType: prepared.mimeType, byteCount: prepared.byteCount)],
      promptText: "", settings: r.model.effective)
    #expect(r.model.projectedBodyBytes == (try RequestBodyWriter.predictedSize(spec)))
    await r.model.send()
    #expect(r.chat.generation.sends.value.first?.attachments.first?.prepared.longEdgeSetting == 3072)
  }

  @Test func disablingModelMakesOverriddenChatFallBackToFlash() async throws {
    let r = try await Rig()
    await r.model.setModel(Self.pro, from: .pill)
    #expect(r.model.effective.modelID == Self.pro)
    r.settingsModel.setEnabled(Self.pro, false)
    #expect(r.model.effective.modelID == ModelCatalog.defaultModelID)
    #expect(r.model.isCoerced(.model))
    r.settingsModel.setEnabled(Self.pro, true)
    #expect(r.model.effective.modelID == Self.pro)
  }

  @Test func modelMenuOffersEnabledAvailableModels() async throws {
    let r = try await Rig()
    r.listed([ModelCatalog.defaultModelID, Self.pro, Self.nb21])
    #expect(Set(r.model.menuModels.map(\.id)) == [ModelCatalog.defaultModelID, Self.pro, Self.nb21])
    r.settingsModel.setEnabled(Self.nb21, false)
    #expect(Set(r.model.menuModels.map(\.id)) == [ModelCatalog.defaultModelID, Self.pro])
    #expect(r.settingsModel.availability("gemini-2.5-flash-image") == .notListed)
    #expect(r.settingsModel.availability(Self.pro) == .available)
  }

  @Test func defaultMenuLabelsFollowChangedDefaults() async throws {
    let r = try await Rig()
    r.settingsModel.setDefaultAspect(.r1x1)
    r.settingsModel.setDefaultSize(.s1K)
    #expect(r.model.defaultAspectItemLabel == "Default (1:1)")
    #expect(r.model.defaultSizeItemLabel == "Default (1K)")
  }

  @Test func notificationStatusShown() async throws {
    let r = try await Rig()
    await r.settingsModel.refreshNotificationStatus()
    #expect(r.settingsModel.notificationStatus == "denied")
    #expect(r.settingsModel.notificationStatusText == "Off in system Settings")
  }

  @Test func settingChangesLogged() async throws {
    let r = try await Rig()
    r.settingsModel.setDefaultAspect(.r1x1)
    r.settingsModel.setMaxLongEdge(3072)
    r.settingsModel.setThreshold(.blockOnlyHigh)
    r.settingsModel.setIncludeText(false)
    r.settingsModel.setEnabled(Self.nb21, false)
    r.settingsModel.setMaxLongEdge(3072)  // Unchanged value suppresses redundant log emissions.
    let begins = await r.chat.probe.entries().filter { $0.name == "Settings change" && $0.kind == .begin }.map(\.message)
    #expect(
      begins == [
        "default aspect ratio 16:9 → 1:1", "max long edge 2048 → 3072", "safety threshold Block none → Block only high",
        "request text alongside images on → off", "model 2.1 on → off",
      ])
    #expect(await r.chat.probe.entries().filter { $0.name == "Settings change" && $0.kind == .begin }.allSatisfy { $0.origin == .user })
    await r.chat.probe.assertPaired()
  }

  @Test func customIDValidationLogged() async throws {
    let r = try await Rig()
    try r.models.respond(
      URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-gone")!, "Errors/err_404.json", status: 404)
    _ = await r.settingsModel.addCustomModel("gemini-gone")
    let tree = await r.chat.probe.action(named: "Add custom model")
    #expect(tree.first?.message == "gemini-gone · GET /v1beta/models/{id}")
    #expect(tree.last?.outcome == .failed)
    #expect(tree.last?.message == "HTTP 404 · not added")
    let mirror = try #require(r.chat.probe.mirrorCalls.first { $0.entry.name == "Add custom model" && $0.entry.kind == .begin })
    #expect(mirror.publicText == "<private> · GET /v1beta/models/{id}")
    await r.chat.probe.assertPaired()
  }

  @Test func removeKeyLogged() async throws {
    let r = try await Rig()
    try r.models.respond(ModelsClientTests.list, "Models/models_no_flash.json")
    try r.models.respond(ModelsClientTests.list, "Models/models_no_flash.json")
    let key = APIKeySectionModel(keyStore: r.keyStore, log: r.chat.probe.log, availability: r.availability, registry: r.registry)
    key.beginReplace()
    let form = try #require(key.replace)
    let typed = "replacement-key-5678"
    form.keyText = typed
    #expect(await form.validateAndSave())
    key.replaceFinished()
    #expect(key.statusText == "Saved (…5678)")
    #expect(key.removeKey())
    let save = await r.chat.probe.action(named: "Save API key")
    #expect(save.first?.message == "from Settings › Replace Key")
    #expect(save.last?.outcome == .success)
    let remove = await r.chat.probe.action(named: "Remove API key")
    #expect(remove.last?.outcome == .success)
    #expect(!(await r.chat.probe.lines()).contains { $0.contains(typed) || $0.contains("stored-key-1234") })
  }

  @Test func deleteAllChatsLogged() async throws {
    let r = try await Rig()
    _ = try await r.chat.imageTurn()
    await r.settingsModel.refreshSizes()
    await r.settingsModel.deleteAllChats()
    var tree = await r.chat.probe.action(named: "Delete all chats")
    #expect(tree.first?.message.hasPrefix("1 chat · 1 image · ") == true)
    #expect(tree.first?.message.hasSuffix(" · 0 live requests to cancel") == true)
    #expect(tree.last?.outcome == .success)
    #expect(tree.last?.message.hasPrefix("chats removed 1 · files removed ") == true)

    // Failed filesystem deletions conclude the activity action as failed with detailed error accounting.
    let conv = try await r.chat.s.store.createConversation()
    try await r.chat.s.send(conv, prompt: "p", attachments: [try r.chat.s.stage()])
    let dir = r.chat.s.files.conversationDir(conv)
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
    await r.settingsModel.deleteAllChats()
    tree = await r.chat.probe.action(named: "Delete all chats")
    #expect(tree.last?.outcome == .failed)
    #expect(tree.last?.message.contains("1 failed: ") == true)
    await r.chat.probe.assertPaired()
  }

  @Test func clearThumbnailCacheLogged() async throws {
    let r = try await Rig()
    let dir = r.chat.s.files.thumbnailsDir
    try FileStore.createDirectory(dir)
    for i in 0..<3 { try Data(repeating: 1, count: 1000).write(to: dir.appendingPathComponent("t\(i).jpg")) }
    await r.settingsModel.clearThumbnailCache()
    #expect(FileStore.usage(of: dir).count == 0)
    let tree = await r.chat.probe.action(named: "Clear thumbnail cache")
    #expect(tree.first?.message == "3 files · 0.0 MB")
    #expect(tree.last?.message == "removed 3 · 0.0 MB freed")
  }
}

@MainActor
@Suite(.tags(.integration))
struct CustomIDScrubbingTests {
  @Test func customIDHoldingKeyIsScrubbed() async throws {
    let models = ModelsClientTests.Rig()
    let registry = SecretRegistry()
    let probe = ActivityLogProbe(sanitize: Redactor.forLog(secrets: { registry.all }))
    let suite = "ImageGenTests.\(UUID().uuidString)"
    defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: UserDefaults(suiteName: suite)!)
    let s = try InMemoryStore()
    let keyStore = InMemoryKeyStore(key: "stored-key-1234", registry: registry)
    let availability = ModelAvailabilityService(
      client: models.client, keyStore: keyStore, settings: settings, log: probe.log, registry: registry)
    let model = SettingsModel(
      services: SettingsModel.Services(
        settings: settings, keyStore: keyStore, availability: availability, modelsClient: models.client, store: s.store,
        files: s.files, thumbnails: ThumbnailService(directory: s.files.thumbnailsDir), generation: FakeGeneration(),
        log: probe.log, navigator: Navigator(), notificationStatus: { "authorized" }))
    let sentinel = ActivityLogRedactionTests.keyShaped
    try models.respond(
      URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(sentinel)")!, "Errors/err_404.json", status: 404)
    _ = await model.addCustomModel(sentinel)
    #expect(settings.customModelIDs.isEmpty)
    #expect(!(await probe.lines()).contains { $0.contains(sentinel) })
    #expect(!probe.osLogStrings.contains { $0.contains(sentinel) })
    #expect(await probe.action(named: "Add custom model").last?.outcome == .failed)
  }
}

extension ModelAvailabilityServiceTests {
  @Test @MainActor func unlistedModelLeftOutOfMenuButFlashSelectable() async throws {
    let r = try await ChatScreenModelTests.Rig()
    r.settings.modelAvailabilityCache = ModelAvailabilityCache(models: ["gemini-3-pro-image": true], checkedAt: Date())
    #expect(r.model.menuModels.map(\.id) == [ModelCatalog.defaultModelID, "gemini-3-pro-image"])
    #expect(r.model.flashUnlisted)
  }

  @Test @MainActor func uncheckedModelsOfferedUntilFirstCheck() async throws {
    let r = try await ChatScreenModelTests.Rig()
    #expect(r.settings.modelAvailabilityCache == nil)
    let ids = Set(r.model.menuModels.map(\.id))
    let expected = Set(ModelCatalog.builtIns.filter { $0.role != .legacyIfListed }.map(\.id))
    #expect(ids == expected)
    #expect(!r.model.flashUnlisted)
    r.settings.modelAvailabilityCache = ModelAvailabilityCache(
      models: [ModelCatalog.defaultModelID: true, "gemini-3-pro-image-preview": true], checkedAt: Date())
    #expect(r.model.menuModels.map(\.id).contains("gemini-3-pro-image-preview"))
  }
}
