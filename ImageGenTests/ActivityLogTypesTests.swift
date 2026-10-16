import Foundation
import Testing

@testable import ImageGen

@Suite(.tags(.pure))
struct ActivityLogTypesTests {
  @Test func entryJSONRoundTrip() throws {
    let stamp = Date(timeIntervalSince1970: 1_792_143_660.125)
    let full = ActivityEntry(
      timestamp: stamp, actionID: ActionID(raw: "3f9c"), parentID: ActionID(raw: "08d1"),
      name: "Late completion", kind: .begin, origin: .system, outcome: .success,
      relatedID: ActionID(raw: "7f3a"), message: "req 3f9c · attempt 2")
    let data = try JSONEncoder().encode(full)
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(Set(object.keys) == [
      "timestamp", "actionID", "parentID", "name", "kind", "origin", "outcome", "relatedID", "message",
    ])
    #expect(object["actionID"] as? String == "3f9c")
    #expect(object["timestamp"] as? String == "2026-10-16T09:41:00.125Z")
    let decoded = try JSONDecoder().decode(ActivityEntry.self, from: data)
    #expect(decoded == full)
    #expect(abs(decoded.timestamp.timeIntervalSince1970 - stamp.timeIntervalSince1970) < 0.0005)

    let minimal = ActivityEntry(
      timestamp: stamp, actionID: ActionID(raw: "0001"), name: "Send", kind: .step, message: "attempt 1")
    let minimalObject = try #require(
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(minimal)) as? [String: Any])
    #expect(Set(minimalObject.keys) == ["timestamp", "actionID", "name", "kind", "message"])
  }

  @Test func outcomeAndKindRawValues() {
    #expect([ActivityKind.begin, .step, .result].map(\.rawValue) == ["begin", "step", "result"])
    #expect(
      [ActivityOutcome.success, .failed, .refused, .cancelled, .interrupted].map(\.rawValue)
        == ["success", "failed", "refused", "cancelled", "interrupted"])
    #expect([ActivityOrigin.user, .system].map(\.rawValue) == ["user", "system"])
    #expect(ActionID(raw: "ab12").description == "ab12")
  }
}
