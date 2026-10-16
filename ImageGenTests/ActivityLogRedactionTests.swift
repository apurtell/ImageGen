import Foundation
import Testing

@testable import ImageGen

/// The key never reaches the log or OSLog, whatever route it takes (D§9 suite 15, plan M4).
@Suite(.tags(.integration))
struct ActivityLogRedactionTests {
  static let keyShaped = "AIzaSyD-SENTINEL-do-not-log-0123456789x"
  static let notKeyShaped = "not-a-key-SENTINEL-42"

  @Test(arguments: [keyShaped, notKeyShaped])
  func sentinelNeverLogged(sentinel: String) async throws {
    let h = try GenerationHarness(
      manualSleeper: true, key: sentinel, sanitize: { registry in Redactor.forLog(secrets: { registry.all }) })
    // The store reads (and so registers) the key at its first use, as the real Keychain store does.
    _ = try h.keyStore.read()
    let conv = try await h.s.store.createConversation()

    // A success.
    try h.respond("Responses/resp_text_image.json")
    _ = try await h.sendAndWait(h.draft(conv, "a lighthouse"))

    // A 429, then a success.
    try h.respond("Errors/err_429_retryinfo.json", "Responses/resp_text_image.json")
    let rate = try await h.service.send(h.draft(conv, "again"))
    try await h.wait(rate, for: [.retryScheduled])
    try await h.until { h.sleeper!.waitingCount >= 1 }
    h.sleeper!.advance()
    _ = try await h.wait(rate)

    // An error body that echoes ?key=<sentinel>, 5 KB long, three times (the retries).
    let echo = "Bad request for https://generativelanguage.googleapis.com/v1beta/models/x:generateContent?key=\(sentinel) "
      + String(repeating: "padding ", count: 640)
    let other = try await h.s.store.createConversation()
    try h.respond(status: 400, body: Data(echo.utf8))
    _ = try await h.sendAndWait(h.draft(other, "echo"))

    // An API error whose message holds the sentinel without key=.
    let json = try JSONSerialization.data(withJSONObject: [
      "error": ["code": 400, "status": "INVALID_ARGUMENT", "message": "The key \(sentinel) is not allowed here"]
    ])
    try h.respond(status: 400, body: json)
    _ = try await h.sendAndWait(h.draft(other, "api error"))

    // A prompt holding it.
    try h.respond("Responses/resp_thought_parts.json")
    _ = try await h.sendAndWait(h.draft(other, "draw \(sentinel) as a cat"))

    // A URLError description holding it, logged through the facade.
    let urlError = URLError(.notConnectedToInternet, userInfo: [NSLocalizedDescriptionKey: "offline while using \(sentinel)"])
    let action = h.probe.log.begin("Validate key", origin: .user, "manual")
    h.probe.log.result(action, .failed, "\(private: urlError.localizedDescription)")

    // A key validation (the typed key is registered before the request).
    let rig = ModelsClientTests.Rig()
    try rig.respond(ModelsClientTests.list, "Errors/err_400_api_key_invalid.json", status: 400)
    let suite = "ImageGenTests.\(UUID().uuidString)"
    defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    let validation = await MainActor.run {
      ModelAvailabilityService(
        client: rig.client, keyStore: h.keyStore, settings: AppSettings(defaults: UserDefaults(suiteName: suite)!),
        log: h.probe.log, registry: h.registry)
    }
    #expect(await validation.validateKey(sentinel) == .rejected("API key not valid. Please pass a valid API key."))

    await h.probe.log.flush()
    let file = try String(contentsOf: h.probe.fileURL, encoding: .utf8)
    let oslog = h.probe.osLogStrings.joined(separator: "\n") + h.probe.mirrorCalls.map(\.privateText).joined()
    for text in [file, oslog] {
      #expect(!text.contains(sentinel))
      #expect(!text.contains("x-goog-api-key"))
      #expect(text.range(of: "[A-Za-z0-9+/]{100,}", options: .regularExpression) == nil)
      #expect(!text.contains("c2lnbmF0dXJlLW9wYXF1ZS1ieXRlcy0xMjM0NTY3ODkw"))
    }
    #expect(file.contains("<key removed>"))
    // The echoed error body is cut to 2 KB with a note.
    let echoed = try #require(await h.probe.entries().first { $0.kind == .result && $0.message.contains("Bad request for") })
    #expect(echoed.message.contains("… (+"))
    #expect(echoed.message.utf8.count < 2048 + 300)
  }
}
