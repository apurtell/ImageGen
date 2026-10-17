import Foundation

// Activity-log vocabulary (D§4.13). Behavior arrives in M2. Lives in Support/ because every layer
// logs and Support/ must not depend on Pipeline/.
//
// Every type here is a `Sendable` value, so an entry can travel from any caller, through the
// facade's stream, to the store's actor. `ActivityEntry`'s `Codable` code defines the JSON shape of
// each line of `activity.jsonl`.

/// Four lowercase hex digits. Encoded as a bare string.
/// The custom `init(from:)` and `encode(to:)` write `"a1b2"`, not the default `{"raw":"a1b2"}`.
/// `ActivityLog.actionID(counter:)` makes them.
struct ActionID: Sendable, Codable, Hashable, CustomStringConvertible {
  let raw: String

  init(raw: String) { self.raw = raw }

  init(from decoder: Decoder) throws {
    raw = try decoder.singleValueContainer().decode(String.self)
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(raw)
  }

  var description: String { raw }
}

/// Every action has exactly one begin and one result; steps are optional (D§4.13 Pairing).
enum ActivityKind: String, Sendable, Codable { case begin, step, result }

enum ActivityOrigin: String, Sendable, Codable { case user, system }

/// No `empty` case on purpose: an empty reply's Send ends `failed` (D§4.13 Outcomes).
enum ActivityOutcome: String, Sendable, Codable { case success, failed, refused, cancelled, interrupted }

/// One line of the log file. `name` is on every line: the facade sets it on a begin, and the store
/// fills it in on steps and results from its index.
struct ActivityEntry: Sendable, Codable, Equatable {
  /// ISO 8601 with milliseconds in the file.
  var timestamp: Date
  var actionID: ActionID
  var parentID: ActionID?
  var name: String
  var kind: ActivityKind
  /// Begin only; the store fills it for sub-actions.
  var origin: ActivityOrigin?
  /// Result only.
  var outcome: ActivityOutcome?
  /// Late completion begin only: the original action.
  var relatedID: ActionID?
  var message: String

  private enum CodingKeys: String, CodingKey {
    case timestamp, actionID, parentID, name, kind, origin, outcome, relatedID, message
  }

  init(
    timestamp: Date, actionID: ActionID, parentID: ActionID? = nil, name: String,
    kind: ActivityKind, origin: ActivityOrigin? = nil, outcome: ActivityOutcome? = nil,
    relatedID: ActionID? = nil, message: String
  ) {
    self.timestamp = timestamp
    self.actionID = actionID
    self.parentID = parentID
    self.name = name
    self.kind = kind
    self.origin = origin
    self.outcome = outcome
    self.relatedID = relatedID
    self.message = message
  }

  // `Codable` is written out by hand for the timestamp: `JSONEncoder`'s built-in ISO 8601 has no
  // milliseconds. A bad timestamp throws, so readers skip that line.
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let stamp = try c.decode(String.self, forKey: .timestamp)
    guard let date = try? Date(stamp, strategy: Self.timestampStyle) else {  // Becomes the error below.
      throw DecodingError.dataCorruptedError(
        forKey: .timestamp, in: c, debugDescription: "not ISO 8601 with milliseconds: \(stamp)")
    }
    timestamp = date
    actionID = try c.decode(ActionID.self, forKey: .actionID)
    parentID = try c.decodeIfPresent(ActionID.self, forKey: .parentID)
    name = try c.decode(String.self, forKey: .name)
    kind = try c.decode(ActivityKind.self, forKey: .kind)
    origin = try c.decodeIfPresent(ActivityOrigin.self, forKey: .origin)
    outcome = try c.decodeIfPresent(ActivityOutcome.self, forKey: .outcome)
    relatedID = try c.decodeIfPresent(ActionID.self, forKey: .relatedID)
    message = try c.decode(String.self, forKey: .message)
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(timestamp.formatted(Self.timestampStyle), forKey: .timestamp)
    try c.encode(actionID, forKey: .actionID)
    try c.encodeIfPresent(parentID, forKey: .parentID)
    try c.encode(name, forKey: .name)
    try c.encode(kind, forKey: .kind)
    try c.encodeIfPresent(origin, forKey: .origin)
    try c.encodeIfPresent(outcome, forKey: .outcome)
    try c.encodeIfPresent(relatedID, forKey: .relatedID)
    try c.encode(message, forKey: .message)
  }

  /// UTC, for example `2026-10-16T09:41:00.123Z`.
  static let timestampStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
}

/// Published by `changes()` (M2).
/// The store computes it from its index after each write. `DeveloperMenuModel` uses it to enable the
/// menu's items, and the viewer to see that new entries exist.
struct ActivityLogStatus: Sendable, Equatable {
  var lastSequence: Int
  /// What Last Action and Last Error would show; nil when there is none.
  var lastActionID: ActionID?
  var lastErrorID: ActionID?
}
