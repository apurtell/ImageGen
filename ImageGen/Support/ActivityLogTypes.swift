import Foundation

// Core domain models defining the schema, serialization rules, and operational taxonomy for the activity log.

/// Four-character hexadecimal identifier representing an isolated action scope. Encoded as a single scalar string.
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

/// Classification of lifecycle checkpoints within an action execution.
enum ActivityKind: String, Sendable, Codable { case begin, step, result }

/// Provenance categorization indicating whether an action was initiated by user interaction or system automation.
enum ActivityOrigin: String, Sendable, Codable { case user, system }

/// Terminal disposition descriptor recorded upon action completion.
enum ActivityOutcome: String, Sendable, Codable { case success, failed, refused, cancelled, interrupted }

/// Canonical record representing an individual line in the newline-delimited activity log file.
struct ActivityEntry: Sendable, Codable, Equatable {
  /// UTC timestamp with millisecond precision.
  var timestamp: Date
  var actionID: ActionID
  var parentID: ActionID?
  var name: String
  var kind: ActivityKind
  /// Origin indicator, present on action initiation records.
  var origin: ActivityOrigin?
  /// Outcome status, present exclusively on terminal result records.
  var outcome: ActivityOutcome?
  /// Target action identifier for late completion reconciliation.
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

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let stamp = try c.decode(String.self, forKey: .timestamp)
    guard let date = try? Date(stamp, strategy: Self.timestampStyle) else {
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

  /// ISO 8601 formatting style including fractional seconds and UTC timezone indication.
  static let timestampStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
}

/// Published telemetry snapshot reflecting log sequence advancement and active diagnostic anchors.
struct ActivityLogStatus: Sendable, Equatable {
  var lastSequence: Int
  /// Identifier of the most recently initiated primary action, if present.
  var lastActionID: ActionID?
  /// Identifier of the most recent action concluding with an error disposition, if present.
  var lastErrorID: ActionID?
}
