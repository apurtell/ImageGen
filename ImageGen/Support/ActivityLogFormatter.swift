import Foundation

/// Turns entries into the viewer's lines (D§3.10). Pure.
///
///     14:02:11.384 [Send a1b2] Begin: gemini-3.1-flash-image · 16:9 · 2K
///     14:02:11.390   [Prepare request 3c5e] Result: success in 0.0 s · body.json 1.3 MB
enum ActivityLogFormatter {
  static let rotatedOutNote = "(earlier entries rotated out)"
  static let completedLaterNote = "(completed later)"
  static let emptyText = "No log entries"

  static func lines(_ view: ActivityView, timeZone: TimeZone = .current) -> [String] {
    guard !view.entries.isEmpty else { return [emptyText] }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone

    // Depth from the parent links among the shown entries.
    var parents: [ActionID: ActionID] = [:]
    for e in view.entries { if let p = e.parentID { parents[e.actionID] = p } }
    func depth(_ id: ActionID) -> Int {
      var d = 0
      var current = id
      while let p = parents[current], d < 64 {
        d += 1
        current = p
      }
      return d
    }

    var out: [String] = []
    var seen: Set<ActionID> = []
    var lastDay: DateComponents?
    var inLateSection = false
    let blank = String(repeating: " ", count: 12)  // the width of HH:mm:ss.SSS

    for e in view.entries {
      let day = calendar.dateComponents([.year, .month, .day], from: e.timestamp)
      if day != lastDay {
        if lastDay != nil || view.isFullLog { out.append("— \(dateString(e.timestamp, calendar)) —") }
        lastDay = day
      }
      let isLate = view.lateCompletionIDs.contains(e.actionID)
      if isLate && !inLateSection {
        out.append("\(blank)  \(completedLaterNote)")
        inLateSection = true
      }
      let level = depth(e.actionID) + (isLate ? 1 : 0)
      let indent = String(repeating: "  ", count: level)
      if !seen.contains(e.actionID) {
        seen.insert(e.actionID)
        if e.kind != .begin { out.append("\(blank) \(indent)\(rotatedOutNote)") }
      }
      out.append("\(timeString(e.timestamp, calendar)) \(indent)[\(e.name) \(e.actionID)] \(body(e))")
    }
    return out
  }

  static func text(_ view: ActivityView, timeZone: TimeZone = .current) -> String {
    lines(view, timeZone: timeZone).joined(separator: "\n")
  }

  /// `Begin: …`, `Step: …`, or `Result: <outcome> …` (a message starting with "in " follows the
  /// outcome word directly; anything else after ` · `).
  static func body(_ e: ActivityEntry) -> String {
    switch e.kind {
    case .begin: return "Begin: \(e.message)"
    case .step: return "Step: \(e.message)"
    case .result:
      let word = e.outcome?.rawValue ?? "done"
      if e.message.isEmpty { return "Result: \(word)" }
      return e.message.hasPrefix("in ") ? "Result: \(word) \(e.message)" : "Result: \(word) · \(e.message)"
    }
  }

  /// Rounded to the millisecond, so a stored `.384` that reads back as `.38399…` prints as `.384`.
  private static func timeString(_ date: Date, _ calendar: Calendar) -> String {
    let totalMs = Int64((date.timeIntervalSince1970 * 1000).rounded())
    let ms = Int(((totalMs % 1000) + 1000) % 1000)
    let whole = Date(timeIntervalSince1970: Double((totalMs - Int64(ms)) / 1000))
    let c = calendar.dateComponents([.hour, .minute, .second], from: whole)
    return String(format: "%02d:%02d:%02d.%03d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0, ms)
  }

  private static func dateString(_ date: Date, _ calendar: Calendar) -> String {
    let c = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
  }
}
