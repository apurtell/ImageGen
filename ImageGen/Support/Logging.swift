import Foundation
import OSLog

/// Logging subsystems organizing Apple unified logging categories across the application architecture.
///
/// Dispatches log events into domain-specific categories including pipeline orchestration, transport networking,
/// storage persistence, imaging operations, and diagnostic test harnesses.
enum Log {
  static let subsystem = Bundle.main.bundleIdentifier ?? "com.andrewpurtell.imagegen"

  static let pipeline = Logger(subsystem: subsystem, category: "pipeline")
  static let transport = Logger(subsystem: subsystem, category: "transport")
  static let store = Logger(subsystem: subsystem, category: "store")
  static let imaging = Logger(subsystem: subsystem, category: "imaging")
  static let smoke = Logger(subsystem: subsystem, category: "smoke")
}
