import Foundation
import Testing

@testable import ImageGen

/// Verifies that sensitive authentication keys and credential tokens are strictly stripped and redacted
/// from persistent activity logs and mirrored system logging channels across all execution pathways.
@Suite(.tags(.integration))
struct ActivityLogRedactionTests {
  static let keyShaped = "AIzaSyD-SENTINEL-do-not-log-0123456789x"
  static let notKeyShaped = "not-a-key-SENTINEL-42"

  @Test(arguments: [keyShaped, notKeyShaped])
  func sentinelNeverLogged(sentinel: String) async throws {
    let h = try GenerationHarness(
      manualSleeper: true, key: sentinel, sanitize: { registry in Redactor.forLog(secrets: { registry.all }) })
    // Simulates initial Keychain read and automatic secret registration on first access.
    _ = try h.keyStore.read()
    let conv = try await h.s.store.createConversation()

    // Exercises a baseline successful generation flow.
    try h.respond("Responses/resp_text_image.json")
    _ = try await h.sendAndWait(h.draft(conv, "a lighthouse"))

    // Exercises a transient rate-limit rejection followed by recovery retry.
    try h.respond("Errors/err_429_retryinfo.json", "Responses/resp_text_image.json")
    let rate = try await h.service.send(h.draft(conv, "again"))
    try await h.wait(rate, for: [.retryScheduled])
    try await h.until { h.sleeper!.waitingCount >= 1 }
    h.sleeper!.advance()
    _ = try await h.wait(rate)

    // Simulates an oversized error response echoing query parameter credentials across retry attempts.
    let echo = "Bad request for https://generativelanguage.googleapis.com/v1beta/models/x:generateContent?key=\(sentinel) "
      + String(repeating: "padding ", count: 640)
    let other = try await h.s.store.createConversation()
    try h.respond(status: 400, body: Data(echo.utf8))
    _ = try await h.sendAndWait(h.draft(other, "echo"))

    // Simulates structured API error JSON containing embedded raw credential text.
    let json = try JSONSerialization.data(withJSONObject: [
      "error": ["code": 400, "status": "INVALID_ARGUMENT", "message": "The key \(sentinel) is not allowed here"]
    ])
    try h.respond(status: 400, body: json)
    _ = try await h.sendAndWait(h.draft(other, "api error"))

    // Verifies sanitization of user prompt inputs referencing sensitive sentinel strings.
    try h.respond("Responses/resp_thought_parts.json")
    _ = try await h.sendAndWait(h.draft(other, "draw \(sentinel) as a cat"))

    // Verifies localized URLError description redaction through the logger facade.
    let urlError = URLError(.notConnectedToInternet, userInfo: [NSLocalizedDescriptionKey: "offline while using \(sentinel)"])
    let action = h.probe.log.begin("Validate key", origin: .user, "manual")
    h.probe.log.result(action, .failed, "\(private: urlError.localizedDescription)")

    // Verifies credential registration and redaction during explicit interactive key validation.
    let rig = ModelsClientTests.Rig()
    try rig.respond(ModelsClientTests.list, "Errors/err_400_api_key_invalid.json", status: 400)
    let suite = "ImageGenTests.\(UUID().uuidString)"
    defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    let validation = await MainActor.run {
      ModelAvailabilityService(
        client: rig.client, keyStore: h.keyStore, settings: AppSettings(defaults: UserDefaults(suiteName: suite)!),
        log: h.probe.log, registry: h.registry)
    }
    #expect(await validation.validateKey(sentinel) == .rejected("API key not valid. Please pass a valid API key.", reason: "API_KEY_INVALID"))

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
    // Verifies truncation and suffix annotation of oversized diagnostic payloads exceeding the 2 KB limit.
    let echoed = try #require(await h.probe.entries().first { $0.kind == .result && $0.message.contains("Bad request for") })
    #expect(echoed.message.contains("… (+"))
    #expect(echoed.message.utf8.count < 2048 + 300)
  }
}
